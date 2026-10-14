package main

import (
	"encoding/xml"
	"errors"
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

func taskText(exe string) string {
	b := taskXML(exe)
	u := make([]uint16, 0, len(b)/2)
	for i := 2; i+1 < len(b); i += 2 {
		u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
	}
	return string(utf16.Decode(u))
}

func TestTaskLetsLocalServiceStartItAndNothingMore(t *testing.T) {
	s := taskText(`C:\x\u.exe`)
	want := "<SecurityDescriptor>D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;LS)</SecurityDescriptor>"
	if !strings.Contains(s, want) {
		t.Fatalf("no security descriptor for Local Service: %s", s)
	}
	if strings.Contains(s, "S-1-5-19") || strings.Contains(s, "FA;;;LS") || strings.Contains(s, "GA;;;LS") {
		t.Fatal("Local Service may change the task")
	}
	if !strings.Contains(s, taskMarker(`C:\x\u.exe`)) || taskMarker(`C:\x\u.exe`) == taskMarker(`C:\y\u.exe`) {
		t.Fatal("the task does not carry a marker of its own text")
	}
}

func TestUpgradeTaskRegistersOnlyAnOutOfDateTask(t *testing.T) {
	r := newRig(t, false)
	where.updaterExe = `C:\Program Files\DokkitUpdater\dokkit-updater.exe`
	os.MkdirAll(where.work(), 0o700)
	old := runTool
	defer func() { runTool = old }()
	installed := "<Task>old text</Task>"
	var calls []string
	runTool = func(name string, args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		switch args[0] {
		case "/query":
			return installed, nil
		case "/create":
			installed = taskText(where.updaterExe)
		}
		return "", nil
	}
	upgradeTask()
	upgradeTask()
	creates := 0
	for _, c := range calls {
		if strings.HasPrefix(c, "/create") {
			creates++
		}
	}
	if creates != 1 || !strings.Contains(r.read(filepath.Join(where.data, "updater.log")), "out of date") {
		t.Fatalf("%q", calls)
	}
	runTool = func(string, ...string) (string, error) { return "", os.ErrNotExist }
	upgradeTask()
}

func TestPokeStartsTheTaskByName(t *testing.T) {
	old := runTool
	defer func() { runTool = old }()
	var got string
	runTool = func(name string, args ...string) (string, error) {
		got = name + " " + strings.Join(args, " ")
		return "", nil
	}
	if _, err := realPoke(); err != nil || got != `schtasks.exe /run /tn Dokkit updater` {
		t.Fatalf("%q %v", got, err)
	}
	runTool = func(string, ...string) (string, error) { return "ERROR: Access is denied.", os.ErrPermission }
	if _, err := realPoke(); err == nil || !strings.Contains(err.Error(), "Access is denied") {
		t.Fatalf("%v", err)
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

func TestPokeThatSchtasksRefusesCarriesItsExitAndOutput(t *testing.T) {
	old := runTool
	defer func() { runTool = old }()
	runTool = func(string, ...string) (string, error) {
		return "ERROR: Access is denied.\r\n", errors.New("exit status 1")
	}
	if _, err := realPoke(); err == nil || err.Error() != "schtasks: exit status 1 ERROR: Access is denied." {
		t.Fatalf("%v", err)
	}
}
