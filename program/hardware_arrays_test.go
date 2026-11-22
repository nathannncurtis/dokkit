package main

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func statesOf(s []hwState) map[string]hwState {
	m := map[string]hwState{}
	for _, x := range s {
		m[x.check] = x
	}
	return m
}

func wantStates(t *testing.T, what string, got []hwState, want []hwState) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: %v, want %v", what, got, want)
	}
	m := statesOf(got)
	for _, w := range want {
		if m[w.check] != w {
			t.Errorf("%s: %+v, want %+v", what, m[w.check], w)
		}
	}
}

func TestMdstatOnAQnapSkipsItsOwnArrays(t *testing.T) {
	text := fixture(t, "mdstat", "qnap.txt")
	wantStates(t, "qnap", parseMdstat(text, true), []hwState{{"hw.array.md3", "ok", ""}, {"hw.array.md1", "ok", ""}})
	if s := statesOf(parseMdstat(text, false)); s["hw.array.md13"].state != "down" {
		t.Errorf("anywhere else a 128-slot array short of drives is down: %v", s)
	}
}

func TestMdstatDegradedAndRebuilding(t *testing.T) {
	wantStates(t, "degraded", parseMdstat(fixture(t, "mdstat", "degraded.txt"), false), []hwState{
		{"hw.array.md0", "down", "1 of 2 drives missing"},
		{"hw.array.md1", "ok", ""},
		{"hw.array.md2", "down", "Not running"},
	})
	wantStates(t, "rebuilding", parseMdstat(fixture(t, "mdstat", "rebuilding.txt"), false), []hwState{
		{"hw.array.md1", "degraded", "Rebuilding, 41.2% done"},
		{"hw.array.md2", "degraded", "Resyncing, 12.5% done"},
		{"hw.array.md3", "ok", "Checking, 30.0% done"},
		{"hw.array.md4", "degraded", "Resyncing, waiting to start"},
		{"hw.array.md5", "ok", ""},
	})
}

func qnapAnswers(t *testing.T, change map[string]string) {
	answers := map[string]string{}
	for _, l := range strings.Split(fixture(t, "qnap", "nas.txt"), "\n") {
		if k, v, ok := strings.Cut(l, "\t"); ok {
			answers[k] = v
		}
	}
	for k, v := range change {
		answers[k] = v
	}
	runCmd = func(name string, args ...string) ([]byte, error) {
		if filepath.Base(name) != "getsysinfo" {
			return nil, exec.ErrNotFound
		}
		if v, ok := answers[strings.Join(args, " ")]; ok {
			return []byte(v + "\n"), nil
		}
		return nil, &exec.ExitError{}
	}
}

func TestQnapVolumesAndDriveVerdicts(t *testing.T) {
	hwReset(t)
	qnapAnswers(t, nil)
	f := &hwFound{}
	qnapVerdicts(f)
	if len(f.states) != 11 {
		t.Fatalf("2 volumes and 9 drives: %v", f.states)
	}
	if _, ok := statesOf(f.states)["hw.array.vol3"]; ok {
		t.Error("a healthy QNAP counts a third volume and answers nothing for it; that opens nothing")
	}
	for _, s := range f.states {
		if s.state != "ok" || s.note != "" {
			t.Errorf("all ready and good: %+v", s)
		}
	}

	qnapAnswers(t, map[string]string{"vol_status 1": "Degraded", "vol_status 2": "Rebuilding...", "hdsmart 3": "Abnormal", "hdsmart 4": "Warning", "hdsmart 5": "--"})
	f = &hwFound{}
	qnapVerdicts(f)
	got := statesOf(f.states)
	for check, want := range map[string]hwState{
		"hw.array.vol1": {"hw.array.vol1", "down", "The NAS says the volume is Degraded"},
		"hw.array.vol2": {"hw.array.vol2", "degraded", "The NAS says the volume is Rebuilding..."},
		"hw.smart.hd3":  {"hw.smart.hd3", "down", "The NAS says the drive is Abnormal"},
		"hw.smart.hd4":  {"hw.smart.hd4", "degraded", "The NAS says the drive is Warning"},
	} {
		if got[check] != want {
			t.Errorf("%s: %+v, want %+v", check, got[check], want)
		}
	}
	if _, ok := got["hw.smart.hd5"]; ok {
		t.Error("an empty slot has no verdict")
	}
}

