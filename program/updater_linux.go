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

const volumeFolder = ".dokkit-updater"

var (
	timerServicePath = "/etc/systemd/system/" + timerName + ".service"
	timerUnitPath    = "/etc/systemd/system/" + timerName + ".timer"
	pathUnitPath     = "/etc/systemd/system/" + timerName + ".path"
)

var qnapCrontab = "/etc/config/crontab"

var updaterDir, updaterData = locateUpdater()

// On QNAP the root file system is emptied at every restart, so the updater lives on the data
// volume and its crontab line, which survives, is what says where.
func locateUpdater() (dir, data string) {
	if b, err := os.ReadFile(qnapCrontab); err == nil {
		if dir = filepath.Dir(cronExe(string(b))); filepath.Base(filepath.Dir(dir)) == volumeFolder {
			return dir, filepath.Join(filepath.Dir(dir), "data")
		}
	}
	return "/usr/local/lib/dokkit-updater", "/var/lib/dokkit-updater"
}

func init() {
	placeUpdater = placeOnVolume
	cronUpdaterExe = rootCronExe
}

func rootCronExe() string {
	if b, err := os.ReadFile(qnapCrontab); err == nil {
		return cronExe(string(b))
	}
	if _, err := exec.LookPath("crontab"); err != nil {
		return ""
	}
	out, _ := runCmd("crontab", "-l")
	return cronExe(string(out))
}

func placeOnVolume(c upConfig) error {
	if !exists(qnapCrontab) || systemdRunning() {
		return nil
	}
	mounts, _ := os.ReadFile("/proc/mounts")
	vol := mountOf(c.Program, parseMounts(string(mounts)))
	if vol == "/" {
		return fmt.Errorf("%s is on the root file system, which this machine empties at every restart, so the updater has nowhere lasting to live beside it. Nothing was changed. Keep the program on a data volume, then install again", c.Program)
	}
	root := filepath.Join(vol, volumeFolder)
	if exists(root) {
		if err := rootOnly(root); err != nil {
			return err
		}
		es, err := os.ReadDir(root)
		if err != nil {
			return err
		}
		for _, e := range es {
			if e.Name() != "program" && e.Name() != "data" {
				return fmt.Errorf("%s holds %s, which the updater did not put there. Nothing was changed. Move that out, then install again", root, e.Name())
			}
		}
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return err
	}
	updaterDir, updaterData = filepath.Join(root, "program"), filepath.Join(root, "data")
	upConfigPath = filepath.Join(updaterDir, "config.json")
	return nil
}

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
		if _, err := syncUnits(exe); err != nil {
			return "", err
		}
		if err := systemctl("enable", "--now", timerName+".timer"); err != nil {
			return "", err
		}
		return fmt.Sprintf("the systemd timer %s.timer, every five minutes, and %s.path, when the program asks (in %s)", timerName, timerName, filepath.Dir(timerUnitPath)), nil
	}
	where, _, err := editCrontab(func(tab string) string { return addCron(tab, cronLine(exe)) })
	if err != nil {
		return "", err
	}
	return "a root crontab line in " + where + ", every five minutes", nil
}

// syncUnits makes the three units the current text and the path unit enabled, and returns the files it changed.
func syncUnits(exe string) (changed []string, err error) {
	c, err := readUpConfig()
	if err != nil {
		return nil, err
	}
	if err := ensureNudge(c); err != nil {
		return nil, err
	}
	for _, u := range []struct{ path, want string }{{timerServicePath, timerService(exe)}, {timerUnitPath, timerUnit()}, {pathUnitPath, pathUnit()}} {
		did, err := writeIfChanged(u.path, u.want)
		if err != nil {
			return changed, err
		}
		if did {
			changed = append(changed, filepath.Base(u.path))
		}
	}
	if len(changed) > 0 {
		if err := systemctl("daemon-reload"); err != nil {
			return changed, err
		}
	}
	if out, _ := runCmd("systemctl", "is-active", pathUnitName); len(changed) > 0 || strings.TrimSpace(string(out)) != "active" {
		return changed, systemctl("enable", "--now", pathUnitName)
	}
	return changed, nil
}

// refreshSchedule brings a systemd updater installed before the nudge to the current units. The
// running job is not touched: a daemon-reload leaves a running service alone.
func refreshSchedule() {
	if !systemdRunning() || !exists(timerUnitPath) {
		return
	}
	changed, err := syncUnits(where.updaterExe)
	if len(changed) > 0 {
		logf("the updater's schedule was out of date; wrote %s", strings.Join(changed, ", "))
	}
	if err != nil {
		logf("could not bring the updater's schedule up to date: %v", err)
	}
}

func removeTimer() (string, error) {
	var gone []string
	if exists(timerUnitPath) || exists(timerServicePath) || exists(pathUnitPath) {
		runCmd("systemctl", "disable", "--now", pathUnitName)
		runCmd("systemctl", "disable", "--now", timerName+".timer")
		for _, p := range []string{pathUnitPath, timerUnitPath, timerServicePath} {
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
// Where /etc/config/crontab exists (QNAP) that file is the one cron reads. Loading it is enough: QNAP's
// "crond.sh restart" rewrites and reorders the other lines of that file, so it is never run.
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
