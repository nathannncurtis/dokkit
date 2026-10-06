package main

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// runCmd runs a program and returns what it printed. Tests replace it.
var runCmd = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

// systemdActive is nil when the unit is running.
func systemdActive(name string) error {
	out, err := runCmd("systemctl", "is-active", "--", name)
	state := strings.TrimSpace(string(out))
	switch {
	case err == nil && state == "active":
		return nil
	case state == "":
		return errors.New("systemctl did not answer")
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
