//go:build !windows && !linux

package main

import (
	"fmt"
	"os"
)

func serviceCommand(string) int {
	fmt.Fprintln(os.Stderr, "dokkit: installing as a service is built for Windows and Linux so far, not macOS. On macOS, run dokkit watch from a launchd job.")
	return 1
}

func finishUpdate(path string) string {
	return "To finish: stop dokkit, put that file in its place, and start it again."
}
