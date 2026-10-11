package main

import (
	"errors"
	"runtime"
	"strings"
)

// proc is a running process: its program's file name and the text command_has looks in.
// On Windows the text is the full executable path; elsewhere it is the whole command line.
type proc struct{ name, text string }

// matchProcess says whether a process called name, with has in its text, is in ps.
// A process whose text could not be read has none, so it matches only when has is empty.
func matchProcess(ps []proc, name, has string) bool { return countProcesses(ps, name, has) > 0 }

// countProcesses is how many processes in ps are called name and have has in their text.
func countProcesses(ps []proc, name, has string) int {
	has = flatten(has)
	n := 0
	for _, p := range ps {
		same := p.name == name
		if runtime.GOOS == "windows" {
			same = strings.EqualFold(p.name, name)
		}
		if same && strings.Contains(flatten(p.text), has) {
			n++
		}
	}
	return n
}

func flatten(s string) string { return strings.ToLower(strings.ReplaceAll(s, `\`, "/")) }

func processWithText(name, has string) (int, error) {
	if runtime.GOOS == "linux" && len(name) > 15 {
		name = name[:15] // the kernel keeps only this much of a process's name
	}
	ps, err := listProcesses()
	if err != nil {
		return 0, cannotTell{"this account may not list processes"}
	}
	n := countProcesses(ps, name, has)
	if n == 0 {
		return 0, errors.New("not running")
	}
	return n, nil
}
