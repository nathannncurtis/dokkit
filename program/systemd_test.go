package main

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeSystemctl answers every command with out and records them.
func fakeSystemctl(t *testing.T, out string, err error) *[][]string {
	var calls [][]string
	old := runCmd
	t.Cleanup(func() { runCmd = old })
	runCmd = func(name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		return []byte(out + "\n"), err
	}
	return &calls
}

// show is systemctl show output as it prints it, one line per property.
func show(load, active, sub, result, restarts string) string {
	return strings.Join([]string{"LoadState=" + load, "ActiveState=" + active, "SubState=" + sub, "Result=" + result, "NRestarts=" + restarts}, "\n")
}

// Captured output, one per state a unit can be seen in.
var (
	showActive      = show("loaded", "active", "running", "success", "0")
	showStarting    = show("loaded", "activating", "start", "success", "0")
	showAutoRestart = show("loaded", "activating", "auto-restart", "exit-code", "7")
	showFailed      = show("loaded", "failed", "failed", "exit-code", "0")
	showInactive    = show("loaded", "inactive", "dead", "success", "0")
	showReloading   = show("loaded", "reloading", "reload", "success", "0")
	showUnknownUnit = show("not-found", "inactive", "dead", "success", "0")
	// Auto-restart with a clean result still means systemd is restarting it.
	showAutoRestartClean = show("loaded", "activating", "auto-restart", "success", "0")
)

// fakeShow answers every systemctl call with a captured show output.
func fakeShow(t *testing.T, out string) *[][]string {
	busyChecks = map[string]int{}
	return fakeSystemctl(t, out, nil)
}

func TestSystemdStateComesFromShow(t *testing.T) {
	calls := fakeShow(t, showActive)
	if err := systemdActive("nginx.service"); err != nil {
		t.Fatal(err)
	}
	if got := (*calls)[0]; got[1] != "show" || !slices.Contains(got, "--property=LoadState,ActiveState,SubState,Result,NRestarts") || got[len(got)-1] != "nginx.service" {
		t.Fatalf("%v", *calls)
	}
	for _, c := range []struct{ out, want string }{
		{showFailed, "failed: exit-code"},
		{showInactive, "not running (inactive)"},
		{showUnknownUnit, "no such unit"},
		{showAutoRestart, "waiting to be restarted after a failure: exit-code, restarted 7 times"},
		{showAutoRestartClean, "waiting to be restarted after a failure"},
	} {
		fakeShow(t, c.out)
		err := systemdActive("nginx")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("%q: %v", c.want, err)
		}
		var busy unitBusy
		if errors.As(err, &busy) {
			t.Fatalf("%q must not read as busy", c.want)
		}
	}
	fakeSystemctl(t, "", errors.New("not found"))
	if err := systemdActive("nginx"); err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Fatalf("no answer is down: %v", err)
	}
}

func TestAUnitStartingOrReloadingIsBusyForTwoChecksThenDown(t *testing.T) {
	for _, out := range []string{showStarting, showReloading} {
		fakeShow(t, out)
		for i := 1; i <= busyLimit; i++ {
			var busy unitBusy
			if err := systemdActive("web"); !errors.As(err, &busy) {
				t.Fatalf("check %d: %v", i, err)
			}
		}
		var stuck unitStuck
		if err := systemdActive("web"); !errors.As(err, &stuck) {
			t.Fatalf("the third check in a row is down: %v", err)
		}
		fakeShow(t, showActive)
		systemdActive("web")
		fakeShow(t, out)
		var busy unitBusy
		if err := systemdActive("web"); !errors.As(err, &busy) {
			t.Fatalf("a good answer in between starts the count again: %v", err)
		}
	}
}

func TestACrashLoopingUnitIsDownAndNotRestartedFromHere(t *testing.T) {
	restarted = map[string]time.Time{}
	insideService(t)
	calls := fakeShow(t, showAutoRestart)
	r := (&check{Type: "systemd", Name: "web", restart: true}).run()
	if r.ok || r.state != "" || !strings.Contains(r.note, "auto") && !strings.Contains(r.note, "restarted") {
		t.Fatalf("%+v", r)
	}
	if len(*calls) != 1 {
		t.Fatalf("systemd is restarting it already: %v", *calls)
	}
}

