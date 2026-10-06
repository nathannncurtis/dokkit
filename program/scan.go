package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const proposalFile = "dokkit-proposal.json"

type found = map[string]string

// What a scan looks at. Each part asks the machine's own tools and reads no file contents.
var scanParts = []struct {
	name string
	find func() []found
}{
	{"services", findServices},
	{"ports", findPorts},
	{"tasks", findScheduled},
	{"containers", findContainers},
	{"sites", findSites},
	{"disks", findDisks},
}

// scan writes what it finds to a file for a person to read. It sends nothing.
func scan(args []string, folders []string) int {
	skip := map[string]bool{}
	for _, a := range args {
		skip[strings.TrimPrefix(a, "--no-")] = strings.HasPrefix(a, "--no-")
	}
	host, _ := os.Hostname()
	all := map[string][]found{}
	if !skip["declarations"] {
		for _, p := range declarations(folders) {
			all["declarations"] = append(all["declarations"], found{"file": p})
		}
	}
	for _, part := range scanParts {
		if !skip[part.name] {
			all[part.name] = part.find()
		}
	}
	b, _ := json.MarshalIndent(map[string]any{"machine": host, "os": runtime.GOOS, "at": now(), "found": all}, "", "  ")
	if err := os.WriteFile(proposalFile, b, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	for _, name := range []string{"declarations", "services", "ports", "tasks", "containers", "sites", "disks"} {
		if !skip[name] {
			fmt.Printf("%-13s %d\n", name, len(all[name]))
		}
	}
	fmt.Printf("Wrote %s. Nothing was sent.\n", proposalFile)
	return 0
}

// propose sends the file a scan wrote, to be decided about in the interface.
func (c *client) propose() int {
	b, err := os.ReadFile(proposalFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: run dokkit scan first:", err)
		return 1
	}
	var a struct{ Waiting int }
	status, err := c.call("POST", "/api/v1/proposals", "application/json", b, &a)
	if err != nil || status != 200 {
		fmt.Fprintf(os.Stderr, "dokkit: the server did not take it (%d). It needs a machine key. %v\n", status, err)
		return 1
	}
	fmt.Printf("Sent. %d thing(s) are waiting on the Found page.\n", a.Waiting)
	return 0
}

// output runs one of the machine's own tools and returns its lines, or nothing when it is not there.
func output(name string, args ...string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return nil
	}
	return strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n")
}

func findServices() (all []found) {
	if runtime.GOOS != "windows" {
		for _, l := range output("systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain") {
			if f := strings.Fields(l); len(f) >= 4 {
				all = append(all, found{"name": strings.TrimSuffix(f[0], ".service"), "state": f[3]})
			}
		}
		return
	}
	var one found
	for _, l := range output("sc", "query", "type=", "service", "state=", "all") {
		key, value, _ := strings.Cut(strings.TrimSpace(l), ":")
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(key) {
		case "SERVICE_NAME":
			one = found{"name": value}
			all = append(all, one)
		case "DISPLAY_NAME":
			one["display"] = value
		case "STATE":
			if f := strings.Fields(value); len(f) > 1 {
				one["state"] = strings.ToLower(f[1])
			}
		}
	}
	return
}

func findPorts() (all []found) {
	seen := map[string]bool{}
	add := func(port, program string) {
		if !seen[port+program] {
			seen[port+program] = true
			all = append(all, found{"port": port, "program": program})
		}
	}
	if runtime.GOOS != "windows" {
		for _, l := range output("ss", "-ltnpH") {
			f := strings.Fields(l)
			if len(f) < 4 {
				continue
			}
			_, program, _ := strings.Cut(l, `(("`)
			program, _, _ = strings.Cut(program, `"`)
			add(f[3][strings.LastIndex(f[3], ":")+1:], program)
		}
		return
	}
	programs := map[string]string{}
	for _, row := range table(output("tasklist", "/fo", "csv", "/nh")) {
		if len(row) > 1 {
			programs[row[1]] = row[0]
		}
	}
	for _, l := range output("netstat", "-ano", "-p", "TCP") {
		// A listening row is the one with nobody on the other end.
		if f := strings.Fields(l); len(f) == 5 && f[0] == "TCP" && strings.HasSuffix(f[2], ":0") {
			add(f[1][strings.LastIndex(f[1], ":")+1:], programs[f[4]])
		}
	}
	return
}

