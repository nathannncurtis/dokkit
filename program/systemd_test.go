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

func TestSystemdStateComesFromIsActive(t *testing.T) {
	calls := fakeSystemctl(t, "active", nil)
	if err := systemdActive("nginx.service"); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal((*calls)[0], []string{"systemctl", "is-active", "--", "nginx.service"}) {
		t.Fatalf("%v", *calls)
	}
	fakeSystemctl(t, "failed", errors.New("exit status 3"))
	if err := systemdActive("nginx"); err == nil || !strings.Contains(err.Error(), "failed") {
		t.Fatalf("a failed unit is down and says why: %v", err)
	}
	fakeSystemctl(t, "", errors.New("not found"))
	if systemdActive("nginx") == nil {
		t.Fatal("no answer is down")
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

func TestAUnitStillStartingOrReloadingIsDegradedAndLeftAlone(t *testing.T) {
	restarted = map[string]time.Time{}
	insideService(t)
	for _, state := range []string{"activating", "reloading", "deactivating"} {
		calls := fakeSystemctl(t, state, errors.New("exit status 3"))
		r := (&check{Type: "systemd", Name: "web", restart: true}).run()
		if r.ok || r.state != "degraded" || !strings.Contains(r.note, state) {
			t.Fatalf("%s: %+v", state, r)
		}
		if len(*calls) != 1 {
			t.Fatalf("%s must not be restarted: %v", state, *calls)
		}
	}
}

func TestAnUnknownUnitIsNotJustStopped(t *testing.T) {
	runCmd = func(name string, args ...string) ([]byte, error) {
		if slices.Contains(args, "show") {
			return []byte("not-found"), nil
		}
		return []byte("inactive"), errors.New("exit status 3")
	}
	t.Cleanup(func() { runCmd = fakeOld })
	if err := systemdActive("nope"); err == nil || !strings.Contains(err.Error(), "no such unit") {
		t.Fatalf("%v", err)
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

func TestInstallUsesTheEnrolmentOfWhoRanSudo(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	own := filepath.Join(root, "config.json")
	theirs := filepath.Join(home, ".config", "dokkit", "config.json")
	os.MkdirAll(filepath.Dir(theirs), 0o755)
	if enrolmentPath(own, home) != "" {
		t.Fatal("no enrolment anywhere")
	}
	os.WriteFile(theirs, []byte(`{"url":"https://s","key":"dkm_x"}`), 0o600)
	if got := enrolmentPath(own, home); got != theirs {
		t.Fatalf("got %q", got)
	}
	os.WriteFile(own, []byte(`{"url":"https://r","key":"dkm_y"}`), 0o600)
	if got := enrolmentPath(own, home); got != own {
		t.Fatalf("root's own comes first: %q", got)
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
		"run --job help -- cmd": false, "ping x --help": false, "check help": false, "nope --help": false,
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
