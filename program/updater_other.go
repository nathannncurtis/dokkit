//go:build !windows && !linux && !darwin

package main

import (
	"fmt"
	"os"
)

func realLayout() layout { return layout{} }
func realHost() hostOps  { return hostOps{} }

func keepOwner(tmp, ref string) error { return nil }

func syncDir(string) {}

func updaterCommand([]string) int {
	fmt.Fprintln(os.Stderr, "dokkit: the updater is built for Windows, Linux and macOS.")
	return 1
}
