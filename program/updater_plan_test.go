package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLaunchdRestartMayWaitOutTheThrottle(t *testing.T) {
	if got := restartLimit(upConfig{Method: methodLaunchAgent}, 30*time.Second); got < time.Minute+30*time.Second {
		t.Errorf("a kickstart held by launchd's throttle needs more than %v", got)
	}
	if got := restartLimit(upConfig{Method: methodSystemUnit}, 30*time.Second); got != 30*time.Second {
		t.Errorf("%v", got)
	}
}

func TestUpConfigRoundTrip(t *testing.T) {
	in := buildConfig("linux", watchProc{Pid: 7, UID: 1001, User: "rweb", Exe: "/home/rweb/dokkit", Env: map[string]string{"DOKKIT_CONFIG": "/srv/c.json", "DOKKIT_SPOOL": "/srv/spool", "DOKKIT_KEY": "secret", "FOO": "x"}}, "/home/rweb", 1001)
	out, err := decodeUpConfig(in.encode())
	if err != nil || out.Method != methodProcess || out.Program != "/home/rweb/dokkit" || out.Config != "/srv/c.json" || out.Spool != "/srv/spool" || out.GID != 1001 {
		t.Fatalf("%+v %v", out, err)
	}
	if strings.Contains(string(in.encode()), "secret") || len(out.Env) != 2 {
		t.Fatalf("only the named variables are kept: %+v", out.Env)
	}
	if _, err := decodeUpConfig([]byte(`{"method":"process"}`)); err == nil {
		t.Fatal("a config with no program is refused")
	}
}

func TestBuildConfigMethodsAndDefaults(t *testing.T) {
	for _, c := range []struct {
		goos   string
		p      watchProc
		method string
		config string
		spool  string
	}{
		{"linux", watchProc{Scope: "system", Unit: "dokkit.service", Env: map[string]string{"DOKKIT_CONFIG": "/etc/dokkit/config.json"}}, methodSystemUnit, "/etc/dokkit/config.json", "/home/u/.cache/dokkit/spool"},
		{"linux", watchProc{Scope: "user", Unit: "d.service"}, methodUserUnit, "/home/u/.config/dokkit/config.json", "/home/u/.cache/dokkit/spool"},
		{"linux", watchProc{Env: map[string]string{"XDG_CONFIG_HOME": "/x/cfg", "XDG_CACHE_HOME": "/x/cache"}}, methodProcess, "/x/cfg/dokkit/config.json", "/x/cache/dokkit/spool"},
		{"darwin", watchProc{Unit: "com.me.dokkit"}, methodLaunchAgent, "/home/u/Library/Application Support/dokkit/config.json", "/home/u/Library/Caches/dokkit/spool"},
		{"darwin", watchProc{}, methodProcess, "/home/u/Library/Application Support/dokkit/config.json", "/home/u/Library/Caches/dokkit/spool"},
	} {
		got := buildConfig(c.goos, c.p, "/home/u", 20)
		if got.Method != c.method || got.Config != c.config || got.Spool != c.spool {
			t.Errorf("%s %+v: %+v", c.goos, c.p, got)
		}
		if got.Method == methodProcess && got.Unit != "" {
			t.Errorf("a plain process has no unit: %+v", got)
		}
	}
}

func TestChooseProgram(t *testing.T) {
	sys := watchProc{Pid: 1, UID: 999, User: "dokkit", Exe: "/usr/local/bin/dokkit", Scope: "system", Unit: "dokkit.service"}
	mine := watchProc{Pid: 2, UID: 1000, User: "nat", Exe: "/home/nat/dokkit"}
	other := watchProc{Pid: 3, UID: 1001, User: "bob", Exe: "/home/bob/dokkit"}
	if p, err := chooseProgram([]watchProc{other, mine, sys}, "nat"); err != nil || p.Pid != 1 {
		t.Fatalf("a system unit wins: %+v %v", p, err)
	}
	if p, err := chooseProgram([]watchProc{other, mine}, "nat"); err != nil || p.Pid != 2 {
		t.Fatalf("the account that ran sudo wins: %+v %v", p, err)
	}
	if p, err := chooseProgram([]watchProc{other}, ""); err != nil || p.Pid != 3 {
		t.Fatalf("the only one: %+v %v", p, err)
	}
	dup := mine
	dup.Pid = 9
	if p, err := chooseProgram([]watchProc{mine, dup}, ""); err != nil || p.Pid != 2 {
		t.Fatalf("one program with two processes is one program: %+v %v", p, err)
	}
	if _, err := chooseProgram([]watchProc{mine, other}, ""); err == nil || !strings.Contains(err.Error(), "/home/bob/dokkit") {
		t.Fatalf("two programs are a question, not a guess: %v", err)
	}
	if _, err := chooseProgram(nil, "nat"); err == nil {
		t.Fatal("nothing running is refused")
	}
}

