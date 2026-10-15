package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

const taskName = ownTask

// Tests replace these.
var runTool = func(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}

func realLayout() layout {
	return layout{
		data:       filepath.Join(os.Getenv("ProgramData"), "DokkitUpdater"),
		updaterExe: filepath.Join(os.Getenv("ProgramFiles"), "DokkitUpdater", "dokkit-updater.exe"),
		programExe: installedExe(),
		serverBin:  filepath.Join(os.Getenv("ProgramFiles"), "Dokkit", "bin", "dokkit.bat"),
		serverEnv:  filepath.Join(os.Getenv("ProgramData"), "Dokkit", "settings.env"),
	}
}

func realHost() hostOps {
	return hostOps{
		admin:    func() bool { return windows.GetCurrentProcessToken().IsElevated() },
		lock:     lockFile,
		schedule: upgradeTask,
		tasks:    publishTasks,
		stopService: func(name string) error {
			return withService(name, func(s *mgr.Service) error {
				if st, err := s.Query(); err == nil && st.State == svc.Stopped {
					return nil
				}
				if _, err := s.Control(svc.Stop); err != nil {
					return err
				}
				return waitState(s, svc.Stopped, time.Minute)
			})
		},
		startService: func(name string) error {
			return withService(name, func(s *mgr.Service) error {
				if st, err := s.Query(); err != nil || st.State != svc.Running {
					if err := s.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
						return err
					}
				}
				return waitState(s, svc.Running, 30*time.Second)
			})
		},
		installer: func(ctx context.Context, script string) (string, error) {
			ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
			defer cancel()
			out, err := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script).CombinedOutput()
			return string(out), err
		},
		portUp: func(port string) bool {
			for end := time.Now().Add(2 * time.Minute); time.Now().Before(end); time.Sleep(2 * time.Second) {
				if c, err := net.DialTimeout("tcp", "127.0.0.1:"+port, 3*time.Second); err == nil {
					c.Close()
					return true
				}
			}
			return false
		},
		versionOf: func(exe string) string {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			out, err := exec.CommandContext(ctx, exe, "version").Output()
			if v := strings.TrimSpace(string(out)); err == nil {
				if _, ok := parseVersion(v); ok {
					return v
				}
			}
			return devVersion
		},
	}
}

func publishTasks() {
	dir := machineDir()
	if !exists(dir) {
		return
	}
	err := publishTaskList(filepath.Join(dir, taskListFile), time.Now(), func() ([]string, error) {
		out, err := runTool("schtasks.exe", "/query", "/fo", "csv", "/v")
		return strings.Split(strings.ReplaceAll(out, "\r", ""), "\n"), err
	})
	if err != nil {
		logf("%v", err)
	}
}

func withService(name string, f func(*mgr.Service) error) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(name)
	if err != nil {
		return err
	}
	defer s.Close()
	return f(s)
}

func waitState(s *mgr.Service, want svc.State, within time.Duration) error {
	for end := time.Now().Add(within); time.Now().Before(end); time.Sleep(500 * time.Millisecond) {
		if st, err := s.Query(); err == nil && st.State == want {
			return nil
		}
	}
	return fmt.Errorf("the service did not reach the state %d within %s", want, within)
}

