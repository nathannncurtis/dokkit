//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func machineDir() string { return "" }

func asService() bool { return false }

func detach(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }

func startup(bool) error {
	return errors.New("starting at sign-in is built for Windows so far. Elsewhere, add dokkit watch --background to your desktop's startup programs")
}

func memoryUsed() (float64, bool) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, false
	}
	kb := map[string]float64{}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 2 {
			kb[f[0]], _ = strconv.ParseFloat(f[1], 64)
		}
	}
	total := kb["MemTotal:"]
	return 100 * (total - kb["MemAvailable:"]) / total, total > 0
}

func cpuTimes() (idle, total uint64, ok bool) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	for i, f := range strings.Fields(line) {
		n, _ := strconv.ParseUint(f, 10, 64)
		total += n
		// The fourth and fifth numbers are idle and waiting on a disk.
		if i == 4 || i == 5 {
			idle += n
		}
	}
	return idle, total, total > 0
}

func findDisks() (all []found) {
	for _, l := range output("df", "-P", "-k") {
		f := strings.Fields(l)
		if len(f) < 6 || !strings.HasPrefix(f[0], "/dev/") {
			continue
		}
		total, _ := strconv.ParseInt(f[1], 10, 64)
		free, _ := strconv.ParseInt(f[3], 10, 64)
		all = append(all, found{"mount": f[5], "total_gb": fmt.Sprint(total >> 20), "free_gb": fmt.Sprint(free >> 20), "total_bytes": fmt.Sprint(total << 10), "free_bytes": fmt.Sprint(free << 10)})
	}
	return
}

func serviceCommand(string) int {
	fmt.Fprintln(os.Stderr, "dokkit: installing as a service is built for Windows so far. Elsewhere, run dokkit watch from a systemd unit.")
	return 1
}

func finishUpdate(path string) string {
	return "To finish: stop dokkit, put that file in its place, and start it again."
}
