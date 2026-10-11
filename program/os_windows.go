package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
// Only administrators and the system account can write it.
func machineDir() string { return newData(os.Getenv("ProgramData")) }

func installedExe() string { return newExe(os.Getenv("ProgramFiles")) }

// installedServiceConfig is the installed service's configuration file, or "" when there is no service.
// An ordinary account may not open the service, so any answer but "no such service" counts as installed.
func installedServiceConfig() string {
	m, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return ""
	}
	defer windows.CloseServiceHandle(m)
	name, _ := windows.UTF16PtrFromString(serviceName)
	h, err := windows.OpenService(m, name, windows.SERVICE_QUERY_STATUS)
	if err == nil {
		windows.CloseServiceHandle(h)
	} else if err == windows.ERROR_SERVICE_DOES_NOT_EXIST {
		return ""
	}
	return filepath.Join(machineDir(), "config.json")
}

// ownedByService has nothing to do: the folder the file is in already limits it to administrators.
func ownedByService(string) error { return nil }

// refuseFolders is true in the installed service when its folder or configuration file can be
// changed by anyone but administrators, so the folders it names are not read.
func refuseFolders() bool {
	if is, _ := svc.IsWindowsService(); !is {
		return false
	}
	dir := machineDir()
	file := filepath.Join(dir, "config.json")
	return trustedOwner(dir) != nil || writableByOthers(dir) != nil || writableByOthers(file) != nil
}

// serviceFiles is for Linux; Windows reads machineDir for every command.
func serviceFiles() (string, string) { return "", "" }

// The installed service's config.json carries the lists; there is no other place.
func listsPath() string { return "" }

// asService runs watch when Windows started this program as a service.
func asService() bool {
	if is, _ := svc.IsWindowsService(); !is {
		return false
	}
	if out, err := openLog(filepath.Join(machineDir(), "dokkit.log")); err == nil {
		os.Stdout, os.Stderr = out, out
	}
	// The service is Local Service, and like the Linux service it fetches no update for an administrator to run.
	runningAsService = func() bool { return true }
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
		// The address and key go; the restart and hosts lists stay for the next install.
		file := filepath.Join(machineDir(), "config.json")
		var l saved
		if keep, err := os.ReadFile(file); err == nil && trustedOwner(file) == nil {
			json.Unmarshal(keep, &l)
		}
		b, _ := json.Marshal(saved{Restart: l.Restart, Hosts: l.Hosts})
		os.WriteFile(file, b, 0o600)
		return s.Delete()
	}()
	err = explainDenied(err, windows.GetCurrentProcessToken().IsElevated())
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Println("Done:", action)
	if action == "uninstall" {
		fmt.Println(stillEnrolled)
	}
	return 0
}

// explainDenied blames the prompt only when it is not elevated; otherwise the refused path in err is the answer.
func explainDenied(err error, elevated bool) error {
	if errors.Is(err, windows.ERROR_ACCESS_DENIED) && !elevated {
		return errors.New("run this from an administrator prompt")
	}
	return err
}