func TestRunCmdKeepsStandardOutputAndErrorApart(t *testing.T) {
	self, _ := os.Executable()
	t.Setenv("DOKKIT_FAKE", "3")
	out, err := runCmd(self)
	if strings.TrimSpace(string(out)) != "copying" || err == nil || !strings.Contains(err.Error(), "disk full") {
		t.Fatalf("out %q err %v", out, err)
	}
}

// insideService makes this process look like the installed service's unit.
func insideService(t *testing.T) {
	old := runningAsService
	t.Cleanup(func() { runningAsService = old })
	runningAsService = func() bool { return true }
}

func TestAStoppedUnitIsRestartedOnlyWhenAllowedAndNotOver(t *testing.T) {
	calls := fakeSystemctl(t, "", nil)
	restarted = map[string]time.Time{}
	insideService(t)
	no, yes := &check{Type: "systemd", Name: "unit-a"}, &check{Type: "systemd", Name: "unit-b", restart: true}
	if no.tryRestart() || len(*calls) != 0 {
		t.Fatal("a unit nobody allowed is left alone")
	}
	if !yes.tryRestart() || yes.tryRestart() || len(*calls) != 1 {
		t.Fatalf("an allowed one is restarted once in ten minutes: %v", *calls)
	}
	if !slices.Equal((*calls)[0], []string{"systemctl", "restart", "--", "unit-b"}) {
		t.Fatalf("%v", *calls)
	}
}

func TestTheUnitRunsWatchAsTheDokkitUser(t *testing.T) {
	u := unitFile("/usr/local/bin/dokkit")
	for _, want := range []string{"ExecStart=/usr/local/bin/dokkit watch\n", "User=dokkit\n", "DOKKIT_CONFIG=/etc/dokkit/config.json", "WantedBy=multi-user.target"} {
		if !strings.Contains(u, want) {
			t.Fatalf("the unit lacks %q:\n%s", want, u)
		}
	}
	if strings.Contains(u, "User=root") {
		t.Fatal("not root")
	}
}

func TestServiceActionsMakeTheMatchingSystemctlCalls(t *testing.T) {
	calls := fakeSystemctl(t, "", nil)
	for action, want := range map[string]string{
		"install": "systemctl daemon-reload;systemctl enable --now dokkit.service",
		"start":   "systemctl start dokkit.service",
		"stop":    "systemctl stop dokkit.service",
		"update":  "systemctl restart dokkit.service",
	} {
		*calls = nil
		if err := runSteps(action); err != nil {
			t.Fatal(err)
		}
		var got []string
		for _, c := range *calls {
			got = append(got, strings.Join(c, " "))
		}
		if strings.Join(got, ";") != want {
			t.Fatalf("%s: %v", action, got)
		}
	}
}

func TestAWatchUnderALoginNeverRestartsAUnit(t *testing.T) {
	calls := fakeSystemctl(t, "", nil)
	restarted = map[string]time.Time{}
	if (&check{Type: "systemd", Name: "unit-c", restart: true}).tryRestart() || len(*calls) != 0 {
		t.Fatal("only the installed service restarts a unit")
	}
}

func TestAUnitStillStartingIsDegradedAndLeftAlone(t *testing.T) {
	restarted = map[string]time.Time{}
	insideService(t)
	for _, out := range []string{showStarting, showReloading} {
		calls := fakeShow(t, out)
		r := (&check{Type: "systemd", Name: "web", restart: true}).run()
		if r.ok || r.state != "degraded" || len(*calls) != 1 {
			t.Fatalf("%+v %v", r, *calls)
		}
	}
}

var fakeOld = runCmd

func TestARestartNeverHoldsTheThrottleLock(t *testing.T) {
	restarted = map[string]time.Time{}
	release := make(chan struct{})
	old := startService
	t.Cleanup(func() { startService = old; close(release) })
	startService = func(string) error { <-release; return nil }
	go (&check{Type: "windows-service", Name: "hung", restart: true}).tryRestart()
	time.Sleep(50 * time.Millisecond)
	done := make(chan bool)
	go func() { done <- (&check{Type: "windows-service", Name: "other", restart: false}).tryRestart() }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("one hung restart holds up the next check")
	}
}

