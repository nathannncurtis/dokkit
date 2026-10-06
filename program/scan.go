package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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

// tasks reads the tasks defined in this folder's dokkit.toml and in the folders this machine may read.
func tasks(folders []string) map[string]task {
	all := map[string]task{}
	for _, p := range append([]string{"dokkit.toml"}, declarations(folders)...) {
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

func taskCommand(args []string, folders []string) int {
	all := tasks(folders)
	if len(args) == 1 && args[0] == "list" {
		for id, t := range all {
			fmt.Printf("%-24s %s   in %s\n", id, t.Run, t.dir)
		}
		if len(all) == 0 {
			fmt.Println("No tasks are defined here or in the folders this machine reads.")
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
	return t.run()
}

// run runs a task where its file is, lets its output through, and exits as it did.
func (t task) run() int {
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
	cmd.Dir, cmd.Stdin, cmd.Stdout, cmd.Stderr = t.dir, os.Stdin, os.Stdout, os.Stderr
	err = cmd.Run()
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		fmt.Fprintln(os.Stderr, "dokkit: stopped after", limit)
		return 124
	case errors.As(err, &exit):
		return exit.ExitCode()
	case err != nil:
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 127
	}
	return 0
}
