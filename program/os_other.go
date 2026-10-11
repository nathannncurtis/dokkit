//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

func machineDir() string { return "" }

// refuseFolders is true in the installed service when its configuration is in a file or folder
// anyone but root can write, so the folders it names are not read.
func refuseFolders() bool { return runningAsService() && listsPath() == "" }

// serviceFiles are the installed service's configuration file and spool folder, where there is one.
func serviceFiles() (string, string) {
	if runtime.GOOS == "linux" {
		return configFile, stateDir
	}
	if runtime.GOOS == "darwin" {
		return macConfigFile, macStateDir
	}
	return "", ""
}

// listsPath is the file naming the services this machine may start and the hosts it may reach,
// used only while root owns it and the folder and nobody else can write to either.
func listsPath() string {
	p := "/etc/dokkit/config.json"
	if runtime.GOOS == "darwin" {
		p = macConfigFile
	}
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

func asService() bool { return false }

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
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

func lockFile(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return func() { f.Close() }, nil
}

func detach(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }

func startup(bool) error {
	return errors.New("starting at sign-in is built for Windows so far. Elsewhere, add dokkit watch --background to your desktop's startup programs")
}

func memoryUsed() (float64, bool) {
	if runtime.GOOS == "darwin" {
		return macMemoryUsed()
	}
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
	if runtime.GOOS == "darwin" {
		return macCPUTimes()
	}
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

func findDisks() []found { return disksFrom(output("df", "-P", "-k")) }

var apfsSlice = regexp.MustCompile(`^(/dev/disk\d+)s\d+.*`)

// A disk is listed once however many mounts show it: the volumes of an APFS container (the
// first, "/", stands for it) and bind mounts and subvolumes of one device all report one disk.
// The helper volumes macOS mounts under /System/Volumes and the Recovery volume, and the
// read-only loop devices of snap packages, are not disks anyone fills.
func disksFrom(lines []string) (all []found) {
	seen := map[string]bool{}
	for _, l := range lines {
		f := strings.Fields(l)
		if len(f) < 6 || !strings.HasPrefix(f[0], "/dev/") || strings.HasPrefix(f[0], "/dev/loop") ||
			strings.HasPrefix(f[5], "/System/Volumes/") || f[5] == "/Volumes/Recovery" {
			continue
		}
		device := apfsSlice.ReplaceAllString(f[0], "$1")
		if seen[device] {
			continue
		}
		seen[device] = true
		total, _ := strconv.ParseInt(f[1], 10, 64)
		free, _ := strconv.ParseInt(f[3], 10, 64)
		all = append(all, found{"mount": f[5], "total_gb": fmt.Sprint(total >> 20), "free_gb": fmt.Sprint(free >> 20), "total_bytes": fmt.Sprint(total << 10), "free_bytes": fmt.Sprint(free << 10)})
	}
	return
}