func TestDiskutilSmartStatus(t *testing.T) {
	wantStates(t, "diskutil", parseDiskutil(fixture(t, "diskutil", "info-all.txt")), []hwState{
		{"hw.smart.disk0", "ok", ""},
		{"hw.smart.disk5", "down", "SMART status: Failing"},
	})
}

func TestZpoolHealth(t *testing.T) {
	wantStates(t, "zpool", parseZpool(fixture(t, "zpool", "list.txt"), fixture(t, "zpool", "status-x.txt")), []hwState{
		{"hw.array.zfs_tank", "degraded", "Resilvering, 20.35% done"},
		{"hw.array.zfs_backup", "ok", ""},
		{"hw.array.zfs_scratch", "down", "The ZFS pool is FAULTED"},
		{"hw.array.zfs_cold", "down", "The ZFS pool is DEGRADED"},
	})
}

func TestEveryPoolKeepsItsOwnCheck(t *testing.T) {
	got := parseZpool("tank-a\tONLINE\ntank_a\tDEGRADED\nTank_A\tONLINE\nmd1\tONLINE\n", "")
	seen := map[string]bool{}
	for _, s := range got {
		if seen[s.check] || s.check == "hw.array.md1" {
			t.Fatalf("pools share a check or take an md array's name: %v", got)
		}
		seen[s.check] = true
	}
	if len(got) != 4 || statesOf(got)["hw.array.zfs_tank_a"].state != "down" {
		t.Fatalf("%v", got)
	}
}

func TestQnapSaysWhyAVerdictIsMissing(t *testing.T) {
	hwReset(t)
	qnapAnswers(t, nil)
	answered := runCmd
	runCmd = func(name string, args ...string) ([]byte, error) {
		if args[0] == "hdsmart" {
			return nil, &exec.ExitError{}
		}
		return answered(name, args...)
	}
	f := &hwFound{}
	qnapVerdicts(f)
	said := strings.Join(f.said, "\n")
	if !strings.Contains(said, "drive verdicts: 0 of 9") || !strings.Contains(said, "getsysinfo hdsmart 1:") {
		t.Fatalf("said %q", said)
	}
}

func TestZpoolStatusIsAskedOnlyWhenAPoolIsUnwell(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no zpool on Windows")
	}
	hwReset(t)
	var asked []string
	runCmd = func(name string, args ...string) ([]byte, error) {
		if name != "zpool" {
			return nil, exec.ErrNotFound
		}
		asked = append(asked, args[0])
		return []byte("tank\tONLINE\n"), nil
	}
	f := &hwFound{}
	zfsPools(f)
	if len(asked) != 1 || len(f.states) != 1 || f.states[0].state != "ok" {
		t.Fatalf("asked %v, states %v", asked, f.states)
	}
}

func TestArraysOnALinuxQnap(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("mdstat is read on Linux")
	}
	root := hwReset(t)
	mdstatPath = filepath.Join(root, "mdstat")
	write(t, mdstatPath, fixture(t, "mdstat", "qnap.txt"))
	qnapAnswers(t, nil)
	f := lookHardware()
	got := statesOf(f.states)
	if len(got) != 13 || got["hw.array.md1"].state != "ok" || got["hw.smart.hd9"].state != "ok" {
		t.Fatalf("2 arrays, 2 volumes, 9 drives: %v", f.states)
	}
	if _, ok := got["hw.array.md9"]; ok {
		t.Error("md9 is the QNAP's own")
	}
}