func TestARestartKeepsItsNoteOnAGoodAnswerAndNameVariantsShareAThrottle(t *testing.T) {
	d := &declaration{}
	d.Service.ID = "s"
	c := &check{Type: "systemd", Name: "nginx", name: "systemd"}
	if l := stateLine(d, c, result{ok: true, note: "had stopped; started it again"}); l["state"] != "ok" || l["note"] == nil {
		t.Fatalf("%v", l)
	}
	if l := stateLine(d, c, result{ok: true}); l["note"] != nil {
		t.Fatalf("%v", l)
	}
	if c.unitKey("NGINX.service") != c.unitKey("nginx") {
		t.Fatal("nginx and nginx.service are one unit")
	}
}

func TestInstallUsesTheEnrolmentOfWhoRanSudoThenRoots(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	own := filepath.Join(root, "config.json")
	theirs := filepath.Join(home, ".config", "dokkit", "config.json")
	os.MkdirAll(filepath.Dir(theirs), 0o755)
	if enrolmentPath(own, home) != "" {
		t.Fatal("no enrolment anywhere")
	}
	os.WriteFile(own, []byte(`{"url":"https://r","key":"dkm_y"}`), 0o600)
	if got := enrolmentPath(own, home); got != own {
		t.Fatalf("root's own is the fallback: %q", got)
	}
	os.WriteFile(theirs, []byte(`{"url":"https://s","key":"dkm_x"}`), 0o600)
	if got := enrolmentPath(own, home); got != theirs {
		t.Fatalf("the account that ran sudo comes first: %q", got)
	}
}

func TestAnUnreadableFolderIsSaid(t *testing.T) {
	if unreadable(t.TempDir()) != "" || unreadable(filepath.Join(t.TempDir(), "gone")) == "" {
		t.Fatal("a missing folder is reported, a readable one is not")
	}
	w := &watcher{folders: []string{filepath.Join(t.TempDir(), "gone")}}
	w.checkFolders()
	if len(w.blocked) != 1 {
		t.Fatalf("%v", w.blocked)
	}
}

func TestTheUpdateTaskUnderTheServiceSaysToUseServiceUpdate(t *testing.T) {
	insideService(t)
	spool := t.TempDir()
	_, _, err := (&client{spool: spool}).fetchUpdate()
	if err == nil || !strings.Contains(err.Error(), "service update") {
		t.Fatalf("%v", err)
	}
}

func TestHelpIsOnlyAskedForOnRealCommands(t *testing.T) {
	for args, want := range map[string]bool{
		"scan --no-ports --help": true, "check -h": true, "apply x.toml --help": true,
		"task run --help": true, "ping --help": true, "run --help": true,
		"ping help": false, "ping help ok": false, "run --job x -- cmd --help": false,
		"run --job help -- cmd": false, "ping x --help": false, "nope --help": false, "run help": false,
		"scan help": true, "propose help": true, "watch help": true, "status help": true, "doctor help": true,
		"startup help": true, "service help": true, "init help": true, "check help": true, "apply help": true,
		"enrol help": true, "task help": true, "folder help": true, "task run help": false, "folder add help": false,
	} {
		if got := wantsHelp(strings.Fields(args)); got != want {
			t.Errorf("%s: %v", args, got)
		}
	}
}

func TestSlowMustBeAboveZeroAndBelowTimeoutAndOnlyOnHTTP(t *testing.T) {
	for slow, ok := range map[string]bool{"2s": true, "0s": false, "-1s": false, "5s": false, "9s": false} {
		_, err := (&check{Type: "http", URL: "http://x", Slow: slow}).problem()
		if (err == nil) != ok {
			t.Errorf("slow %s: %v", slow, err)
		}
	}
	if _, err := (&check{Type: "http", URL: "http://x", Slow: "9s", Timeout: "10s"}).problem(); err != nil {
		t.Fatal(err)
	}
	if _, err := (&check{Type: "tcp", Port: 1, Slow: "1s"}).problem(); err == nil {
		t.Fatal("slow on a tcp check says so")
	}
}

func TestATimeOverTheLimitIsNeverWrittenAsTheLimit(t *testing.T) {
	if got := tookText(2040*time.Millisecond, 2*time.Second); got != "2.04 s" {
		t.Fatal(got)
	}
	if got := tookText(2400*time.Millisecond, 2*time.Second); got != "2.4 s" {
		t.Fatal(got)
	}
}
