package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// cmdLimit is how long one program run through runCmd may take.
var cmdLimit = 30 * time.Second

// runCmd runs a program and returns what it printed. Tests replace it.
var runCmd = func(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), cmdLimit)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if ctx.Err() != nil {
		err = fmt.Errorf("gave no answer in %s", cmdLimit)
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		out = append(out, exit.Stderr...)
	}
	return out, err
}

// unitBusy is a unit that is neither up nor stopped: it is starting, reloading or stopping.
type unitBusy struct{ state string }

func (b unitBusy) Error() string { return "is " + b.state }

// systemdActive is nil when the unit is running.
func systemdActive(name string) error {
	out, err := runCmd("systemctl", "is-active", "--", name)
	state := strings.TrimSpace(string(out))
	switch {
	case err == nil && state == "active":
		return nil
	case state == "reloading", state == "activating", state == "deactivating":
		return unitBusy{state}
	case state == "":
		return errors.New("systemctl did not answer")
	case state == "inactive":
		if load, _ := runCmd("systemctl", "show", "--property=LoadState", "--value", "--", name); strings.TrimSpace(string(load)) == "not-found" {
			return errors.New("no such unit")
		}
	}
	return fmt.Errorf("not running (%s)", state)
}

// restartUnit restarts a unit. Only root can, unless the system allows this account to.
func restartUnit(name string) error { return systemctl("restart", "--", name) }

func systemctl(args ...string) error {
	if out, err := runCmd("systemctl", args...); err != nil {
		return fmt.Errorf("systemctl %s: %v: %s", args[0], err, strings.TrimSpace(string(out)))
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

// enrolmentPath is the first of the person's own configuration file and the one under the home
// of the account that ran sudo that holds an address and a key. "" when neither does.
func enrolmentPath(own, sudoHome string) string {
	paths := []string{own}
	if sudoHome != "" {
		paths = append(paths, filepath.Join(sudoHome, ".config", "dokkit", "config.json"))
	}
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
