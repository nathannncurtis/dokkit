//go:build !windows

package main

import (
	"fmt"
	"os"
)

func realLayout() layout { return layout{} }
func realHost() hostOps  { return hostOps{} }

func updaterCommand([]string) int {
	fmt.Fprintln(os.Stderr, "dokkit: the updater is built for Windows so far.")
	return 1
}