// install copies this program and the saved configuration to where only an administrator
// can change them, so the service never runs a file an ordinary account can replace.
func install(m *mgr.Mgr) error {
	if s, err := m.OpenService(serviceName); err == nil {
		s.Close()
		return errors.New("the service is already installed")
	}
	dir := machineDir()
	if _, err := os.Stat(dir); err == nil {
		if err := trustedOwner(dir); err != nil {
			return err
		}
		if names, err := dirNames(dir); err != nil {
			return err
		} else if err := refusal(dir, names); err != nil {
			return err
		}
	}
	if p, err := configPath(); err == nil && os.Getenv("DOKKIT_CONFIG") == "" {
		os.Setenv("DOKKIT_CONFIG", p) // the address and key come from the person installing, never from the folder
	}
	c, err := load()
	if err != nil {
		return err
	}
	note, err := migrateOld()
	if err != nil {
		return err
	}
	// A config.json left in the folder counts only for its two lists, and only if an administrator owns it.
	file := filepath.Join(dir, "config.json")
	var lists saved
	if b, err := os.ReadFile(file); err == nil && trustedOwner(file) == nil {
		json.Unmarshal(b, &lists)
	}
	log := filepath.Join(dir, "dokkit.log")
	os.RemoveAll(filepath.Join(dir, "update"))
	if err := secure(dir); err != nil {
		return err
	}
	os.Remove(file)
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, Restart: lists.Restart, Hosts: lists.Hosts, SpoolMB: int(c.spoolMB), UpdateSha256: c.updateSha})
	if err := os.WriteFile(file, b, 0o600); err != nil {
		return err
	}
	fmt.Print(note)
	from, err := os.Executable()
	if err != nil {
		return err
	}
	to := installedExe()
	if !sameFile(from, to) {
		if err := copyFile(from, to); err != nil {
			return err
		}
	}
	s, err := m.CreateService(serviceName, to, mgr.Config{
		DisplayName:      "Dokkit",
		Description:      "Watches this machine and reports to Dokkit. Makes outbound requests only.",
		StartType:        mgr.StartAutomatic,
		ServiceStartName: `NT AUTHORITY\LocalService`,
	})
	if err != nil {
		return err
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{{Type: mgr.ServiceRestart, Delay: time.Minute}}, 86400)
	if len(c.folders) == 0 {
		fmt.Println("The service reads no folders yet. To add one, run it " + elevated("folder", "add", "<path>"))
	}
	if err := s.Start(); err != nil {
		return err
	}
	// Installed means running, not registered.
	for range 30 {
		if st, err := s.Query(); err == nil && st.State == svc.Running {
			fmt.Println("The service is running as Local Service.")
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	said, _ := os.ReadFile(log)
	if len(said) > 2000 {
		said = said[len(said)-2000:]
	}
	return fmt.Errorf("the service is installed but did not stay running. The end of %s:\n%s", log, said)
}

// secure makes the folder, its spool and its log, and sets who may use them. The folder is set once,
// without /T, and what is inside is reset to inherit from it: with /T, inheritance goes from every
// file too, and an entry that applies to folders leaves a file with no permissions at all.
func secure(dir string) error {
	spool, log := filepath.Join(dir, "spool"), filepath.Join(dir, "dokkit.log")
	if err := os.MkdirAll(spool, 0o700); err != nil {
		return err
	}
	f, err := openLog(log)
	if err != nil {
		return err
	}
	f.Close()
	for _, args := range permissionSteps(dir, "*S-1-5-32-544") {
		if out, err := exec.Command("icacls", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("could not set who may use %s: %s", args[0], out)
		}
	}
	return nil
}

func dirNames(dir string) (names []string, err error) {
	es, err := os.ReadDir(dir)
	for _, e := range es {
		names = append(names, e.Name())
	}
	return
}

// migrateOld copies the program's own config.json, spool and dokkit.log out of the old folders, which
// the server's installer also uses, when an administrator-owned install is in them. Nothing in the old
// folders is changed or removed, and nothing else in them is read. It returns what to tell the person.
func migrateOld() (string, error) {
	od, ox := oldData(os.Getenv("ProgramData")), oldExe(os.Getenv("ProgramFiles"))
	oc := filepath.Join(od, "config.json")
	if _, err := os.Stat(ox); err != nil {
		return "", nil
	}
	if _, err := os.Stat(oc); err != nil || trustedOwner(oc) != nil {
		return "", nil
	}
	return copyOwn(od, ox, machineDir())
}

// lockFolder gives a new folder its owner and permissions before anything is copied in, so files made in it inherit them.
var lockFolder = func(dir string) error {
	for _, args := range permissionSteps(dir, "*S-1-5-32-544")[:2] {
		if out, err := exec.Command("icacls", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("could not set who may use %s: %s", args[0], out)
		}
	}
	return nil
}

func copyOwn(od, ox, dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := lockFolder(dir); err != nil {
		return "", err
	}
	var copied []string
	var left string
	for _, n := range ownItems {
		to := filepath.Join(dir, n)
		if _, err := os.Stat(to); err == nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(od, n)); err != nil {
			continue
		}
		if err := copyTree(filepath.Join(od, n), to); err != nil {
			if n == "dokkit.log" {
				left = fmt.Sprintf(" %s could not be read (%v), so it was left behind.", n, err)
				continue
			}
			return "", err
		}
		copied = append(copied, n)
	}
	return fmt.Sprintf("Copied %s from %s to %s.%s The old copies are still in %s, with %s, and nothing else there was touched. Delete them when you are sure.\n", strings.Join(copied, ", "), od, dir, left, od, ox), nil
}

