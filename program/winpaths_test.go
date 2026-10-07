package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestTheProgramsFoldersAreNotTheServers(t *testing.T) {
	if got := newData(`C:\ProgramData`); !strings.EqualFold(got, filepath.Join(`C:\ProgramData`, "DokkitProgram")) {
		t.Fatal(got)
	}
	if got := newExe(`C:\Program Files`); !strings.EqualFold(got, filepath.Join(`C:\Program Files`, "DokkitProgram", "dokkit.exe")) {
		t.Fatal(got)
	}
	for _, p := range [][2]string{{newData("r"), oldData("r")}, {newExe("r"), oldExe("r")}} {
		if strings.EqualFold(filepath.Dir(p[0]), filepath.Dir(p[1])) && strings.EqualFold(filepath.Base(p[0]), filepath.Base(p[1])) {
			t.Fatalf("%s is the old folder", p[0])
		}
	}
	if strings.EqualFold(filepath.Dir(newExe("r")), filepath.Dir(oldExe("r"))) {
		t.Fatal("the exe folder is the server's")
	}
}

func TestOnlyTheProgramsThreeItemsAreItsOwn(t *testing.T) {
	for _, n := range []string{"config.json", "SPOOL", "Dokkit.log"} {
		if !isOwnItem(n) {
			t.Errorf("%s is the program's", n)
		}
	}
	for _, n := range []string{"settings.env", "pgdata", "log", "cert.pem", "update", "dokkit.exe"} {
		if isOwnItem(n) {
			t.Errorf("%s is not the program's", n)
		}
	}
}

func TestInheritanceIsRemovedFromTheFolderAloneThenTheInsideIsReset(t *testing.T) {
	steps := permissionSteps(`C:\d`, "*S-1-5-32-544")
	for i, s := range steps {
		for _, x := range s {
			if x == "/inheritance:r" && strings.Contains(strings.Join(s, " "), "/T") {
				t.Fatalf("step %d removes inheritance from every file", i)
			}
		}
	}
	if strings.Join(steps[2], " ") != `C:\d\* /reset /T /C` {
		t.Fatal(steps[2])
	}
}

func TestAFolderWithAnythingElseIsRefusedAndSaysWhat(t *testing.T) {
	if err := refusal("d", []string{"config.json", "spool", "dokkit.log", "Update"}); err != nil {
		t.Fatal(err)
	}
	if err := refusal("d", nil); err != nil {
		t.Fatal(err)
	}
	err := refusal("d", []string{"config.json", "pgdata", "settings.env"})
	if err == nil || !strings.Contains(err.Error(), "pgdata, settings.env") || strings.Contains(err.Error(), "holds config") {
		t.Fatal(err)
	}
}
