package main

import (
	"os"
	"strings"
)

// listProcesses reads /proc. A process whose command line cannot be read, or is empty, is listed with no text.
func listProcesses() ([]proc, error) {
	dirs, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	var out []proc
	for _, d := range dirs {
		if d.Name()[0] < '0' || d.Name()[0] > '9' {
			continue
		}
		comm, err := os.ReadFile("/proc/" + d.Name() + "/comm")
		if err != nil {
			continue
		}
		cmd, _ := os.ReadFile("/proc/" + d.Name() + "/cmdline")
		out = append(out, proc{strings.TrimSuffix(string(comm), "\n"), strings.TrimSpace(strings.ReplaceAll(string(cmd), "\x00", " "))})
	}
	return out, nil
}