func copyTree(from, to string) error {
	return filepath.WalkDir(from, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		if e.IsDir() {
			return os.MkdirAll(filepath.Join(to, rel), 0o700)
		}
		return copyFile(p, filepath.Join(to, rel))
	})
}

// trustedOwner refuses a folder that someone else made first: its owner could change its
// permissions again after the install, whatever they are set to now.
func trustedOwner(dir string) error {
	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	if owner.IsWellKnown(windows.WinLocalSystemSid) || owner.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
		return nil
	}
	return fmt.Errorf("%s already exists and is owned by %s, not by administrators. Delete it from an administrator prompt, then install again", dir, owner)
}

// Rights that let an account change a file or folder, or what is in it.
const writeRights = 0x2 | 0x4 | 0x40 | 0x10000 | 0x40000 | 0x80000 | 0x40000000 | 0x10000000

var trustedTrustees = []string{"S-1-5-18", "S-1-5-32-544", "S-1-3-0", "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"}

// writableByOthers is an error when the path grants write to anyone but administrators, the
// system account, TrustedInstaller or the creator-owner placeholder.
func writableByOthers(path string) error {
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil {
		return errors.New("anyone can write")
	}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, i, &ace) != nil {
			return errors.New("the permissions could not be read")
		}
		// Only allow entries that apply to this object itself count.
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 || uint32(ace.Mask)&writeRights == 0 {
			continue
		}
		who := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		trusted := false
		for _, s := range trustedTrustees {
			if t, err := windows.StringToSid(s); err == nil && who.Equals(t) {
				trusted = true
			}
		}
		if !trusted {
			return fmt.Errorf("%s can write", who)
		}
	}
	return nil
}

// fileIdentity names the file itself, whatever its path: the volume and the index on it.
func fileIdentity(f *os.File) string {
	var i windows.ByHandleFileInformation
	if windows.GetFileInformationByHandle(windows.Handle(f.Fd()), &i) != nil {
		return ""
	}
	return fmt.Sprintf("%d:%d:%d", i.VolumeSerialNumber, i.FileIndexHigh, i.FileIndexLow)
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
			all = append(all, found{"mount": root, "total_gb": fmt.Sprint(total >> 30), "free_gb": fmt.Sprint(free >> 30), "total_bytes": fmt.Sprint(total), "free_bytes": fmt.Sprint(free)})
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

func finishUpdate(path string) string {
	return "To finish, on that machine, from an administrator prompt: \"" + path + "\" service update"
}

type installedService interface {
	Control(svc.Cmd) (svc.Status, error)
	Query() (svc.Status, error)
	Config() (mgr.Config, error)
	UpdateConfig(mgr.Config) error
	Start(...string) error
}

// updateService puts this copy in the installed one's place. It is run by a person, from
// the newer copy, as an administrator: the service never replaces itself.
func updateService(s *mgr.Service) error {
	from, err := os.Executable()
	if err != nil {
		return err
	}
	return replaceInstalled(s, from, installedExe(), migrateOld)
}

func replaceInstalled(s installedService, from, to string, migrate func() (string, error)) error {
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
	note, err := swap(s, from, to, migrate)
	if err != nil {
		if serr := s.Start(); serr != nil {
			return fmt.Errorf("%w. The service is stopped and could not be started again: %v", err, serr)
		}
		return fmt.Errorf("%w. The service was started again as it was", err)
	}
	fmt.Print(note)
	return s.Start()
}

func swap(s installedService, from, to string, migrate func() (string, error)) (string, error) {
	note, err := migrate()
	if err != nil {
		return "", err
	}
	file := filepath.Join(machineDir(), "config.json")
	if _, err := os.Stat(file); err != nil {
		return "", fmt.Errorf("no configuration is in %s, or in the old %s", machineDir(), oldData(os.Getenv("ProgramData")))
	}
	if note != "" {
		if err := secure(machineDir()); err != nil {
			return "", err
		}
	}
	if err := copyFile(from, to); err != nil {
		return "", err
	}
	cfg, err := s.Config()
	if err != nil {
		return "", err
	}
	cfg.BinaryPathName = syscall.EscapeArg(to)
	// Blank leaves the account as it is; naming it again would need its password.
	cfg.ServiceStartName = ""
	if err := s.UpdateConfig(cfg); err != nil {
		return "", fmt.Errorf("could not point the service at %s: %w", to, err)
	}
	return note, nil
}
