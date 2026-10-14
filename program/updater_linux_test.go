//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSystemdUnitsAreBroughtToTheCurrentOnesOnce(t *testing.T) {
	dir := t.TempDir()
	oldS, oldT, oldP, oldRun, oldCfg := timerServicePath, timerUnitPath, pathUnitPath, runCmd, upConfigPath
	defer func() {
		timerServicePath, timerUnitPath, pathUnitPath, runCmd, upConfigPath = oldS, oldT, oldP, oldRun, oldCfg
	}()
	timerServicePath, timerUnitPath, pathUnitPath = filepath.Join(dir, "u.service"), filepath.Join(dir, "u.timer"), filepath.Join(dir, "u.path")
	upConfigPath = filepath.Join(dir, "config.json")
	cfg := me()
	cfg.Method, cfg.Program = methodSystemUnit, "/usr/local/bin/dokkit"
	os.WriteFile(upConfigPath, cfg.encode(), 0o644)
	useNudgeFile(t)
	exe := "/usr/local/lib/dokkit-updater/dokkit"
	os.WriteFile(timerServicePath, []byte(timerService(exe)), 0o644)
	os.WriteFile(timerUnitPath, []byte(timerUnit()), 0o644)

	var calls []string
	active := "inactive"
	runCmd = func(name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+strings.Join(args, " "))
		if args[0] == "is-active" {
			return []byte(active), errors.New("exit status 3")
		}
		if args[0] == "enable" {
			active = "active"
		}
		return nil, nil
	}
	changed, err := syncUnits(exe)
	if err != nil || len(changed) != 1 || changed[0] != "u.path" {
		t.Fatalf("an old install should gain only the path unit: %v %v", changed, err)
	}
	if b, _ := os.ReadFile(pathUnitPath); string(b) != pathUnit() {
		t.Fatalf("%s", b)
	}
	if got := strings.Join(calls, "|"); !strings.Contains(got, "systemctl daemon-reload") || !strings.Contains(got, "systemctl enable --now dokkit-updater.path") {
		t.Fatalf("%s", got)
	}
	calls = nil
	if changed, err := syncUnits(exe); err != nil || len(changed) != 0 || strings.Contains(strings.Join(calls, "|"), "daemon-reload") || strings.Contains(strings.Join(calls, "|"), "enable") {
		t.Fatalf("a current install was touched: %v %v %q", changed, err, calls)
	}
}

func TestQnapCrontabIsEditedLoadedAndRestored(t *testing.T) {
	old, oldRun := qnapCrontab, runCmd
	defer func() { qnapCrontab, runCmd = old, oldRun }()
	qnapCrontab = filepath.Join(t.TempDir(), "crontab")
	other := "0 3 * * * /sbin/other-job\n"
	os.WriteFile(qnapCrontab, []byte(other), 0o644)
	var loaded []string
	runCmd = func(name string, args ...string) ([]byte, error) {
		loaded = append(loaded, name+" "+strings.Join(args, " "))
		return nil, nil
	}
	line := cronLine("/usr/local/lib/dokkit-updater/dokkit")
	for i := 0; i < 2; i++ {
		if _, _, err := editCrontab(func(tab string) string { return addCron(tab, line) }); err != nil {
			t.Fatal(err)
		}
	}
	b, _ := os.ReadFile(qnapCrontab)
	if string(b) != other+line+"\n" {
		t.Fatalf("added twice or lost the other job: %q", b)
	}
	if len(loaded) != 1 || loaded[0] != "crontab "+qnapCrontab {
		t.Fatalf("loaded %q", loaded)
	}
	if _, changed, err := editCrontab(dropCron); err != nil || !changed {
		t.Fatalf("%v %v", changed, err)
	}
	if b, _ := os.ReadFile(qnapCrontab); string(b) != other {
		t.Fatalf("removing the line did not restore the file: %q", b)
	}
}