// lockFile holds a file open with no sharing, so a second run cannot open it and
// Windows lets go of it if this one dies.
func lockFile(path string) (func(), error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(p, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return func() { windows.CloseHandle(h) }, nil
}

func updaterCommand(args []string) int {
	if len(args) == 1 {
		switch args[0] {
		case "install":
			return updaterInstall()
		case "uninstall":
			return updaterUninstall()
		case "run":
			return updaterRun()
		case "status":
			return updaterStatus()
		}
	}
	if len(args) >= 2 && args[0] == "rehearse" {
		return updaterRehearse(args[1], len(args) == 3 && args[2] == "--server")
	}
	fmt.Fprintln(os.Stderr, "dokkit updater install|uninstall|run|status, or rehearse <folder> [--server]")
	return 2
}

func keepOwner(tmp, ref string) error { return nil }

func syncDir(string) {}

// updaterSteps is the icacls arguments that close the data folder to everyone but
// administrators and the system account. The folder is set once, without /T, and what is
// in it is reset to inherit: /inheritance:r with /T leaves files with no permissions.
func updaterSteps(dir string) [][]string {
	return [][]string{
		{dir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"},
		{filepath.Join(dir, "*"), "/reset", "/T", "/C"},
	}
}

const eventKey = `SYSTEM\CurrentControlSet\Services\EventLog\Application\` + eventSource

var registerSource = func() error {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, eventKey, registry.QUERY_VALUE)
	if err == nil {
		k.Close()
		return nil
	}
	return eventlog.InstallAsEventCreate(eventSource, eventlog.Info)
}

// eventQuery matches the entry the program writes to ask for a check.
var eventQuery = "*[System[Provider[@Name='" + eventSource + "'] and EventID=" + strconv.Itoa(eventID) + "]]"

const markHere = "@schedule@"

// taskMarker names this exact task text. It is in the task's description, so a task that carries it is current.
func taskMarker(exe string) string {
	sum := sha256.Sum256([]byte(taskTemplate(exe)))
	return "schedule " + hex.EncodeToString(sum[:6])
}

// taskXML is the scheduled task: the system account, highest rights, every five minutes, at start-up and when the program asks.
func taskXML(exe string) []byte {
	s := strings.Replace(taskTemplate(exe), markHere, taskMarker(exe), 1)
	u := utf16.Encode([]rune(s))
	b := []byte{0xFF, 0xFE}
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	return b
}

var subscription = xmlEscape(`<QueryList><Query Id="0" Path="Application"><Select Path="Application">` + eventQuery + `</Select></Query></QueryList>`)

func taskTemplate(exe string) string {
	esc := xmlEscape(`"` + exe + `"`)
	return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Installs the Dokkit releases a person approved. Makes outbound requests only. ` + markHere + `</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger><Repetition><Interval>PT5M</Interval></Repetition><StartBoundary>2026-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>` + subscription + `</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>` + esc + `</Command><Arguments>updater run</Arguments></Exec></Actions>
</Task>
`
}

func registerTask(exe string) error {
	if err := registerSource(); err != nil {
		return fmt.Errorf("could not register the %s event source: %v", eventSource, err)
	}
	xmlFile := filepath.Join(where.work(), "task.xml")
	if err := os.WriteFile(xmlFile, taskXML(exe), 0o600); err != nil {
		return err
	}
	if out, err := runTool("schtasks.exe", "/create", "/tn", taskName, "/xml", xmlFile, "/f"); err != nil {
		return fmt.Errorf("schtasks could not register the task: %v\n%s", err, out)
	}
	return nil
}

// upgradeTask registers the task again when the installed one is not the current text, so
// a machine that got the updater long ago gets what a newer updater needs. A missing task is left missing.
func upgradeTask() {
	out, err := runTool("schtasks.exe", "/query", "/tn", taskName, "/xml")
	if err != nil || strings.Contains(out, taskMarker(where.updaterExe)) {
		return
	}
	logf("the updater's task is out of date; registering it again")
	if err := registerTask(where.updaterExe); err != nil {
		logf("could not register the updater's task again: %v", err)
	}
}

func updaterInstall() int {
	if !ops.admin() {
		return needAdmin("install")
	}
	if serviceConfig() == "" {
		fmt.Fprintln(os.Stderr, "dokkit: the program's service is not installed, so the updater has no address or key to use. Nothing was changed. Install the service first, "+elevated("service", "install"))
		return 1
	}
	if err := installChecks(); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	if err := installUpdater(); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Println("The updater is installed. Running one check:")
	code := updaterRun()
	updaterStatus()
	return code
}

// installChecks refuses, before anything is changed, a folder that is not ours to secure.
func installChecks() error {
	if exists(where.data) {
		if err := trustedOwner(where.data); err != nil {
			return err
		}
		names, err := dirNames(where.data)
		if err != nil {
			return err
		}
		for _, n := range names {
			if n != "state.json" && n != "updater.log" && n != "work" {
				return fmt.Errorf("%s holds %s, which the updater did not put there. It keeps only state.json, updater.log and work in that folder. Nothing was changed. Move those out, then install again", where.data, n)
			}
		}
	}
	if dir := filepath.Dir(where.updaterExe); exists(dir) {
		if err := trustedOwner(dir); err != nil {
			return err
		}
		if err := writableByOthers(dir); err != nil {
			return fmt.Errorf("%s can be changed by accounts other than administrators (%v). Nothing was changed", dir, err)
		}
	}
	return nil
}

func installUpdater() error {
	if err := os.MkdirAll(where.work(), 0o700); err != nil {
		return err
	}
	f, err := openLog(filepath.Join(where.data, "updater.log"))
	if err != nil {
		return err
	}
	f.Close()
	for _, args := range updaterSteps(where.data) {
		if out, err := runTool("icacls", args...); err != nil {
			return fmt.Errorf("could not set who may use %s: %s", args[0], out)
		}
	}
	from, err := os.Executable()
	if err != nil {
		return err
	}
	if !sameFile(from, where.updaterExe) {
		if err := os.MkdirAll(filepath.Dir(where.updaterExe), 0o755); err != nil {
			return err
		}
		if err := swapSelf(from, where.updaterExe); err != nil {
			return err
		}
	}
	return registerTask(where.updaterExe)
}

func updaterUninstall() int {
	if !ops.admin() {
		return needAdmin("uninstall")
	}
	if _, err := runTool("schtasks.exe", "/query", "/tn", taskName); err == nil {
		if out, err := runTool("schtasks.exe", "/delete", "/tn", taskName, "/f"); err != nil {
			fmt.Fprintf(os.Stderr, "dokkit: schtasks could not remove the task: %v\n%s", err, out)
			return 1
		}
	}
	eventlog.Remove(eventSource)
	for _, p := range []string{where.updaterExe, where.updaterExe + ".previous"} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "dokkit: could not remove %s: %v\n", p, err)
			return 1
		}
	}
	os.Remove(filepath.Dir(where.updaterExe))
	fmt.Println("Done: the task and the updater's file are removed. Its state and log are still in", where.data)
	return 0
}
