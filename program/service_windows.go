package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
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
	log := filepath.Join(machineDir(), "dokkit.log")
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(log); err == nil && info.Size() > 5<<20 {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	if out, err := os.OpenFile(log, flags, 0o600); err == nil {
		os.Stdout, os.Stderr = out, out
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
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Folders: c.folders})
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
