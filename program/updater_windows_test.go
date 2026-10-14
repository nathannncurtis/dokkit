package main

import (
	"encoding/xml"
	"errors"
	"golang.org/x/sys/windows/svc/eventlog"
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

func TestTaskStartsOnTheProgramsEventAndKeepsItsOtherTriggers(t *testing.T) {
	s := taskText(`C:\x\u.exe`)
	for _, w := range []string{
		`<EventTrigger><Enabled>true</Enabled><Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Application"&gt;&lt;Select Path="Application"&gt;*[System[Provider[@Name='Dokkit'] and EventID=100]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger>`,
		"<TimeTrigger>", "<BootTrigger>", "PT5M", "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>",
	} {
		if !strings.Contains(s, w) {
			t.Errorf("missing %s", w)
		}
	}
	if strings.Contains(s, "SecurityDescriptor") || strings.Contains(s, "S-1-5-19") {
		t.Fatal("the task carries a descriptor for Local Service")
	}
	if !strings.Contains(s, taskMarker(`C:\x\u.exe`)) || taskMarker(`C:\x\u.exe`) == taskMarker(`C:\y\u.exe`) {
		t.Fatal("the task does not carry a marker of its own text")
	}
}

func TestRegisteringTheTaskRegistersTheEventSourceFirst(t *testing.T) {
	newRig(t, false)
	os.MkdirAll(where.work(), 0o700)
	old, oldSrc := runTool, registerSource
	defer func() { runTool, registerSource = old, oldSrc }()
	var order []string
	registerSource = func() error { order = append(order, "source"); return nil }
	runTool = func(string, ...string) (string, error) { order = append(order, "task"); return "", nil }
	if err := registerTask(`C:\x\u.exe`); err != nil || strings.Join(order, " ") != "source task" {
		t.Fatalf("%v %v", order, err)
	}
	registerSource = func() error { return errors.New("no registry") }
	if err := registerTask(`C:\x\u.exe`); err == nil || !strings.Contains(err.Error(), "no registry") {
		t.Fatalf("%v", err)
	}
}

func TestEventSourceIsRegisteredOnceAndLeftAlone(t *testing.T) {
	if os.Getenv("DOKKIT_TEST_EVENT_SOURCE") == "" {
		t.Skip("registers a source in HKLM; needs administrator rights")
	}
	defer eventlog.Remove(eventSource)
	for i := 0; i < 2; i++ {
		if err := registerSource(); err != nil {
			t.Fatal(i, err)
		}
	}
}

func TestUpgradeTaskRegistersOnlyAnOutOfDateTask(t *testing.T) {
	r := newRig(t, false)
	where.updaterExe = `C:\Program Files\DokkitUpdater\dokkit-updater.exe`
	os.MkdirAll(where.work(), 0o700)
	old, oldSrc := runTool, registerSource
	defer func() { runTool, registerSource = old, oldSrc }()
	registerSource = func() error { return nil }
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

func TestPokeWritesOneEventFromTheDokkitSource(t *testing.T) {
	old := writeEvent
	defer func() { writeEvent = old }()
	n := 0
	writeEvent = func() error { n++; return nil }
	said, err := realPoke()
	if err != nil || n != 1 || said != "Asked the updater to check now (event written).\n" {
		t.Fatalf("%q %v %d", said, err, n)
	}
	if eventSource != "Dokkit" || eventID != 100 {
		t.Fatal(eventSource, eventID)
	}
	writeEvent = func() error { return errors.New("The handle is invalid.") }
	if _, err := realPoke(); err == nil || err.Error() != "The handle is invalid." {
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

func TestRealEventWrite(t *testing.T) {
	if os.Getenv("DOKKIT_TEST_EVENT_WRITE") == "" {
		t.Skip("writes to the Application log")
	}
	if _, err := realPoke(); err != nil {
		t.Fatal(err)
	}
}
