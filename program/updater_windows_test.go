package main

import (
	"encoding/xml"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf16"
)

func TestPermissionStepsNeverCombineInheritanceAndRecursion(t *testing.T) {
	steps := updaterSteps(`C:\ProgramData\DokkitUpdater`)
	for _, s := range steps {
		j := strings.Join(s, " ")
		if strings.Contains(j, "/inheritance:r") && strings.Contains(j, "/T") {
			t.Fatal(j)
		}
		if strings.Contains(j, "S-1-5-19") {
			t.Fatal("Local Service is given access")
		}
	}
	if !strings.Contains(strings.Join(steps[1], " "), `DokkitUpdater\* /reset /T /C`) {
		t.Fatalf("%v", steps[1])
	}
}

func TestTaskXMLIsWellFormedUTF16(t *testing.T) {
	b := taskXML(`C:\Program Files\DokkitUpdater\dokkit-updater.exe`)
	if b[0] != 0xFF || b[1] != 0xFE {
		t.Fatal("no byte order mark")
	}
	u := make([]uint16, 0, len(b)/2)
	for i := 2; i+1 < len(b); i += 2 {
		u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
	}
	s := string(utf16.Decode(u))
	d := xml.NewDecoder(strings.NewReader(strings.Replace(s, `encoding="UTF-16"`, `encoding="UTF-8"`, 1)))
	for {
		if _, err := d.Token(); err != nil {
			if err.Error() != "EOF" {
				t.Fatal(err)
			}
			break
		}
	}
	for _, w := range []string{"PT5M", "BootTrigger", "S-1-5-18", "HighestAvailable", `<Command>"C:\Program Files\DokkitUpdater\dokkit-updater.exe"</Command>`, "<Arguments>updater run</Arguments>"} {
		if !strings.Contains(s, w) {
			t.Errorf("missing %s", w)
		}
	}
	if p := os.Getenv("DOKKIT_TASK_XML"); p != "" {
		os.WriteFile(p, b, 0o600)
	}
}

func TestSecondRunCannotTakeTheLock(t *testing.T) {
	p := filepath.Join(t.TempDir(), "run.lock")
	release, err := lockFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockFile(p); err == nil {
		t.Fatal("two runs held the lock")
	}
	release()
	if r2, err := lockFile(p); err != nil {
		t.Fatal(err)
	} else {
		r2()
	}
}

