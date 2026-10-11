//go:build !windows && !linux && !darwin

package main

import (
	"fmt"
	"os"
)

func serviceCommand(string) int {
	fmt.Fprintln(os.Stderr, "dokkit: installing as a service is built for Windows and Linux so far, not here.")
	return 1
}

func installedServiceConfig() string { return "" }

func ownedByService(string) error { return nil }

func finishUpdate(path string) string {
	return "To finish: stop dokkit, put that file in its place, and start it again."
}
