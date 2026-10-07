package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// cmdLimit is how long one program run through runCmd may take.
var cmdLimit = 30 * time.Second

// runCmd runs a program and returns what it printed on standard output. Standard error goes
// into the error, never into the output. Tests replace it.
var runCmd = func(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), cmdLimit)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if ctx.Err() != nil {
		err = fmt.Errorf("gave no answer in %s", cmdLimit)
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if said := strings.TrimSpace(string(exit.Stderr)); said != "" {
			err = fmt.Errorf("%w: %s", err, said)
		}
	}
	return out, err
}

// unitBusy is a unit that is neither up nor stopped: it is starting, reloading or stopping.
type unitBusy struct{ state string }

func (b unitBusy) Error() string { return "is " + b.state }

// unitStuck is a unit that is down in a way a restart from here would not help: it is waiting to
// be restarted by systemd after a failure, or it has been starting for too long.
type unitStuck struct{ why string }

func (s unitStuck) Error() string { return "not running (" + s.why + ")" }

// busyChecks counts the consecutive checks that found each unit starting, reloading or stopping.
var (
	busyChecks   = map[string]int{}
	busyChecksMu sync.Mutex
)

// busyLimit is how many consecutive checks may find a unit busy before it counts as down.
const busyLimit = 2

// unitState is what systemctl show says about a unit.
type unitState struct{ load, active, sub, result, restarts string }

func parseUnit(out string) unitState {
	var u unitState
	for _, l := range strings.Split(out, "\n") {
		k, v, _ := strings.Cut(strings.TrimSpace(l), "=")
		switch k {
		case "LoadState":
			u.load = v
		case "ActiveState":
			u.active = v
		case "SubState":
			u.sub = v
		case "Result":
			u.result = v
		case "NRestarts":
			u.restarts = v
		}
	}
	return u
}

// systemdActive is nil when the unit is running.
func systemdActive(name string) error {
	out, err := runCmd("systemctl", "show", "--property=LoadState,ActiveState,SubState,Result,NRestarts", "--", name)
	u := parseUnit(string(out))
	if u.active == "" {
		if err != nil {
			return fmt.Errorf("systemctl did not answer: %v", err)
		}
		return errors.New("systemctl did not answer")
	}
	key := strings.ToLower(strings.TrimSuffix(name, ".service"))
	busyChecksMu.Lock()
	defer busyChecksMu.Unlock()
	switch u.active {
	case "active":
		delete(busyChecks, key)
		return nil
	case "activating", "reloading", "deactivating":
		failed := u.result != "" && u.result != "success"
		if u.sub == "auto-restart" || failed {
			delete(busyChecks, key)
			why := "waiting to be restarted after a failure"
			if failed {
				why += ": " + u.result
			}
			if n, _ := strconv.Atoi(u.restarts); n > 0 {
				why += fmt.Sprintf(", restarted %d times", n)
			}
			return unitStuck{why}
		}
		if busyChecks[key]++; busyChecks[key] > busyLimit {
			return unitStuck{fmt.Sprintf("still %s after %d checks", u.active, busyChecks[key])}
		}
		return unitBusy{u.active}
	}
	delete(busyChecks, key)
	if u.load == "not-found" {
		return errors.New("no such unit")
	}
	if u.result != "" && u.result != "success" {
		return fmt.Errorf("not running (%s: %s)", u.active, u.result)
	}
	return fmt.Errorf("not running (%s)", u.active)
}

// restartUnit restarts a unit. Only root can, unless the system allows this account to.
func restartUnit(name string) error { return systemctl("restart", "--", name) }

func systemctl(args ...string) error {
	if out, err := runCmd("systemctl", args...); err != nil {
		if said := strings.TrimSpace(string(out)); said != "" {
			return fmt.Errorf("systemctl %s: %v: %s", args[0], err, said)
		}
		return fmt.Errorf("systemctl %s: %v", args[0], err)
	}
	return nil
}

// runningAsService is true only in the unit that dokkit service install writes.
var runningAsService = func() bool {
	return os.Getenv("INVOCATION_ID") != "" && os.Getenv("DOKKIT_CONFIG") == configFile
}

const (
	unitName = "dokkit.service"
	unitPath = "/etc/systemd/system/" + unitName
	// The system user the service runs as, and where it finds its configuration and keeps its spool.
	unitUser   = "dokkit"
	configFile = "/etc/dokkit/config.json"
	stateDir   = "/var/lib/dokkit"
)

// unitFile is the systemd unit that runs watch from the installed copy at exe.
func unitFile(exe string) string {
	return `[Unit]
Description=Dokkit
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=` + exe + ` watch
User=` + unitUser + `
Environment=DOKKIT_CONFIG=` + configFile + `
Environment=DOKKIT_SPOOL=` + stateDir + `
StateDirectory=dokkit
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
`
}

// serviceSteps are the systemctl calls for an action, in order.
func serviceSteps(action string) [][]string {
	switch action {
	case "install":
		return [][]string{{"daemon-reload"}, {"enable", "--now", unitName}}
	case "uninstall":
		return [][]string{{"disable", "--now", unitName}}
	case "update":
		return [][]string{{"restart", unitName}}
	}
	return [][]string{{action, unitName}}
}

func runSteps(action string) error {
	for _, args := range serviceSteps(action) {
		if err := systemctl(args...); err != nil {
			return err
		}
	}
	return nil
}

// stillEnrolled is said after an uninstall: the server is not told.
const stillEnrolled = "This machine is still enrolled on the server, which will report that it stopped reporting. Revoke its key on the server to end that."

// enrolmentPath is the first of the file under the home of the account that ran sudo and
// root's own configuration file that holds an address and a key. "" when neither does.
func enrolmentPath(own, sudoHome string) string {
	var paths []string
	if sudoHome != "" {
		paths = append(paths, filepath.Join(sudoHome, ".config", "dokkit", "config.json"))
	}
	paths = append(paths, own)
	for _, p := range paths {
		var s saved
		if b, err := os.ReadFile(p); err == nil && json.Unmarshal(b, &s) == nil && s.URL != "" && s.Key != "" {
			return p
		}
	}
	return ""
}

// unreadable says why a folder in the configuration cannot be listed by this account, or "".
func unreadable(folder string) string {
	if _, err := os.ReadDir(folder); err != nil {
		return err.Error()
	}
	return ""
}

// othersCannotRead says why an account that owns nothing here may not be able to list path, or "".
func othersCannotRead(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err.Error()
	}
	for dir := abs; ; dir = filepath.Dir(dir) {
		fi, err := os.Stat(dir)
		if err != nil {
			return err.Error()
		}
		need := os.FileMode(0o001)
		if dir == abs {
			need = 0o005
		}
		if fi.Mode().Perm()&need != need {
			return dir + " is closed to other accounts"
		}
		if dir == filepath.Dir(dir) {
			return ""
		}
	}
}
