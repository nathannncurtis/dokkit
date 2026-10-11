//go:build linux || darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var upConfigPath = filepath.Join(updaterDir, "config.json")

func init() {
	loadClient = programClient
	statusExtra = func() {
		if c, err := readUpConfig(); err == nil {
			how := c.Method
			if c.Unit != "" {
				how += " " + c.Unit
			}
			fmt.Printf("Looks after: %s, run by %s (%s)\n", c.Program, c.User, how)
		}
	}
}

func readUpConfig() (upConfig, error) {
	b, err := os.ReadFile(upConfigPath)
	if err != nil {
		return upConfig{}, err
	}
	return decodeUpConfig(b)
}

// programClient reads the program's own address and key, as root, from the file the updater recorded.
func programClient() (*client, error) {
	c, err := readUpConfig()
	if err != nil {
		return nil, err
	}
	os.Setenv("DOKKIT_CONFIG", c.Config)
	os.Setenv("DOKKIT_SPOOL", filepath.Join(updaterData, "spool"))
	return load()
}

func realLayout() layout {
	l := layout{data: updaterData, updaterExe: filepath.Join(updaterDir, "dokkit")}
	if c, err := readUpConfig(); err == nil {
		l.programExe = c.Program
	}
	return l
}

func realHost() hostOps {
	return hostOps{
		admin: func() bool { return os.Geteuid() == 0 },
		lock:  lockFile,
		// A running file is replaced by renaming, so the restart is the only stop there is.
		stopService: func(string) error { return nil },
		startService: func(string) error {
			c, err := readUpConfig()
			if err != nil {
				return err
			}
			return restartProgram(c)
		},
		installer: func(context.Context, string) (string, error) {
			return "", errors.New("this system does not run the server from the updater")
		},
		portUp:    func(string) bool { return false },
		versionOf: versionAs,
	}
}

func lockFile(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return func() { f.Close() }, nil
}

func sameFile(a, b string) bool {
	x, err1 := os.Stat(a)
	y, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(x, y)
}

// keepOwner gives a new file the owner and mode of the one it will replace, or 0755 when there
// is none. It works on the open file, so a link put in its place is not followed.
func keepOwner(tmp, ref string) error {
	f, err := os.OpenFile(tmp, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := os.Stat(ref)
	if err != nil {
		return f.Chmod(0o755)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		if err := f.Chown(int(st.Uid), int(st.Gid)); err != nil {
			return err
		}
	}
	return f.Chmod(fi.Mode().Perm())
}

func syncDir(dir string) {
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
}

func account(uid int) (name, home string, gid int) {
	if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
		gid, _ = strconv.Atoi(u.Gid)
		return u.Username, u.HomeDir, gid
	}
	return "", "", 0
}

// asUser makes root run a command as the account that owns the program, so a file that
// account can write is never run with more rights than it has.
func asUser(cmd *exec.Cmd, c upConfig) {
	if os.Geteuid() == 0 && c.UID != 0 {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uint32(c.UID), Gid: uint32(c.GID)}}
	}
}

func versionAs(exe string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, "version")
	cmd.Dir = "/"
	if c, err := readUpConfig(); err == nil && exe == c.Program {
		asUser(cmd, c)
	}
	if out, err := cmd.Output(); err == nil {
		if v := strings.TrimSpace(string(out)); v != "" {
			if _, ok := parseVersion(v); ok {
				return v
			}
		}
	}
	return devVersion
}

func readStatus(spool string) (s status, ok bool) {
	b, err := os.ReadFile(filepath.Join(spool, "status.json"))
	return s, err == nil && json.Unmarshal(b, &s) == nil
}

// restartProgram restarts the program the way it is kept, then waits until it is running.
func restartProgram(c upConfig) error {
	if c.Method == methodProcess {
		return restartProcess(c)
	}
	argv := restartArgv(c)
	if out, err := runCmd(argv[0], argv[1:]...); err != nil {
		return fmt.Errorf("%s: %v %s", argv[0], err, tail(string(out), 300))
	}
	argv = activeArgv(c)
	up := func() bool {
		out, _ := runCmd(argv[0], argv[1:]...)
		return isRunning(c.Method, string(out))
	}
	for end := time.Now().Add(30 * time.Second); time.Now().Before(end); time.Sleep(time.Second) {
		if up() {
			time.Sleep(5 * time.Second)
			if up() {
				return nil
			}
		}
	}
	return fmt.Errorf("%s was restarted but is not running", c.Unit)
}

// runningPid is the recorded process of the program, only when it is alive and is the program's file.
func runningPid(c upConfig) int {
	if s, ok := readStatus(c.Spool); ok && s.Pid > 0 && pidAlive(s.Pid) && pidIsProgram(exeOf(s.Pid), c.Program) {
		return s.Pid
	}
	return 0
}

func stopPid(pid int) error {
	syscall.Kill(pid, syscall.SIGTERM)
	for _, sig := range []syscall.Signal{0, syscall.SIGKILL} {
		if sig != 0 {
			syscall.Kill(pid, sig)
		}
		for end := time.Now().Add(20 * time.Second); time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
			if !pidAlive(pid) {
				return nil
			}
		}
	}
	return fmt.Errorf("process %d did not stop", pid)
}