func TestUnitFromCgroup(t *testing.T) {
	for _, c := range []struct{ in, scope, unit string }{
		{"0::/system.slice/dokkit.service\n", "system", "dokkit.service"},
		{"0::/user.slice/user-1000.slice/user@1000.service/app.slice/dokkit.service\n", "user", "dokkit.service"},
		{"0::/user.slice/user-1000.slice/session-3.scope\n", "", ""},
		{"0::/user.slice/user-1000.slice/user@1000.service\n", "", ""},
		{"12:cpu:/\n1:name=systemd:/system.slice/cron.service\n", "system", "cron.service"},
		{"", "", ""},
	} {
		if s, u := unitFromCgroup(c.in); s != c.scope || u != c.unit {
			t.Errorf("%q: %q %q", c.in, s, u)
		}
	}
}

func TestParsers(t *testing.T) {
	env := parseEnviron([]byte("A=1\x00DOKKIT_CONFIG=/a=b\x00\x00junk\x00"))
	if env["A"] != "1" || env["DOKKIT_CONFIG"] != "/a=b" || len(env) != 2 {
		t.Fatalf("%v", env)
	}
	list := "PID\tStatus\tLabel\n-\t0\tcom.apple.x\n412\t0\tcom.me.dokkit\n"
	if labelForPid(list, 412) != "com.me.dokkit" || labelForPid(list, 4) != "" {
		t.Fatal("label")
	}
	rows := parsePS("  101   501 /Applications/Some App/dokkit watch\n  102     0 /usr/bin/ssh host\nbad line here\n")
	if len(rows) != 2 || rows[0].pid != 101 || rows[0].uid != 501 || rows[0].cmd != "/Applications/Some App/dokkit watch" {
		t.Fatalf("%+v", rows)
	}
	for cmd, want := range map[string]bool{
		"/Applications/Some App/dokkit watch":      true,
		"/usr/local/bin/dokkit watch --extra":      true,
		"/usr/local/bin/dokkit-darwin-arm64 watch": true,
		"/usr/local/bin/dokkit watchdog":           false,
		"/usr/bin/watch":                           false,
		"dokkit watch":                             false,
		"/usr/bin/ssh host":                        false,
	} {
		if _, ok := watchCommand(cmd); ok != want {
			t.Errorf("%q: %v", cmd, ok)
		}
	}
}

func TestPidIsProgram(t *testing.T) {
	for exe, want := range map[string]bool{
		"/usr/local/bin/dokkit":           true,
		"/usr/local/bin/dokkit (deleted)": true,
		"/usr/local/bin//dokkit":          true,
		"/usr/local/bin/other":            false,
		"":                                false,
		"/tmp/usr/local/bin/dokkit":       false,
		"/usr/local/bin/dokkit.previous":  false,
	} {
		if pidIsProgram(exe, "/usr/local/bin/dokkit") != want {
			t.Errorf("%q", exe)
		}
	}
}

func TestRestartAndActiveCommands(t *testing.T) {
	join := func(a []string) string { return strings.Join(a, " ") }
	sys := upConfig{Method: methodSystemUnit, Unit: "dokkit.service"}
	usr := upConfig{Method: methodUserUnit, Unit: "d.service", User: "nat", UID: 1000}
	mac := upConfig{Method: methodLaunchAgent, Unit: "com.me.dokkit", UID: 501}
	for got, want := range map[string]string{
		join(restartArgv(sys)): "systemctl restart -- dokkit.service",
		join(activeArgv(sys)):  "systemctl is-active -- dokkit.service",
		join(restartArgv(usr)): "runuser -u nat -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user restart -- d.service",
		join(restartArgv(mac)): "launchctl kickstart -k gui/501/com.me.dokkit",
		join(activeArgv(mac)):  "launchctl print gui/501/com.me.dokkit",
	} {
		if got != want {
			t.Errorf("%s != %s", got, want)
		}
	}
	if restartArgv(upConfig{Method: methodProcess}) != nil {
		t.Error("a plain process is restarted by the updater itself")
	}
	if !isRunning(methodSystemUnit, "active\n") || isRunning(methodSystemUnit, "activating\n") || isRunning(methodUserUnit, "inactive") {
		t.Error("is-active")
	}
	if !isRunning(methodLaunchAgent, "\tstate = running\n") || isRunning(methodLaunchAgent, "\tstate = waiting\n") {
		t.Error("launchctl print")
	}
}

