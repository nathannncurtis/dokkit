//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const (
	updaterDir  = "/usr/local/lib/dokkit-updater"
	updaterData = "/var/lib/dokkit-updater"

	timerServicePath = "/etc/systemd/system/" + timerName + ".service"
	timerUnitPath    = "/etc/systemd/system/" + timerName + ".timer"
	qnapCrontab      = "/etc/config/crontab"
)

var errNoCron = errors.New("this machine has neither a running systemd nor a crontab command, so there is nothing to run the updater from")

func exeOf(pid int) string {
	p, _ := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	return p
}

// mainProcessOf is true when the unit's main process is pid, so a program started by cron or a
// script is not mistaken for the unit that merely contains it.
func mainProcessOf(p watchProc) bool {
	argv := []string{"systemctl", "show", "--property=MainPID", "--value", "--", p.Unit}
	if p.Scope == "user" {
		argv = userSystemctl(upConfig{User: p.User, UID: p.UID, Unit: p.Unit}, "show", "--property=MainPID", "--value")
	}
	out, err := runCmd(argv[0], argv[1:]...)
	n, _ := strconv.Atoi(strings.TrimSpace(string(out)))
	return err == nil && n == p.Pid
}

func findWatchers() ([]watchProc, error) {
	dirs, _ := filepath.Glob("/proc/[0-9]*")
	var out []watchProc
	for _, d := range dirs {
		cmdline, err := os.ReadFile(d + "/cmdline")
		args := strings.Split(strings.TrimRight(string(cmdline), "\x00"), "\x00")
		if err != nil || len(args) < 2 || args[1] != "watch" {
			continue
		}
		pid, _ := strconv.Atoi(filepath.Base(d))
		exe := strings.TrimSuffix(exeOf(pid), " (deleted)")
		fi, err := os.Stat(d)
		if err != nil || !strings.HasPrefix(filepath.Base(exe), "dokkit") {
			continue
		}
		st, _ := fi.Sys().(*syscall.Stat_t)
		p := watchProc{Pid: pid, UID: int(st.Uid), Exe: exe}
		p.User, _, _ = account(p.UID)
		if b, err := os.ReadFile(d + "/environ"); err == nil {
			p.Env = parseEnviron(b)
		}
		if b, err := os.ReadFile(d + "/cgroup"); err == nil {
			if p.Scope, p.Unit = unitFromCgroup(string(b)); p.Scope != "" && !mainProcessOf(p) {
				p.Scope, p.Unit = "", ""
			}
		}
		out = append(out, p)
	}
	if len(out) == 0 && exists(unitPath) {
		p := watchProc{User: unitUser, Exe: installedExe, Scope: "system", Unit: unitName, Env: map[string]string{"DOKKIT_CONFIG": configFile, "DOKKIT_SPOOL": stateDir}}
		if u, err := user.Lookup(unitUser); err == nil {
			p.UID, _ = strconv.Atoi(u.Uid)
		}
		out = append(out, p)
	}
	return out, nil
}

func systemdRunning() bool {
	fi, err := os.Stat("/run/systemd/system")
	return err == nil && fi.IsDir()
}

func installTimer(exe string) (string, error) {
	if systemdRunning() {
		if err := os.WriteFile(timerServicePath, []byte(timerService(exe)), 0o644); err != nil {
			return "", err
		}
		if err := os.WriteFile(timerUnitPath, []byte(timerUnit()), 0o644); err != nil {
			return "", err
		}
		for _, args := range [][]string{{"daemon-reload"}, {"enable", "--now", timerName + ".timer"}} {
			if err := systemctl(args...); err != nil {
				return "", err
			}
		}
		return fmt.Sprintf("the systemd timer %s.timer, every five minutes (%s and %s)", timerName, timerUnitPath, timerServicePath), nil
	}
	where, _, err := editCrontab(func(tab string) string { return addCron(tab, cronLine(exe)) })
	if err != nil {
		return "", err
	}
	return "a root crontab line in " + where + ", every five minutes", nil
}

func removeTimer() (string, error) {
	var gone []string
	if exists(timerUnitPath) || exists(timerServicePath) {
		runCmd("systemctl", "disable", "--now", timerName+".timer")
		for _, p := range []string{timerUnitPath, timerServicePath} {
			if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
				return "", err
			}
		}
		runCmd("systemctl", "daemon-reload")
		gone = append(gone, "the systemd timer")
	}
	where, changed, err := editCrontab(dropCron)
	if err != nil && !errors.Is(err, errNoCron) {
		return "", err
	}
	if changed {
		gone = append(gone, "the crontab line in "+where)
	}
	if len(gone) == 0 {
		return "no timer was found", nil
	}
	return strings.Join(gone, " and "), nil
}

// editCrontab rewrites root's crontab with edit and reports where it is and whether it changed.
// Where /etc/config/crontab exists (QNAP) that file is the one cron reads, and cron is told to reread it.
func editCrontab(edit func(string) string) (where string, changed bool, err error) {
	if b, rerr := os.ReadFile(qnapCrontab); rerr == nil {
		next := edit(string(b))
		if next == string(b) {
			return qnapCrontab, false, nil
		}
		if err := os.WriteFile(qnapCrontab, []byte(next), 0o644); err != nil {
			return "", false, err
		}
		if out, err := runCmd("crontab", qnapCrontab); err != nil {
			return "", false, fmt.Errorf("crontab %s: %v %s", qnapCrontab, err, out)
		}
		if exists("/etc/init.d/crond.sh") {
			runCmd("/etc/init.d/crond.sh", "restart")
		}
		return qnapCrontab, true, nil
	}
	if _, err := exec.LookPath("crontab"); err != nil {
		return "", false, errNoCron
	}
	out, err := runCmd("crontab", "-l")
	if err != nil && !strings.Contains(err.Error(), "no crontab") {
		return "", false, fmt.Errorf("could not read root's crontab: %v", err)
	}
	next := edit(string(out))
	if next == string(out) {
		return "root's crontab", false, nil
	}
	cmd := exec.Command("crontab", "-")
	cmd.Stdin = strings.NewReader(next)
	if b, err := cmd.CombinedOutput(); err != nil {
		return "", false, fmt.Errorf("could not write root's crontab: %v %s", err, b)
	}
	return "root's crontab", true, nil
}