func findScheduled() (all []found) {
	if runtime.GOOS != "windows" {
		for _, l := range output("systemctl", "list-timers", "--all", "--no-legend", "--plain") {
			if f := strings.Fields(l); len(f) >= 2 {
				all = append(all, found{"name": f[len(f)-2]})
			}
		}
		return
	}
	// Columns keep their order in every language: name, next run, state, mode, last run, result, author, what runs.
	for _, row := range table(output("schtasks", "/query", "/fo", "csv", "/v", "/nh")) {
		if len(row) > 8 && !strings.HasPrefix(row[1], `\Microsoft\`) {
			all = append(all, found{"name": row[1], "last_run": row[5], "runs": row[8]})
		}
	}
	return
}

func findContainers() (all []found) {
	for _, l := range output("docker", "ps", "--format", "{{.Names}}\t{{.Image}}") {
		if name, image, ok := strings.Cut(l, "\t"); ok {
			all = append(all, found{"name": name, "image": image})
		}
	}
	return
}

func findSites() (all []found) {
	if runtime.GOOS == "windows" {
		for _, l := range output(filepath.Join(os.Getenv("windir"), "system32", "inetsrv", "appcmd.exe"), "list", "site", "/text:name") {
			if l != "" {
				all = append(all, found{"name": l, "server": "iis"})
			}
		}
		return
	}
	for _, server := range []string{"nginx", "apache2"} {
		names, _ := filepath.Glob("/etc/" + server + "/sites-enabled/*")
		for _, n := range names {
			all = append(all, found{"name": filepath.Base(n), "server": server})
		}
	}
	return
}

func table(lines []string) [][]string {
	rows, _ := csv.NewReader(strings.NewReader(strings.Join(lines, "\n"))).ReadAll()
	return rows
}

// declarations lists the dokkit.toml files in the folders and in the folders directly inside them.
func declarations(folders []string) (all []string) {
	for _, folder := range folders {
		here, _ := filepath.Glob(filepath.Join(folder, "dokkit.toml"))
		inside, _ := filepath.Glob(filepath.Join(folder, "*", "dokkit.toml"))
		all = append(append(all, here...), inside...)
	}
	return
}

type task struct {
	ID, Run, Timeout string
	dir              string
}

// tasks reads the tasks these dokkit.toml files define. The first file to name a task has it.
func tasks(files []string) map[string]task {
	all := map[string]task{}
	for _, p := range files {
		if d, err := readDeclaration(p); err == nil {
			for _, t := range d.Task {
				if _, taken := all[t.ID]; !taken {
					t.dir = filepath.Dir(p)
					all[t.ID] = t
				}
			}
		}
	}
	return all
}

// accepted asks the server which commands were accepted for this machine, by task.
// ok is false when the machine is not enrolled or the server did not answer.
func accepted(c *client) (bySha map[string]string, ok bool) {
	var a struct {
		Items []struct {
			Task string
			Sha  string `json:"command_sha256"`
		}
	}
	if c == nil {
		return nil, false
	}
	if status, err := c.call("GET", "/api/v1/tasks/accepted", "", nil, &a); err != nil || status != 200 {
		return nil, false
	}
	bySha = map[string]string{}
	for _, item := range a.Items {
		bySha[item.Task] = item.Sha
	}
	return bySha, true
}

// standing says whether the server would be allowed to ask for this task as it is written now.
func standing(run, acceptedSha string, known bool) string {
	sum := sha256.Sum256([]byte(run))
	switch {
	case !known:
		return "not accepted yet"
	case acceptedSha == hex.EncodeToString(sum[:]):
		return "accepted"
	}
	return "changed since it was accepted"
}

func taskCommand(args []string, folders []string, c *client) int {
	all := tasks(append([]string{"dokkit.toml"}, declarations(folders)...))
	if len(args) == 1 && args[0] == "list" {
		shas, asked := accepted(c)
		for id, t := range all {
			state := ""
			if asked {
				sha, known := shas[id]
				state = "   " + standing(t.Run, sha, known)
			}
			fmt.Printf("%-24s %s   in %s%s\n", id, t.Run, t.dir, state)
		}
		if len(all) == 0 {
			fmt.Println("No tasks are defined here or in the folders this machine reads.")
			return 0
		}
		if !asked {
			fmt.Println("The server was not asked which are accepted: this machine is not enrolled, or it did not answer.")
		}
		if u, err := user.Current(); err == nil {
			fmt.Println("A task runs as whoever runs dokkit watch. Here that is " + u.Username + ".")
		}
		return 0
	}
	if len(args) != 2 || args[0] != "run" {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	t, ok := all[args[1]]
	if !ok {
		fmt.Fprintln(os.Stderr, "dokkit: no task called", args[1])
		return 1
	}
	return t.run(os.Stdout, os.Stderr)
}

// run runs a task where its file is and exits as it did.
func (t task) run(stdout, stderr io.Writer) int {
	run := t.Run
	limit, err := time.ParseDuration(t.Timeout)
	if err != nil || limit <= 0 {
		limit = time.Hour
	}
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	shell := []string{"sh", "-c", run}
	if runtime.GOOS == "windows" {
		shell = []string{"cmd", "/c", run}
		if first, _, _ := strings.Cut(run, " "); strings.HasSuffix(strings.ToLower(first), ".ps1") {
			shell = append([]string{"powershell", "-NoProfile", "-File"}, strings.Fields(run)...)
		}
	}
	// On Windows the time limit stops the shell; what the shell started may outlive it.
	cmd := exec.CommandContext(ctx, shell[0], shell[1:]...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = t.dir, stdout, stderr
	err = cmd.Run()
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		fmt.Fprintln(stderr, "dokkit: stopped after", limit)
		return 124
	case errors.As(err, &exit):
		return exit.ExitCode()
	case err != nil:
		fmt.Fprintln(stderr, "dokkit:", err)
		return 127
	}
	return 0
}

// The installed service runs as the system account, and a task must not until it can
// be given an ordinary account. So only dokkit watch under a login takes work.
var takesWork = true

// work asks the server for task runs, holding each request open, and runs them one at a time.
func (c *client) work() {
	for {
		var job struct {
			Run, Task string
			Sha       string `json:"command_sha256"`
		}
		status, err := c.call("GET", "/api/v1/work?wait=50", "", nil, &job)
		if status == 204 {
			continue
		}
		if err != nil || status != 200 {
			time.Sleep(15 * time.Second)
			continue
		}
		result := "/api/v1/work/" + job.Run + "/result"
		t, defined := tasks(declarations(c.folders))[job.Task]
		sum := sha256.Sum256([]byte(t.Run))
		// Only the command a person accepted runs. A file edited since then is refused.
		if !defined || hex.EncodeToString(sum[:]) != job.Sha {
			c.call("POST", result, "application/json", []byte(`{"refused":"This machine has no task with that name and that command."}`), nil)
			continue
		}
		fmt.Printf("%s  running task %s\n", time.Now().Format("15:04:05"), job.Task)
		out, done, sent := &chunks{}, make(chan bool), make(chan bool)
		send := func() {
			if b := out.take(); len(b) > 0 {
				c.call("POST", "/api/v1/work/"+job.Run+"/output", "text/plain", b, nil)
			}
		}
		go func() {
			for {
				select {
				case <-done:
					send()
					close(sent)
					return
				case <-time.After(3 * time.Second):
					send()
				}
			}
		}()
		started := time.Now()
		code := t.run(out, out)
		close(done)
		<-sent
		body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": time.Since(started).Milliseconds()})
		c.call("POST", result, "application/json", body, nil)
	}
}

// call makes one request with this machine's key and reads a JSON answer into `into`.
func (c *client) call(method, path, kind string, body []byte, into any) (int, error) {
	req, err := http.NewRequest(method, c.url+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	if kind != "" {
		req.Header.Set("Content-Type", kind)
	}
	res, err := (&http.Client{Timeout: 70 * time.Second, Transport: toServer}).Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if into != nil && res.StatusCode == 200 {
		json.NewDecoder(res.Body).Decode(into)
	}
	return res.StatusCode, nil
}

// chunks holds a task's output until it is next sent.
type chunks struct {
	sync.Mutex
	b []byte
}

func (c *chunks) Write(p []byte) (int, error) {
	c.Lock()
	defer c.Unlock()
	c.b = append(c.b, p...)
	return len(p), nil
}

func (c *chunks) take() []byte {
	c.Lock()
	defer c.Unlock()
	b := c.b
	c.b = nil
	return b
}
