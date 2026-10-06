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

// tasks reads the tasks these dokkit.toml files define. A name that two files both
// declare belongs to neither: a file dropped in another folder cannot take over a task.
func tasks(files []string) map[string]task {
	all, clash, read := map[string]task{}, map[string]bool{}, map[string]bool{}
	for _, p := range files {
		if abs, err := filepath.Abs(p); err == nil {
			p = abs
		}
		if read[p] {
			continue
		}
		read[p] = true
		if d, err := readDeclaration(p); err == nil {
			for _, t := range d.Task {
				if _, taken := all[t.ID]; taken {
					clash[t.ID] = true
				}
				t.dir = filepath.Dir(p)
				all[t.ID] = t
			}
		}
	}
	for id := range clash {
		delete(all, id)
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
	return t.run(os.Stdout, os.Stderr, nil)
}

// run runs a task where its file is and exits as it did. prepare, when there is one,
// sets the account it runs as, and the task does not run if that cannot be done.
func (t task) run(stdout, stderr io.Writer, prepare func(*exec.Cmd) (func(), error)) int {
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
	// The time limit stops the shell; what the shell started may outlive it, so waiting for its output ends too.
	cmd := exec.CommandContext(ctx, shell[0], shell[1:]...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = t.dir, stdout, stderr
	cmd.WaitDelay = killWait
	// cmd looks in the task's own folder first unless told not to.
	cmd.Env = append(os.Environ(), "NoDefaultCurrentDirectoryInExePath=1")
	if prepare != nil {
		after, err := prepare(cmd)
		if err != nil {
			fmt.Fprintln(stderr, "dokkit: not run, because an ordinary account could not be used:", err)
			return 126
		}
		defer after()
	}
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

// killWait is how long a stopped task's output is waited for.
var resultWait = 2 * time.Second

var killWait = 5 * time.Second

// ordinary makes a command run under an ordinary account instead of this program's own.
// The installed service sets it, because it is the system account. Under a login it is
// nil and a task runs as that person.
var ordinary func(*exec.Cmd) (func(), error)

const updateTask = "dokkit:update"

// update is the one built-in task. It fetches the newer copy the server holds and leaves
// it beside the spool. It replaces nothing: a person finishes the update on the machine.
func (c *client) update(run string) {
	said, code := "", 0
	path, sum, err := c.fetchUpdate()
	if err != nil {
		said, code = "Not fetched: "+err.Error(), 1
	} else {
		said = "The newer copy is at " + path + ".\nIts SHA-256 is " + sum + ".\n"
		if c.updateSha == "" {
			said += "Compare it with the hash published for that release before running it.\n"
		}
		said += finishUpdate(path)
	}
	fmt.Println(time.Now().Format("15:04:05"), "", said)
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said+"\n"), nil)
	body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": 0})
	c.postResult("/api/v1/work/"+run+"/result", body)
}

// postResult sends a run's result, trying again while the server cannot be reached or fails.
// A refusal by the server is final.
func (c *client) postResult(path string, body []byte) {
	for i := 0; i < 8; i++ {
		if status, err := c.call("POST", path, "application/json", body, nil); err == nil && status < 500 {
			return
		}
		time.Sleep(resultWait << i)
	}
}

// fetchUpdate leaves the newer copy in place and returns its SHA-256. A copy that does not
// match the hash in this machine's config is removed.
func (c *client) fetchUpdate() (string, string, error) {
	name := "dokkit"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	dir := filepath.Join(filepath.Dir(c.spool), "update")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	path := filepath.Join(dir, name)
	file, err := os.OpenFile(path+".part", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o700)
	if err != nil {
		return "", "", err
	}
	hash := sha256.New()
	status, err := c.call("GET", "/api/v1/program/"+runtime.GOOS+"-"+runtime.GOARCH, "", nil, io.MultiWriter(file, hash))
	file.Close()
	if err != nil || status != 200 {
		return "", "", fmt.Errorf("the server has no newer copy for this kind of machine (%d)", status)
	}
	sum := hex.EncodeToString(hash.Sum(nil))
	if c.updateSha != "" && c.updateSha != sum {
		os.Remove(path + ".part")
		return "", "", fmt.Errorf("the fetched copy has SHA-256 %s, not the %s this machine expects", sum, c.updateSha)
	}
	return path, sum, os.Rename(path+".part", path)
}

// work asks the server for task runs, holding each request open, and runs them one at a time.
func (c *client) work() {
	for {
		var job struct {
			Run, Task, As string
			Sha           string `json:"command_sha256"`
		}
		status, err := c.call("GET", "/api/v1/work?wait=50", "", nil, &job)
		if status == 204 {
			continue
		}
		if err != nil || status != 200 {
			time.Sleep(15 * time.Second)
			continue
		}
		if job.Task == updateTask {
			c.update(job.Run)
			continue
		}
		result := "/api/v1/work/" + job.Run + "/result"
		t, defined := tasks(declarations(c.folders))[job.Task]
		sum := sha256.Sum256([]byte(t.Run))
		// Only the command a person accepted runs. A file edited since then is refused.
		if !defined || hex.EncodeToString(sum[:]) != job.Sha {
			c.postResult(result, []byte(`{"refused":"This machine has no task with that name and that command."}`))
			continue
		}
		if job.As == "system" && !c.system {
			c.postResult(result, []byte(`{"refused":"This task was accepted for the system account, and this machine's own configuration does not allow that. Set system_tasks to true in its config file."}`))
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
		// A task runs as the system account only when it was accepted to.
		var account func(*exec.Cmd) (func(), error)
		if job.As != "system" {
			account = ordinary
		}
		code := t.run(out, out, account)
		close(done)
		<-sent
		body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": time.Since(started).Milliseconds()})
		c.postResult(result, body)
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
	if file, ok := into.(io.Writer); ok && res.StatusCode == 200 {
		// A file, not an answer to read.
		_, err = io.Copy(file, res.Body)
		return res.StatusCode, err
	}
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
