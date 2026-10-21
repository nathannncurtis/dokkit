package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func TestAccessDeniedBlamesThePromptOnlyWhenItIsNotElevated(t *testing.T) {
	denied := &os.PathError{Op: "open", Path: `C:\ProgramData\dokkit\x`, Err: windows.ERROR_ACCESS_DENIED}
	if got := explainDenied(denied, false); !strings.Contains(got.Error(), "administrator prompt") {
		t.Fatalf("not elevated: %v", got)
	}
	if got := explainDenied(denied, true); got != error(denied) || !strings.Contains(got.Error(), `ProgramData\dokkit\x`) {
		t.Fatalf("elevated must keep the refused path: %v", got)
	}
}

func TestAnUnreadableOldLogIsLeftBehindAndNothingElseIs(t *testing.T) {
	old, dir := t.TempDir(), filepath.Join(t.TempDir(), "new")
	os.WriteFile(filepath.Join(old, "config.json"), []byte("{}"), 0o600)
	os.Mkdir(filepath.Join(old, "spool"), 0o700)
	log := filepath.Join(old, "dokkit.log")
	os.WriteFile(log, []byte("x"), 0o600)
	name, _ := windows.UTF16PtrFromString(log)
	h, err := windows.CreateFile(name, windows.GENERIC_READ, 0, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	if f, err := os.Open(log); err == nil {
		f.Close()
		t.Skip("this file system does not enforce an exclusive open")
	}
	was := lockFolder
	lockFolder = func(string) error { return nil }
	defer func() { lockFolder = was }()
	note, err := copyOwn(old, "x", dir)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(note, "Copied config.json, spool from") || !strings.Contains(note, "dokkit.log could not be read") || !strings.Contains(note, "left behind") {
		t.Fatalf("note: %s", note)
	}
	if _, err := os.Stat(filepath.Join(dir, "config.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "dokkit.log")); err == nil {
		t.Fatal("the log should not have been made")
	}
}

func TestACopiedFileThatCannotBeReadNamesItsPath(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope")
	err := copyFile(missing, filepath.Join(t.TempDir(), "to"))
	if err == nil || !strings.Contains(err.Error(), missing) {
		t.Fatalf("the error must carry the path: %v", err)
	}
}

func TestOtherFailuresInTheMigrationStillStopIt(t *testing.T) {
	old, dir := t.TempDir(), filepath.Join(t.TempDir(), "new")
	os.WriteFile(filepath.Join(old, "config.json"), []byte("{}"), 0o600)
	was := lockFolder
	lockFolder = func(string) error { return errors.New("icacls refused") }
	defer func() { lockFolder = was }()
	if _, err := copyOwn(old, "x", dir); err == nil {
		t.Fatal("a folder that could not be locked must not be filled")
	}
	if _, err := os.Stat(filepath.Join(dir, "config.json")); err == nil {
		t.Fatal("the key was copied into a folder that was never locked")
	}
}

func TestTheFolderIsLockedBeforeAnythingIsCopiedIn(t *testing.T) {
	old, dir := t.TempDir(), filepath.Join(t.TempDir(), "new")
	os.WriteFile(filepath.Join(old, "config.json"), []byte("{}"), 0o600)
	was := lockFolder
	var seen bool
	lockFolder = func(d string) error {
		_, err := os.Stat(filepath.Join(d, "config.json"))
		seen = err != nil
		return nil
	}
	defer func() { lockFolder = was }()
	if _, err := copyOwn(old, "x", dir); err != nil || !seen {
		t.Fatalf("locked after the copy: seen=%v err=%v", seen, err)
	}
}

type fakeService struct {
	started, stopped int
	updateErr        error
	startErr         error
}

func (f *fakeService) Control(svc.Cmd) (svc.Status, error) {
	f.stopped++
	return svc.Status{}, nil
}
func (f *fakeService) Query() (svc.Status, error)    { return svc.Status{State: svc.Stopped}, nil }
func (f *fakeService) Config() (mgr.Config, error)   { return mgr.Config{}, nil }
func (f *fakeService) UpdateConfig(mgr.Config) error { return f.updateErr }
func (f *fakeService) Start(...string) error         { f.started++; return f.startErr }

func TestAFailedUpdateStartsTheStoppedServiceAgain(t *testing.T) {
	root := t.TempDir()
	t.Setenv("ProgramData", root)
	os.MkdirAll(machineDir(), 0o700)
	os.WriteFile(filepath.Join(machineDir(), "config.json"), []byte("{}"), 0o600)
	from := filepath.Join(root, "new.exe")
	os.WriteFile(from, []byte("x"), 0o700)
	f := &fakeService{updateErr: errors.New("boom")}
	err := replaceInstalled(f, from, filepath.Join(root, "in.exe"), func() (string, error) { return "", nil })
	if err == nil || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), "started again") {
		t.Fatalf("message: %v", err)
	}
	if f.stopped != 1 || f.started != 1 {
		t.Fatalf("stopped %d, started %d", f.stopped, f.started)
	}
}

func TestAMigrationFailureAlsoStartsTheServiceAgain(t *testing.T) {
	f := &fakeService{startErr: errors.New("no start")}
	err := replaceInstalled(f, filepath.Join(t.TempDir(), "a.exe"), filepath.Join(t.TempDir(), "b.exe"), func() (string, error) { return "", errors.New("copy failed") })
	if err == nil || !strings.Contains(err.Error(), "copy failed") || !strings.Contains(err.Error(), "could not be started again") {
		t.Fatalf("message: %v", err)
	}
	if f.started != 1 {
		t.Fatalf("started %d", f.started)
	}
}
