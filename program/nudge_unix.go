//go:build linux || darwin

package main

import (
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
)

var nudgeFile = nudgeFileFor(runtime.GOOS)

// realPoke writes the file the updater's path unit or LaunchDaemon watches. Where the updater
// made no such folder (cron, or an updater not yet upgraded) there is nothing to write to.
func realPoke() (string, error) {
	err := os.WriteFile(nudgeFile, []byte(now()+"\n"), 0o600)
	if errors.Is(err, fs.ErrNotExist) {
		return startCronUpdater()
	}
	if err != nil {
		return "", err
	}
	return "Asked the updater to check now.\n", nil
}

var cronUpdaterExe = func() string { return "" }

var isRoot = func() bool { return os.Geteuid() == 0 }

// Setsid: the updater restarts this program and must outlive it.
var startCronUpdater = func() (string, error) {
	exe := cronUpdaterExe()
	if exe == "" || !isRoot() {
		return "", errNoNudge
	}
	cmd := exec.Command(exe, "updater", "run")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return "", err
	}
	go cmd.Wait()
	return "Started the updater to check now.\n", nil
}

// ensureNudge gives the program's account a folder of its own to write the nudge file in. It
// only creates what is missing and never opens anything the account could have swapped for a link.
func ensureNudge(c upConfig) error {
	dir := filepath.Dir(nudgeFile)
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return err
	}
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
		return errors.New(dir + " is not a plain folder")
	}
	if err := os.Lchown(dir, c.UID, c.GID); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(nudgeFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if os.IsExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Chown(c.UID, c.GID)
}

// writeIfChanged writes a root-owned file only when its text differs, and says whether it did.
func writeIfChanged(path, want string) (bool, error) {
	if got, err := os.ReadFile(path); err == nil && string(got) == want {
		return false, nil
	}
	return true, os.WriteFile(path, []byte(want), 0o644)
}
