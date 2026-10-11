package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"
)

const (
	methodSystemUnit  = "system-unit"
	methodUserUnit    = "user-unit"
	methodLaunchAgent = "launch-agent"
	methodProcess     = "process"

	timerName    = "dokkit-updater"
	launchdLabel = "com.dokkit.updater"
	cronMarker   = "# dokkit-updater"
)

// carriedEnv is what a restarted background program gets back from the one it replaces.
var carriedEnv = []string{"DOKKIT_CONFIG", "DOKKIT_SPOOL", "DOKKIT_SPOOL_MB", "DOKKIT_FOLDERS", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"}

// upConfig is what the updater keeps about the program it looks after. It holds no key.
type upConfig struct {
	Method  string            `json:"method"`
	Program string            `json:"program"`
	User    string            `json:"user"`
	UID     int               `json:"uid"`
	GID     int               `json:"gid"`
	Home    string            `json:"home"`
	Unit    string            `json:"unit,omitempty"`
	Config  string            `json:"config"`
	Spool   string            `json:"spool"`
	Env     map[string]string `json:"env,omitempty"`
}

func (c upConfig) encode() []byte { b, _ := json.MarshalIndent(c, "", "  "); return append(b, '\n') }

func decodeUpConfig(b []byte) (c upConfig, err error) {
	if err = json.Unmarshal(b, &c); err == nil && (c.Method == "" || c.Program == "") {
		err = errors.New("the updater's config.json names no program")
	}
	return c, err
}

// watchProc is a running dokkit watch.
type watchProc struct {
	Pid, UID    int
	User, Exe   string
	Env         map[string]string
	Scope, Unit string // the systemd manager ("system" or "user") and unit whose main process this is, or the launchd label
}

func defaultConfig(goos, home string, env map[string]string) string {
	if goos == "darwin" {
		return path.Join(home, "Library", "Application Support", "dokkit", "config.json")
	}
	if x := env["XDG_CONFIG_HOME"]; x != "" {
		return path.Join(x, "dokkit", "config.json")
	}
	return path.Join(home, ".config", "dokkit", "config.json")
}

func defaultSpool(goos, home string, env map[string]string) string {
	if goos == "darwin" {
		return path.Join(home, "Library", "Caches", "dokkit", "spool")
	}
	if x := env["XDG_CACHE_HOME"]; x != "" {
		return path.Join(x, "dokkit", "spool")
	}
	return path.Join(home, ".cache", "dokkit", "spool")
}

func buildConfig(goos string, p watchProc, home string, gid int) upConfig {
	c := upConfig{Method: methodProcess, Program: p.Exe, User: p.User, UID: p.UID, GID: gid, Home: home, Env: map[string]string{}}
	switch {
	case p.Scope == "system":
		c.Method, c.Unit = methodSystemUnit, p.Unit
	case p.Scope == "user":
		c.Method, c.Unit = methodUserUnit, p.Unit
	case p.Unit != "":
		c.Method, c.Unit = methodLaunchAgent, p.Unit
	}
	for _, k := range carriedEnv {
		if v := p.Env[k]; v != "" {
			c.Env[k] = v
		}
	}
	if c.Config = c.Env["DOKKIT_CONFIG"]; c.Config == "" {
		c.Config = defaultConfig(goos, home, c.Env)
	}
	if c.Spool = c.Env["DOKKIT_SPOOL"]; c.Spool == "" {
		c.Spool = defaultSpool(goos, home, c.Env)
	}
	return c
}

// chooseProgram picks the program to look after: one run by a system unit, else one run by the
// account that ran sudo, else the only one there is.
func chooseProgram(ps []watchProc, sudoUser string) (watchProc, error) {
	var system, mine, rest []watchProc
	seen := map[string]bool{}
	for _, p := range ps {
		key := fmt.Sprint(p.UID, p.Exe, p.Unit)
		if seen[key] {
			continue
		}
		seen[key] = true
		switch {
		case p.Scope == "system":
			system = append(system, p)
		case sudoUser != "" && p.User == sudoUser:
			mine = append(mine, p)
		default:
			rest = append(rest, p)
		}
	}
	for _, group := range [][]watchProc{system, mine, rest} {
		switch len(group) {
		case 0:
			continue
		case 1:
			return group[0], nil
		}
		var names []string
		for _, p := range group {
			names = append(names, fmt.Sprintf("%s run by %s (process %d)", p.Exe, p.User, p.Pid))
		}
		return watchProc{}, fmt.Errorf("more than one dokkit program is running here and the updater looks after one: %s. Stop the ones it should leave alone, then install again", strings.Join(names, "; "))
	}
	return watchProc{}, errors.New("no dokkit program is running on this machine for the updater to look after. Start it (dokkit watch --background, or dokkit service install), then install the updater")
}

// unitFromCgroup is the systemd manager and service unit a process's cgroup file puts it in.
func unitFromCgroup(cgroup string) (scope, unit string) {
	for _, l := range strings.Split(cgroup, "\n") {
		parts := strings.SplitN(l, ":", 3)
		if len(parts) != 3 || parts[1] != "" && !strings.Contains(parts[1], "name=systemd") {
			continue
		}
		segs := strings.Split(strings.Trim(parts[2], "/"), "/")
		last := segs[len(segs)-1]
		if !strings.HasSuffix(last, ".service") || strings.HasPrefix(last, "user@") {
			return "", ""
		}
		scope = "system"
		for _, s := range segs {
			if strings.HasPrefix(s, "user@") {
				scope = "user"
			}
		}
		return scope, last
	}
	return "", ""
}

func parseEnviron(b []byte) map[string]string {
	env := map[string]string{}
	for _, kv := range strings.Split(string(b), "\x00") {
		if k, v, ok := strings.Cut(kv, "="); ok {
			env[k] = v
		}
	}
	return env
}

// labelForPid is the launchd label of the job running a process, from launchctl list.
func labelForPid(list string, pid int) string {
	for _, l := range strings.Split(list, "\n") {
		if f := strings.Fields(l); len(f) == 3 && f[0] == strconv.Itoa(pid) {
			return f[2]
		}
	}
	return ""
}

// watchCommand is the program file in a command line of the form "<file> watch ...".
func watchCommand(cmd string) (string, bool) {
	i := strings.LastIndex(cmd, " watch")
	if i <= 0 {
		return "", false
	}
	if rest := cmd[i+len(" watch"):]; rest != "" && rest[0] != ' ' {
		return "", false
	}
	exe := cmd[:i]
	return exe, strings.HasPrefix(path.Base(exe), "dokkit") && path.IsAbs(exe)
}

type psRow struct {
	pid, uid int
	cmd      string
}

// parsePS reads the output of ps -axo pid=,uid=,command=.
func parsePS(out string) (rows []psRow) {
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		uid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		cmd := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(l), f[0])), f[1]))
		rows = append(rows, psRow{pid, uid, cmd})
	}
	return rows
}

