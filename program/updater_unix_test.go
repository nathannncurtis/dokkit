//go:build linux || darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReplacedFileKeepsItsMode(t *testing.T) {
	dir := t.TempDir()
	to := filepath.Join(dir, "dokkit")
	os.WriteFile(to, []byte("old"), 0o750)
	os.Chmod(to, 0o750)
	src := filepath.Join(dir, "src")
	os.WriteFile(src, []byte("new"), 0o600)
	if err := putFile(src, to); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(to); fi.Mode().Perm() != 0o750 {
		t.Fatalf("%v", fi.Mode())
	}
	fresh := filepath.Join(dir, "fresh")
	if err := putFile(src, fresh); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(fresh); fi.Mode().Perm() != 0o755 {
		t.Fatalf("a file with nothing to copy from is 0755: %v", fi.Mode())
	}
}

func TestPreviousFileIsKeptWithTheProgramsMode(t *testing.T) {
	r := newRig(t, false)
	os.Chmod(where.programExe, 0o750)
	r.publish("v1.1.0", nil)
	r.wanted = "v1.1.0"
	if updaterRun() != 0 {
		t.Fatalf("%+v", r.results)
	}
	for _, p := range []string{where.programExe, where.programExe + ".previous"} {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != 0o750 {
			t.Fatalf("%s: %v %v", p, fi, err)
		}
	}
}

func TestProgramPathThatIsALinkIsNotCopiedOrReplaced(t *testing.T) {
	r := newRig(t, false)
	secret := filepath.Join(r.dir, "secret")
	os.WriteFile(secret, []byte("root only"), 0o600)
	os.Remove(where.programExe)
	os.Symlink(secret, where.programExe)
	r.publish("v1.1.0", nil)
	r.wanted = "v1.1.0"
	if updaterRun() == 0 {
		t.Fatalf("%+v", r.results)
	}
	if exists(where.programExe+".previous") || r.read(secret) != "root only" {
		t.Fatal("the link's target was copied or replaced")
	}
	if fi, _ := os.Lstat(where.programExe); fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the link was replaced")
	}
}

func TestAHardLinkPutInPlaceOfTheNewFileIsLeftAlone(t *testing.T) {
	dir := t.TempDir()
	secret := filepath.Join(dir, "sudoers")
	os.WriteFile(secret, []byte("root only"), 0o440)
	os.Chmod(secret, 0o440)
	ref := filepath.Join(dir, "dokkit")
	os.WriteFile(ref, []byte("old"), 0o755)
	tmp := ref + ".new"
	if err := os.Link(secret, tmp); err != nil {
		t.Fatal(err)
	}
	if err := keepOwner(tmp, ref); err == nil {
		t.Fatal("a hard link was taken as the new file")
	}
	if fi, _ := os.Stat(secret); fi.Mode().Perm() != 0o440 {
		t.Fatalf("the link's target was changed: %v", fi.Mode())
	}
}

func TestSecondRunIsRefusedByTheLock(t *testing.T) {
	p := filepath.Join(t.TempDir(), "run.lock")
	release, err := lockFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockFile(p); err == nil {
		t.Fatal("two runs at once")
	}
	release()
	if release, err = lockFile(p); err != nil {
		t.Fatal("not released")
	}
	release()
}

func TestRootOnlyRefusesAFolderOthersCanWrite(t *testing.T) {
	d := t.TempDir()
	if os.Geteuid() != 0 && rootOnly(d) == nil {
		t.Fatal("a folder this account owns is not root's")
	}
}