func restartProcess(c upConfig) error {
	old := runningPid(c)
	if old != 0 {
		if err := stopPid(old); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Program, "watch", "--background")
	cmd.Env, cmd.Dir = childEnv(c), "/"
	asUser(cmd, c)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("could not start %s: %v %s", c.Program, err, tail(string(out), 300))
	}
	for end := time.Now().Add(30 * time.Second); time.Now().Before(end); time.Sleep(time.Second) {
		if s, ok := readStatus(c.Spool); ok && s.Pid != old && pidAlive(s.Pid) && pidIsProgram(exeOf(s.Pid), c.Program) {
			time.Sleep(3 * time.Second)
			if pidAlive(s.Pid) {
				return nil
			}
		}
	}
	return fmt.Errorf("%s was started but its status in %s did not show it running", c.Program, c.Spool)
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
	if len(args) == 2 && args[0] == "rehearse" {
		return updaterRehearse(args[1])
	}
	fmt.Fprintln(os.Stderr, "dokkit updater install|uninstall|run|status, or rehearse <folder>")
	return 2
}

func rootOnly(p string) error {
	fi, err := os.Stat(p)
	if err != nil {
		return err
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 || fi.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("%s is not owned by root or can be changed by others. Nothing was changed", p)
	}
	return nil
}

// installChecks refuses, before anything is changed, a folder that is not ours to secure.
func installChecks() error {
	for _, f := range []struct {
		dir     string
		allowed []string
	}{
		{updaterDir, []string{"dokkit", "dokkit.previous", "dokkit.new", "config.json", "config.json.tmp"}},
		{updaterData, []string{"state.json", "updater.log", "work", "spool"}},
	} {
		if !exists(f.dir) {
			continue
		}
		if err := rootOnly(f.dir); err != nil {
			return err
		}
		es, err := os.ReadDir(f.dir)
		if err != nil {
			return err
		}
		for _, e := range es {
			if !slices.Contains(f.allowed, e.Name()) {
				return fmt.Errorf("%s holds %s, which the updater did not put there. It keeps only %v in that folder. Nothing was changed. Move that out, then install again", f.dir, e.Name(), f.allowed)
			}
		}
	}
	return nil
}

func detect() (upConfig, error) {
	ps, err := findWatchers()
	if err != nil {
		return upConfig{}, err
	}
	p, err := chooseProgram(ps, os.Getenv("SUDO_USER"))
	if err != nil {
		return upConfig{}, err
	}
	if real, err := filepath.EvalSymlinks(p.Exe); err == nil {
		p.Exe = real
	}
	name, home, gid := account(p.UID)
	if p.User == "" {
		p.User = name
	}
	cfg := buildConfig(runtime.GOOS, p, home, gid)
	if enrolmentPath(cfg.Config, "") == "" {
		return cfg, fmt.Errorf("%s holds no address and key, so the updater would have nothing to ask the server with. Enrol that program first", cfg.Config)
	}
	return cfg, nil
}

func updaterInstall() int {
	if !ops.admin() {
		return needAdmin("install")
	}
	cfg, err := detect()
	if err == nil {
		err = installChecks()
	}
	var how string
	if err == nil {
		how, err = installUpdater(cfg)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Printf("The updater is installed.\n  It looks after %s, run by %s (%s %s), reading %s.\n  Its program: %s. Its state and log: %s.\n  Its timer: %s.\nRunning one check:\n",
		cfg.Program, cfg.User, cfg.Method, cfg.Unit, cfg.Config, where.updaterExe, updaterData, how)
	code := updaterRun()
	updaterStatus()
	return code
}

func installUpdater(cfg upConfig) (string, error) {
	if err := os.MkdirAll(updaterDir, 0o755); err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Join(updaterData, "work"), 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(updaterData, 0o700); err != nil {
		return "", err
	}
	f, err := openLog(filepath.Join(updaterData, "updater.log"))
	if err != nil {
		return "", err
	}
	f.Close()
	from, err := os.Executable()
	if err != nil {
		return "", err
	}
	exe := filepath.Join(updaterDir, "dokkit")
	if !sameFile(from, exe) {
		if err := swapSelf(from, exe); err != nil {
			return "", err
		}
	}
	if err := writeFile(upConfigPath, cfg.encode()); err != nil {
		return "", err
	}
	if err := os.Chmod(upConfigPath, 0o644); err != nil {
		return "", err
	}
	where = realLayout()
	return installTimer(exe)
}

func updaterUninstall() int {
	if !ops.admin() {
		return needAdmin("uninstall")
	}
	gone, err := removeTimer()
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	exe := filepath.Join(updaterDir, "dokkit")
	for _, p := range []string{exe, exe + ".previous", upConfigPath} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "dokkit: could not remove %s: %v\n", p, err)
			return 1
		}
	}
	os.Remove(updaterDir)
	fmt.Printf("Done: %s, and the updater's files, are removed. Its state and log are still in %s\n", gone, updaterData)
	return 0
}

// updaterRehearse does one real check against the server, with the real signature and hash
// checks, but installs into a folder of its own: nothing is restarted and no result is sent.
func updaterRehearse(dir string) int {
	dir, err := filepath.Abs(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	files := filepath.Join(dir, "files")
	where = layout{data: filepath.Join(dir, "data"), updaterExe: filepath.Join(files, "dokkit-updater"), programExe: filepath.Join(files, "dokkit")}
	if err := os.MkdirAll(where.work(), 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	os.MkdirAll(files, 0o700)
	self, _ := os.Executable()
	for _, p := range []string{where.updaterExe, where.programExe} {
		if !exists(p) {
			putFile(self, p)
		}
	}
	ops = realHost()
	ops.admin = func() bool { return true }
	ops.startService = func(string) error { logf("rehearsal: would restart the program"); return nil }
	ops.versionOf = func(string) string { return devVersion }
	loadClient = load
	sendResults = false
	fmt.Println("Rehearsing in", dir, "- nothing outside it is changed and no result is sent.")
	return updaterRun()
}
