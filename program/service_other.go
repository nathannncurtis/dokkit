//go:build !windows

package main

import (
	"fmt"
	"os"
)

func machineDir() string { return "" }

func asService() bool { return false }

func serviceCommand(string) int {
	fmt.Fprintln(os.Stderr, "dokkit: installing as a service is built for Windows so far. Elsewhere, run dokkit watch from a systemd unit.")
	return 1
}
