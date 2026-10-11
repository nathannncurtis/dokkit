//go:build !windows && !linux

package main

import (
	"os/exec"
	"path/filepath"
	"strings"
)

// listProcesses uses ps twice, since a program's name and its command line cannot be told apart on one line.
func listProcesses() ([]proc, error) {
	names, err := psColumn("comm")
	if err != nil {
		return nil, err
	}
	args, err := psColumn("args")
	if err != nil {
		return nil, err
	}
	var out []proc
	for pid, n := range names {
		out = append(out, proc{filepath.Base(n), args[pid]})
	}
	return out, nil
}

func psColumn(col string) (map[string]string, error) {
	b, err := exec.Command("ps", "-axww", "-o", "pid=", "-o", col+"=").Output()
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) > 0 {
			m[f[0]] = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(l), f[0]))
		}
	}
	return m, nil
}
