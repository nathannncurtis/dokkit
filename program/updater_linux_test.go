//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
