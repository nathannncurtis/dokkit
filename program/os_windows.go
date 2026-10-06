package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const serviceName = "dokkit"

// machineDir is where an installed service keeps its configuration and spool.
// Only administrators and the system account can read it.
func machineDir() string { return filepath.Join(os.Getenv("ProgramData"), "dokkit") }

// asService runs watch when Windows started this program as a service.
func asService() bool {
	if is, _ := svc.IsWindowsService(); !is {
		return false
	}
	if out, err := openLog(filepath.Join(machineDir(), "dokkit.log")); err == nil {
		os.Stdout, os.Stderr = out, out
	}
	ordinary = asLocalService
	startService = func(name string) error {
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
		return s.Start()
	}
	svc.Run(serviceName, service{})
	return true
}

type service struct{}

func (service) Execute(_ []string, requests <-chan svc.ChangeRequest, says chan<- svc.Status) (bool, uint32) {
	says <- svc.Status{State: svc.StartPending}
	c, err := load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return false, 1
	}
	go c.watch()
	says <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for r := range requests {
		switch r.Cmd {
		case svc.Interrogate:
			says <- r.CurrentStatus
		case svc.Stop, svc.Shutdown:
			// What is unsent is in the spool and goes on the next start.
			says <- svc.Status{State: svc.StopPending}
			return false, 0
		}
	}
	return false, 0
}

func serviceCommand(action string) int {
	err := func() error {
		m, err := mgr.Connect()
		if err != nil {
			return err
		}
		defer m.Disconnect()
		if action == "install" {
			return install(m)
		}
		s, err := m.OpenService(serviceName)
		if err != nil {
			return errors.New("the service is not installed")
		}
		defer s.Close()
		switch action {
		case "update":
			return updateService(s)
		case "start":
			return s.Start()
		case "stop":
			_, err = s.Control(svc.Stop)
			return err
		}
		s.Control(svc.Stop)
		os.Remove(filepath.Join(machineDir(), "config.json"))
		return s.Delete()
	}()
	if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		err = errors.New("run this from an administrator prompt")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Println("Done:", action)
	return 0
}

// install copies this program and the saved configuration to where only an administrator
// can change them, so the service never runs a file an ordinary account can replace.
func install(m *mgr.Mgr) error {
	if s, err := m.OpenService(serviceName); err == nil {
		s.Close()
		return errors.New("the service is already installed")
	}
	c, err := load()
	if err != nil {
		return err
	}
	dir := machineDir()
	if err := os.MkdirAll(filepath.Join(dir, "spool"), 0o700); err != nil {
		return err
	}
	// The system account and administrators, by their fixed ids, and nobody else.
	if out, err := exec.Command("icacls", dir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F").CombinedOutput(); err != nil {
		return fmt.Errorf("could not lock down %s: %s", dir, out)
	}
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, SystemTasks: c.system, UpdateSha256: c.updateSha})
	if err := os.WriteFile(filepath.Join(dir, "config.json"), b, 0o600); err != nil {
		return err
	}
	from, err := os.Executable()
	if err != nil {
		return err
	}
	to := filepath.Join(os.Getenv("ProgramFiles"), "Dokkit", "dokkit.exe")
	if !sameFile(from, to) {
		if err := copyFile(from, to); err != nil {
			return err
		}
	}
	s, err := m.CreateService(serviceName, to, mgr.Config{
		DisplayName: "Dokkit",
		Description: "Watches this machine and reports to Dokkit. Makes outbound requests only.",
		StartType:   mgr.StartAutomatic,
	})
	if err != nil {
		return err
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{{Type: mgr.ServiceRestart, Delay: time.Minute}}, 86400)
	return s.Start()
}

// detach lets a command outlive this one, with no window of its own.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &windows.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_NEW_PROCESS_GROUP}
}

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// startup makes dokkit watch start when this person signs in, or stops that. It needs no administrator.
func startup(on bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		if err := k.DeleteValue("Dokkit"); err != nil && err != registry.ErrNotExist {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return k.SetStringValue("Dokkit", `"`+exe+`" watch --background`)
}

var (
	kernel32    = windows.NewLazySystemDLL("kernel32.dll")
	memoryCall  = kernel32.NewProc("GlobalMemoryStatusEx")
	cpuTimeCall = kernel32.NewProc("GetSystemTimes")
)

func memoryUsed() (float64, bool) {
	var m struct {
		length, load uint32
		rest         [7]uint64
	}
	m.length = uint32(unsafe.Sizeof(m))
	r, _, _ := memoryCall.Call(uintptr(unsafe.Pointer(&m)))
	return float64(m.load), r != 0
}

// cpuTimes gives the idle and total time the processors have spent since Windows started.
func cpuTimes() (idle, total uint64, ok bool) {
	var i, k, u windows.Filetime
	r, _, _ := cpuTimeCall.Call(uintptr(unsafe.Pointer(&i)), uintptr(unsafe.Pointer(&k)), uintptr(unsafe.Pointer(&u)))
	ticks := func(f windows.Filetime) uint64 { return uint64(f.HighDateTime)<<32 | uint64(f.LowDateTime) }
	// Kernel time includes idle time.
	return ticks(i), ticks(k) + ticks(u), r != 0
}

func findDisks() (all []found) {
	mask, _ := windows.GetLogicalDrives()
	for i := range 26 {
		root := string(rune('A'+i)) + `:\`
		p, _ := windows.UTF16PtrFromString(root)
		var free, total uint64
		if mask&(1<<i) != 0 && windows.GetDriveType(p) == windows.DRIVE_FIXED && windows.GetDiskFreeSpaceEx(p, &free, &total, nil) == nil {
			all = append(all, found{"mount": root, "total_gb": fmt.Sprint(total >> 30), "free_gb": fmt.Sprint(free >> 30)})
		}
	}
	return
}

func sameFile(a, b string) bool {
	x, err1 := os.Stat(a)
	y, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(x, y)
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	out, err := os.Create(to)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

var (
	advapi32  = windows.NewLazySystemDLL("advapi32.dll")
	logonUser = advapi32.NewProc("LogonUserW")
)

// asLocalService makes a command run as Local Service, the account Windows keeps for
// programs that need no rights: it is not an administrator and has no password.
func asLocalService(cmd *exec.Cmd) (func(), error) {
	name, _ := windows.UTF16PtrFromString("LocalService")
	domain, _ := windows.UTF16PtrFromString("NT AUTHORITY")
	const logonService, providerDefault = 5, 0
	var token windows.Token
	ok, _, err := logonUser.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(domain)), 0, logonService, providerDefault, uintptr(unsafe.Pointer(&token)))
	if ok == 0 {
		return nil, err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(token)}
	return func() { token.Close() }, nil
}

func finishUpdate(path string) string {
	return "To finish, on that machine, from an administrator prompt: \"" + path + "\" service update"
}

// updateService puts this copy in the installed one's place. It is run by a person, from
// the newer copy, as an administrator: the service never replaces itself.
func updateService(s *mgr.Service) error {
	from, err := os.Executable()
	if err != nil {
		return err
	}
	to := filepath.Join(os.Getenv("ProgramFiles"), "Dokkit", "dokkit.exe")
	if sameFile(from, to) {
		return errors.New("run this from the newer copy, not from the installed one")
	}
	s.Control(svc.Stop)
	for range 30 {
		if st, err := s.Query(); err != nil || st.State == svc.Stopped {
			break
		}
		time.Sleep(time.Second)
	}
	if err := copyFile(from, to); err != nil {
		return err
	}
	return s.Start()
}
