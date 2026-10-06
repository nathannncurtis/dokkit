package main

import (
	"errors"
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

func TestAStoppedUnitIsRestartedOnlyWhenAllowedAndNotOver(t *testing.T) {
	calls := fakeSystemctl(t, "", nil)
	restarted = map[string]time.Time{}
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
