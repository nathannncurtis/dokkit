//go:build linux || darwin

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func useNudgeFile(t *testing.T) string {
	old := nudgeFile
	nudgeFile = filepath.Join(t.TempDir(), "dokkit-nudge", "now")
	t.Cleanup(func() { nudgeFile = old })
	return nudgeFile
}

func me() upConfig { return upConfig{UID: os.Getuid(), GID: os.Getgid()} }

func TestPokeWritesTheNudgeFile(t *testing.T) {
	f := useNudgeFile(t)
	if err := ensureNudge(me()); err != nil {
		t.Fatal(err)
	}
	if _, err := realPoke(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(f)
	if !strings.HasSuffix(string(b), "\n") || len(b) < 20 {
		t.Fatalf("%q", b)
	}
}

func useCron(t *testing.T, exe string, root bool) {
	oldExe, oldRoot := cronUpdaterExe, isRoot
	cronUpdaterExe, isRoot = func() string { return exe }, func() bool { return root }
	t.Cleanup(func() { cronUpdaterExe, isRoot = oldExe, oldRoot })
}

func TestPokeWhereTheUpdaterMadeNoFolderPokesNothing(t *testing.T) {
	f := useNudgeFile(t)
	useCron(t, "", true)
	if _, err := realPoke(); !errors.Is(err, errNoNudge) {
		t.Fatalf("%v", err)
	}
	if exists(filepath.Dir(f)) {
		t.Fatal("the program made the folder the updater is meant to make")
	}
}

func TestNudgeFolderBelongsToTheProgramsAccountAndIsMadeOnce(t *testing.T) {
	f := useNudgeFile(t)
	for i := 0; i < 2; i++ {
		if err := ensureNudge(me()); err != nil {
			t.Fatal(err)
		}
	}
	fi, _ := os.Stat(filepath.Dir(f))
	if fi.Mode().Perm() != 0o700 || int(fi.Sys().(*syscall.Stat_t).Uid) != os.Getuid() {
		t.Fatalf("%v", fi.Mode())
	}
	os.WriteFile(f, []byte("kept"), 0o600)
	ensureNudge(me())
	if b, _ := os.ReadFile(f); string(b) != "kept" {
		t.Fatal("an existing nudge file was rewritten")
	}
}

func TestNudgeFileThatIsALinkIsNotFollowed(t *testing.T) {
	f := useNudgeFile(t)
	os.MkdirAll(filepath.Dir(f), 0o700)
	target := filepath.Join(t.TempDir(), "target")
	os.WriteFile(target, []byte("root only"), 0o600)
	os.Symlink(target, f)
	if err := ensureNudge(me()); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(target); string(b) != "root only" {
		t.Fatal("the link's target was changed")
	}
}

func TestWriteIfChangedWritesOnlyADifference(t *testing.T) {
	p := filepath.Join(t.TempDir(), "unit")
	for i, want := range []bool{true, false} {
		if did, err := writeIfChanged(p, "a"); err != nil || did != want {
			t.Fatalf("%d: %v %v", i, did, err)
		}
	}
	if did, _ := writeIfChanged(p, "b"); !did {
		t.Fatal("a different text was not written")
	}
}

func TestPokeStartsACronUpdaterWhenTheProgramIsRoot(t *testing.T) {
	useNudgeFile(t)
	dir := t.TempDir()
	mark := filepath.Join(dir, "ran")
	exe := filepath.Join(dir, "updater")
	os.WriteFile(exe, []byte("#!/bin/sh\necho \"$@\" > "+mark+"\n"), 0o700)
	useCron(t, exe, false)
	if _, err := realPoke(); !errors.Is(err, errNoNudge) {
		t.Fatalf("a program that is not root started the updater: %v", err)
	}
	useCron(t, exe, true)
	if said, err := realPoke(); err != nil || !strings.Contains(said, "Started") {
		t.Fatalf("%q %v", said, err)
	}
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(50 * time.Millisecond) {
		if b, _ := os.ReadFile(mark); string(b) == "updater run\n" {
			return
		}
	}
	t.Fatal("the updater was not run with updater run")
}