func TestChildEnvCarriesOnlyWhatWasSet(t *testing.T) {
	env := strings.Join(childEnv(upConfig{User: "nat", Home: "/home/nat", Env: map[string]string{"DOKKIT_CONFIG": "/c.json", "DOKKIT_FOLDERS": "/a:/b"}}), "\n")
	for _, w := range []string{"HOME=/home/nat", "USER=nat", "DOKKIT_CONFIG=/c.json", "DOKKIT_FOLDERS=/a:/b"} {
		if !strings.Contains(env, w) {
			t.Errorf("%s missing from %s", w, env)
		}
	}
	if strings.Contains(env, "DOKKIT_SPOOL") {
		t.Error("a variable that was not set is not invented")
	}
}

func TestUnitTexts(t *testing.T) {
	svc := timerService("/usr/local/lib/dokkit-updater/dokkit")
	for _, w := range []string{"Type=oneshot", "ExecStart=/usr/local/lib/dokkit-updater/dokkit updater run", "KillMode=process"} {
		if !strings.Contains(svc, w) {
			t.Errorf("service lacks %s", w)
		}
	}
	for _, w := range []string{"OnBootSec=1min", "OnUnitInactiveSec=5min", "WantedBy=timers.target"} {
		if !strings.Contains(timerUnit(), w) {
			t.Errorf("timer lacks %s", w)
		}
	}
	p := launchdPlist("/Library/Application Support/DokkitUpdater/dokkit")
	for _, w := range []string{"<string>com.dokkit.updater</string>", "<integer>300</integer>", "<string>/Library/Application Support/DokkitUpdater/dokkit</string><string>updater</string><string>run</string>", "AbandonProcessGroup"} {
		if !strings.Contains(p, w) {
			t.Errorf("plist lacks %s", w)
		}
	}
	if strings.Contains(launchdPlist("/a&b/<c>"), "/a&b/<c>") {
		t.Error("the plist is not escaped")
	}
}

func TestCrontabEdits(t *testing.T) {
	line := cronLine("/usr/local/lib/dokkit-updater/dokkit")
	if line != "*/5 * * * * /usr/local/lib/dokkit-updater/dokkit updater run >/dev/null 2>&1 # dokkit-updater" {
		t.Fatal(line)
	}
	other := "0 3 * * * /bin/backup\n"
	added := addCron(other, line)
	if added != other+line+"\n" {
		t.Fatalf("%q", added)
	}
	if addCron(added, line) != added {
		t.Fatal("adding twice changes nothing")
	}
	if addCron("", line) != line+"\n" || addCron("no newline", line) != "no newline\n"+line+"\n" {
		t.Fatal("empty or unterminated crontab")
	}
	if dropCron(added) != other || dropCron(line+"\n") != "" || dropCron("") != "" {
		t.Fatalf("%q", dropCron(added))
	}
}

func TestCopyPlainNeverWritesThroughAnExistingName(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	os.WriteFile(src, []byte("new"), 0o600)
	target := filepath.Join(dir, "victim")
	os.WriteFile(target, []byte("keep"), 0o600)
	if err := copyPlain(src, target); err == nil {
		t.Fatal("an existing file was written to")
	}
	link := filepath.Join(dir, "link")
	if os.Symlink(target, link) == nil {
		if err := copyPlain(src, link); err == nil {
			t.Fatal("a link was followed")
		}
	}
	if b, _ := os.ReadFile(target); string(b) != "keep" {
		t.Fatal("the file behind the name changed")
	}
	if err := putFile(src, target); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(target); string(b) != "new" || exists(target+".new") {
		t.Fatal("not replaced, or a .new is left")
	}
}

func TestUpdaterVolumeAndCronLine(t *testing.T) {
	mounts := parseMounts("none / tmpfs rw 0 0\n/dev/mapper/cachedev1 /share/CACHEDEV1_DATA ext4 rw 0 0\n/dev/loop0 /share/CACHEDEV1_DATA/a\\040b ext4 rw 0 0\n")
	for file, want := range map[string]string{
		"/share/CACHEDEV1_DATA/dokkit/dokkit": "/share/CACHEDEV1_DATA",
		"/share/CACHEDEV1_DATA/a b/dokkit":    "/share/CACHEDEV1_DATA/a b",
		"/share/CACHEDEV1_DATA2/dokkit":       "/",
		"/tmp/dokkit":                         "/",
	} {
		if got := mountOf(file, mounts); got != want {
			t.Errorf("%s: %q, want %q", file, got, want)
		}
	}
	exe := "/share/CACHEDEV1_DATA/.dokkit-updater/program/dokkit"
	tab := "# m h dom m dow cmd\n0 3 * * * /sbin/other\n" + cronLine(exe) + "\n"
	if got := cronExe(tab); got != exe {
		t.Fatalf("%q", got)
	}
	if cronExe("0 3 * * * /sbin/other\n# "+cronLine(exe)+"\n") != "" {
		t.Fatal("a commented line is not the updater's")
	}
}