// pidIsProgram is true when the file a process runs is the program file; a process started
// before its file was replaced is shown with " (deleted)" after the name.
func pidIsProgram(exe, program string) bool {
	return exe != "" && path.Clean(strings.TrimSuffix(exe, " (deleted)")) == path.Clean(program)
}

func userSystemctl(c upConfig, verb ...string) []string {
	rt := fmt.Sprintf("/run/user/%d", c.UID)
	argv := []string{"runuser", "-u", c.User, "--", "env", "XDG_RUNTIME_DIR=" + rt, "DBUS_SESSION_BUS_ADDRESS=unix:path=" + rt + "/bus", "systemctl", "--user"}
	return append(append(argv, verb...), "--", c.Unit)
}

// restartArgv restarts a program that a unit or launchd job keeps, or is nil for a plain process.
func restartArgv(c upConfig) []string {
	switch c.Method {
	case methodSystemUnit:
		return []string{"systemctl", "restart", "--", c.Unit}
	case methodUserUnit:
		return userSystemctl(c, "restart")
	case methodLaunchAgent:
		return []string{"launchctl", "kickstart", "-k", fmt.Sprintf("gui/%d/%s", c.UID, c.Unit)}
	}
	return nil
}

// restartLimit: launchd holds a kickstart of a job that started within its throttle interval until it ends.
func restartLimit(c upConfig, limit time.Duration) time.Duration {
	if c.Method == methodLaunchAgent {
		return max(limit, 2*time.Minute)
	}
	return limit
}

// activeArgv asks whether that unit or job is running.
func activeArgv(c upConfig) []string {
	switch c.Method {
	case methodSystemUnit:
		return []string{"systemctl", "is-active", "--", c.Unit}
	case methodUserUnit:
		return userSystemctl(c, "is-active")
	case methodLaunchAgent:
		return []string{"launchctl", "print", fmt.Sprintf("gui/%d/%s", c.UID, c.Unit)}
	}
	return nil
}

func isRunning(method, out string) bool {
	if method == methodLaunchAgent {
		return strings.Contains(out, "state = running")
	}
	return strings.TrimSpace(out) == "active"
}

// childEnv is the environment a plain background program is started with.
func childEnv(c upConfig) []string {
	env := []string{"HOME=" + c.Home, "USER=" + c.User, "LOGNAME=" + c.User, "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
	for _, k := range carriedEnv {
		if v := c.Env[k]; v != "" {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// The unit pair for systems that run systemd. KillMode=process lets a program the updater
// started for a plain background install outlive the run that started it.
func timerService(exe string) string {
	return "[Unit]\nDescription=Dokkit updater\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=" + exe + " updater run\nKillMode=process\n"
}

func timerUnit() string {
	return "[Unit]\nDescription=Dokkit updater, every five minutes\n\n[Timer]\nOnBootSec=1min\nOnActiveSec=1min\nOnUnitInactiveSec=5min\n\n[Install]\nWantedBy=timers.target\n"
}

func launchdPlist(exe string) string {
	esc := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(exe)
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>` + launchdLabel + `</string>
  <key>ProgramArguments</key>
  <array><string>` + esc + `</string><string>updater</string><string>run</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
`
}

func cronLine(exe string) string {
	return "*/5 * * * * " + exe + " updater run >/dev/null 2>&1 " + cronMarker
}

// dropCron removes the updater's line, and any copy of it, from a crontab.
func dropCron(tab string) string {
	var keep []string
	for _, l := range strings.Split(strings.TrimRight(tab, "\n"), "\n") {
		if !strings.Contains(l, cronMarker) {
			keep = append(keep, l)
		}
	}
	if len(keep) == 0 || len(keep) == 1 && keep[0] == "" {
		return ""
	}
	return strings.Join(keep, "\n") + "\n"
}

func addCron(tab, line string) string {
	tab = dropCron(tab)
	if tab != "" && !strings.HasSuffix(tab, "\n") {
		tab += "\n"
	}
	return tab + line + "\n"
}
