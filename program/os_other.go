//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func machineDir() string { return "" }

// listsPath is the file naming the services this machine may start and the hosts it may reach,
// used only while root owns it and the folder and nobody else can write to either.
func listsPath() string {
	const p = "/etc/dokkit/config.json"
	for _, f := range []string{p, filepath.Dir(p)} {
		fi, err := os.Stat(f)
		if err != nil {
			return ""
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 || fi.Mode().Perm()&0o022 != 0 {
			return ""
		}
	}
	return p
}

// Run as root, a task would be root whatever it was accepted as, so only a task accepted for the system account runs.
func init() {
	if os.Geteuid() == 0 {
		ordinary = func(*exec.Cmd) (func(), error) {
			return nil, errors.New("dokkit is running as root and tasks cannot be dropped to another account; accept the task as the system account or run dokkit as an ordinary user")
		}
	}
}

func asService() bool { return false }

// taskFolderProblem refuses, when running as root, a task whose folder or script files anyone
// else owns or can write.
func taskFolderProblem(dir string, files []string) error {
	if os.Geteuid() != 0 {
		return nil
	}
	return rootProblem(dir, files)
}

func rootProblem(dir string, files []string) error {
	for _, p := range append([]string{dir}, files...) {
		fi, err := os.Stat(p)
		if err != nil {
			return err
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 || fi.Mode().Perm()&0o022 != 0 {
			return fmt.Errorf("%s is not owned by root or can be written by others, so a task is not run from it as root.", p)
		}
	}
	return nil
}

// fileIdentity names the file itself, whatever its path: the device and the inode.
func fileIdentity(f *os.File) string {
	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return fmt.Sprintf("%v:%v", st.Dev, st.Ino)
	}
	return ""
}

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

