package main

import (
	"context"
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// portsNote is set when the macOS port list could not be read, so the proposal says so.
var portsNote string

const noteLsof = "The listening ports could not be read: lsof is missing or failed, so no ports were found."

// lsofOutput lists listening TCP ports with lsof. Run as an ordinary user it sees only that account's own processes.
func lsofOutput() []string {
	portsNote = ""
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "lsof", "-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcnL").Output()
	var exit *exec.ExitError
	if err != nil && !(errors.As(err, &exit) && exit.ExitCode() == 1) {
		portsNote = noteLsof
		return nil
	}
	return strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n")
}

// lsofPorts reads lsof -F lines: p starts a process, c is its command, n is a listening address.
func lsofPorts(lines []string, add func(local, program string, owner func() (string, string))) {
	program := ""
	for _, l := range lines {
		if l == "" {
			continue
		}
		switch l[0] {
		case 'p':
			program = ""
		case 'c':
			program = l[1:]
		case 'n':
			local := l[1:]
			if i := strings.LastIndex(local, ":"); i >= 0 && program != "" {
				if _, err := strconv.ParseUint(local[i+1:], 10, 16); err == nil {
					add(local, program, func() (string, string) { return originYours, "owner not known" })
				}
			}
		}
	}
}
