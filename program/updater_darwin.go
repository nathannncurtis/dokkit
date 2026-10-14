//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

const (
	updaterDir  = "/Library/Application Support/DokkitUpdater"
	updaterData = "/var/db/dokkit-updater"

	daemonPlist = "/Library/LaunchDaemons/" + launchdLabel + ".plist"
)

func exeOf(pid int) string {
	out, _ := runCmd("ps", "-p", strconv.Itoa(pid), "-o", "comm=")
	return strings.TrimSpace(string(out))
}

func findWatchers() ([]watchProc, error) {
	out, err := runCmd("ps", "-axo", "pid=,uid=,command=")
	if err != nil {
		return nil, fmt.Errorf("could not list processes: %v", err)
	}
	var found []watchProc
	for _, r := range parsePS(string(out)) {
		exe, ok := watchCommand(r.cmd)
		if !ok {
			continue
		}
		p := watchProc{Pid: r.pid, UID: r.uid, Exe: exe}
		p.User, _, _ = account(r.uid)
		if list, err := runCmd("launchctl", "asuser", strconv.Itoa(r.uid), "launchctl", "list"); err == nil {
			p.Unit = labelForPid(string(list), r.pid)
		}
		found = append(found, p)
	}
	return found, nil
}

func installTimer(exe string) (string, error) {
	c, err := readUpConfig()
	if err != nil {
		return "", err
	}
	if err := ensureNudge(c); err != nil {
		return "", err
	}
	if err := os.WriteFile(daemonPlist, []byte(launchdPlist(exe)), 0o644); err != nil {
		return "", err
	}
	if err := os.Chown(daemonPlist, 0, 0); err != nil {
		return "", err
	}
	runCmd("launchctl", "bootout", "system/"+launchdLabel)
	if out, err := runCmd("launchctl", "bootstrap", "system", daemonPlist); err != nil {
		return "", fmt.Errorf("launchctl could not load %s: %v %s", daemonPlist, err, out)
	}
	return fmt.Sprintf("the LaunchDaemon %s (%s), every five minutes", launchdLabel, daemonPlist), nil
}

// refreshSchedule rewrites an older plist and has a helper load it once this run has ended.
func refreshSchedule() {
	if !exists(daemonPlist) {
		return
	}
	c, err := readUpConfig()
	if err == nil {
		err = ensureNudge(c)
	}
	did := false
	if err == nil {
		did, err = writeIfChanged(daemonPlist, launchdPlist(where.updaterExe))
	}
	if err == nil && did {
		logf("the updater's plist was out of date; wrote it and the job is loaded again when this run ends")
		argv := launchdReload(daemonPlist)
		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		err = cmd.Start()
	}
	if err != nil {
		logf("could not bring the updater's schedule up to date: %v", err)
	}
}

func removeTimer() (string, error) {
	if !exists(daemonPlist) {
		return "no timer was found", nil
	}
	runCmd("launchctl", "bootout", "system/"+launchdLabel)
	if err := os.Remove(daemonPlist); err != nil {
		return "", err
	}
	return "the LaunchDaemon " + launchdLabel, nil
}
