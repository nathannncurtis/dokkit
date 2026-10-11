//go:build darwin

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const installedExe = "/usr/local/bin/dokkit"

func init() {
	runningAsService = func() bool {
		x := os.Getenv("XPC_SERVICE_NAME")
		return os.Getenv("DOKKIT_CONFIG") == macConfigFile && x != "" && x != "0"
	}
}

func launchctl(args ...string) error {
	if out, err := runCmd("launchctl", args...); err != nil {
		if said := strings.TrimSpace(string(out)); said != "" {
			return fmt.Errorf("launchctl %s: %v: %s", args[0], err, said)
		}
		return fmt.Errorf("launchctl %s: %v", args[0], err)
	}
	return nil
}

func loaded() bool { return launchctl("print", "system/"+macLabel) == nil }

func serviceCommand(action string) int {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "dokkit: a service needs root. Run this as root, for example with sudo and the full path of this program.")
		return 1
	}
	var err error
	if !exists(macPlist) && action != "install" && !(action == "uninstall" && leftoverConfig()) {
		err = errors.New("the service is not installed")
	} else {
		switch action {
		case "install":
			err = installService()
		case "uninstall":
			err = uninstallService()
		case "start":
			err = launchStart(false)
		case "stop":
			err = launchctl("bootout", "system/"+macLabel)
		case "update":
			if err = installBinary(); err == nil {
				err = launchStart(true)
			}
		}
	}
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

// launchStart starts the daemon, loading it first when it is not loaded. restart also stops a running one.
func launchStart(restart bool) error {
	if !loaded() {
		if err := launchctl("bootstrap", "system", macPlist); err != nil {
			return err
		}
		return launchctl("enable", "system/"+macLabel)
	}
	if restart {
		return launchctl("kickstart", "-k", "system/"+macLabel)
	}
	return launchctl("kickstart", "system/"+macLabel)
}

func leftoverConfig() bool {
	var s saved
	b, err := os.ReadFile(macConfigFile)
	return err == nil && json.Unmarshal(b, &s) == nil && (s.URL != "" || s.Key != "")
}

// useEnrolment points the configuration at the enrolment of the account that ran sudo, or at
// root's own when that account has none. It returns the file used, the home of its account
// ("" when the enrolment came from the environment) and that account's number.
func useEnrolment() (file, home string, uid int, err error) {
	if os.Getenv("DOKKIT_CONFIG") != "" || (os.Getenv("DOKKIT_URL") != "" && os.Getenv("DOKKIT_KEY") != "") {
		return "", "", 0, nil
	}
	own, _ := configPath()
	ownHome, _ := os.UserHomeDir()
	home, uid = ownHome, os.Getuid()
	sudoHome := ""
	if name := os.Getenv("SUDO_USER"); name != "" && name != "root" {
		if u, e := user.Lookup(name); e == nil {
			sudoHome = u.HomeDir
		}
	}
	paths := macEnrolments(own, sudoHome)
	if file = firstEnrolment(paths); file == "" {
		exe, _ := os.Executable()
		return "", "", 0, fmt.Errorf("this machine is not enrolled for the account that ran sudo or for root. Run: %s enrol <address> <token>, then install again", exe)
	}
	if file != own {
		home = sudoHome
		u, _ := user.Lookup(os.Getenv("SUDO_USER"))
		uid, _ = strconv.Atoi(u.Uid)
	}
	return file, home, uid, os.Setenv("DOKKIT_CONFIG", file)
}

func installService() error {
	if exists(macPlist) && loaded() {
		return errors.New("the service is already installed")
	}
	var lists saved
	if p := listsPath(); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &lists)
		}
	}
	file, home, uid, err := useEnrolment()
	if err != nil {
		return err
	}
	if file != "" {
		var s saved
		if b, err := os.ReadFile(file); err == nil && json.Unmarshal(b, &s) == nil && s.IMessage {
			return errors.New("this Mac sends iMessages, and only a program running in a signed-in user's session can drive Messages. A service cannot, so this Mac stays on its per-user LaunchAgent. Run dokkit imessage off first to move it to the service, which then sends no iMessages")
		}
	}
	c, err := load()
	if err != nil {
		return err
	}
	if file != "" {
		fmt.Println("Using the enrolment in " + file + " for " + c.url + ".")
	}
	if err := makeAccount(); err != nil {
		return err
	}
	u, err := user.Lookup(macUser)
	if err != nil {
		return err
	}
	svcUID, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	if fi, err := os.Stat(macConfigDir); err == nil {
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 {
			return fmt.Errorf("%s already exists and is not owned by root. Delete it, then install again", macConfigDir)
		}
	}
	if err := os.MkdirAll(macConfigDir, 0o755); err != nil {
		return err
	}
	os.Chmod(macConfigDir, 0o755)
	if err := os.MkdirAll(macStateDir, 0o700); err != nil {
		return err
	}
	if err := os.Chown(macStateDir, svcUID, gid); err != nil {
		return err
	}
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, Restart: lists.Restart, Hosts: lists.Hosts, SpoolMB: int(c.spoolMB), UpdateSha256: c.updateSha})
	installed := false
	defer func() {
		if !installed {
			scrubConfig(lists)
		}
	}()
	if err := writeOwned(macConfigFile, b, gid); err != nil {
		return err
	}
	if err := installBinary(); err != nil {
		return err
	}
	for _, f := range c.folders {
		if why := othersCannotRead(f); why != "" {
			fmt.Fprintf(os.Stderr, "dokkit: the %s user may not be able to read the folder %s (%s). Open it to that user, or the service will find nothing there.\n", macUser, f, why)
		}
	}
	if err := os.WriteFile(macPlist, []byte(daemonPlistFor(installedExe)), 0o644); err != nil {
		return err
	}
	if err := os.Chown(macPlist, 0, 0); err != nil {
		return err
	}
	old := stopOldCopies(home, uid)
	copySpool(filepath.Join(home, "Library", "Caches", "dokkit", "spool"), svcUID, gid)
	launchctl("bootout", "system/"+macLabel)
	if err := launchStart(false); err != nil {
		launchctl("bootout", "system/"+macLabel)
		os.Remove(macPlist)
		for _, a := range old {
			launchctl("enable", fmt.Sprintf("gui/%d/%s", uid, a.label))
			launchctl("bootstrap", fmt.Sprintf("gui/%d", uid), a.file)
		}
		return err
	}
	installed = true
	for _, a := range old {
		fmt.Printf("The LaunchAgent %s (%s) is turned off and its files are left in place. To use it again: sudo launchctl enable gui/%d/%s && launchctl bootstrap gui/%d %s\n", a.label, a.file, uid, a.label, uid, quoteArg(a.file))
	}
	if len(c.folders) == 0 {
		fmt.Println("The service reads no folders yet. To add one, run: " + elevated("folder", "add", "<path>"))
	}
	fmt.Println("The first connection to a server on this network is made with nobody signed in. Check it with: dokkit doctor")
	return nil
}

type oldAgent struct{ label, file string }

// stopOldCopies unloads and disables the person's own LaunchAgents that run dokkit watch, and
// ends a plain background copy their spool names, so two copies never run. Files are left in place.
func stopOldCopies(home string, uid int) (stopped []oldAgent) {
	if home == "" {
		return nil
	}
	files, _ := filepath.Glob(filepath.Join(home, "Library", "LaunchAgents", "*.plist"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		if label, ok := isWatchAgent(string(b)); ok {
			if uid != 0 {
				launchctl("bootout", fmt.Sprintf("gui/%d/%s", uid, label))
				launchctl("disable", fmt.Sprintf("gui/%d/%s", uid, label))
			}
			stopped = append(stopped, oldAgent{label, f})
		}
	}
	var s status
	if b, err := os.ReadFile(filepath.Join(home, "Library", "Caches", "dokkit", "spool", "status.json")); err == nil && json.Unmarshal(b, &s) == nil && s.Pid > 1 && pidAlive(s.Pid) {
		if out, err := runCmd("ps", "-p", strconv.Itoa(s.Pid), "-o", "command="); err == nil {
			if _, ok := watchCommand(strings.TrimSpace(string(out))); ok {
				syscall.Kill(s.Pid, syscall.SIGTERM)
				for end := time.Now().Add(10 * time.Second); pidAlive(s.Pid) && time.Now().Before(end); time.Sleep(200 * time.Millisecond) {
				}
			}
		}
	}
	return stopped
}

// copySpool copies the waiting reports and log positions of the person's spool into the service's, leaving the originals.
func copySpool(from string, uid, gid int) {
	for _, pat := range spoolFiles {
		names, _ := filepath.Glob(filepath.Join(from, pat))
		for _, n := range names {
			to := filepath.Join(macStateDir, filepath.Base(n))
			if exists(to) {
				continue
			}
			if err := copyFile(n, to, 0o600); err != nil {
				fmt.Fprintln(os.Stderr, "dokkit: could not copy", n, "to the service:", err)
				continue
			}
			os.Chown(to, uid, gid)
		}
	}
}

func copyFile(from, to string, mode os.FileMode) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func makeAccount() error {
	if _, err := user.Lookup(macUser); err == nil {
		return nil
	}
	users, _ := runCmd("dscl", ".", "-list", "/Users", "UniqueID")
	groups, _ := runCmd("dscl", ".", "-list", "/Groups", "PrimaryGroupID")
	for _, args := range accountSteps(macUser, nextFreeID(string(users), string(groups))) {
		if out, err := runCmd("dscl", args...); err != nil {
			return fmt.Errorf("could not create the user %s: %v %s", macUser, err, out)
		}
	}
	return nil
}

func scrubConfig(l saved) error {
	b, _ := json.Marshal(saved{Restart: l.Restart, Hosts: l.Hosts})
	gid := 0
	if u, err := user.Lookup(macUser); err == nil {
		gid, _ = strconv.Atoi(u.Gid)
	}
	return writeOwned(macConfigFile, b, gid)
}

// writeOwned writes a file only root can change and the dokkit group can read.
func writeOwned(path string, b []byte, gid int) error {
	if err := os.WriteFile(path, b, 0o600); err != nil {
		return err
	}
	if err := os.Chown(path, 0, gid); err != nil {
		return err
	}
	return os.Chmod(path, 0o640)
}

// uninstallService goes on past a step that fails, so a half install can always be removed.
func uninstallService() error {
	if loaded() {
		if err := launchctl("bootout", "system/"+macLabel); err != nil {
			fmt.Fprintln(os.Stderr, "dokkit: warning:", err)
		}
	}
	if err := os.Remove(macPlist); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if exists(macConfigFile) {
		var l saved
		if p := listsPath(); p != "" {
			if b, err := os.ReadFile(p); err == nil {
				json.Unmarshal(b, &l)
			}
		}
		return scrubConfig(l)
	}
	return nil
}

// installBinary copies this program to where only root can replace it. The new copy is
// renamed into place, so a running copy is not written to.
func installBinary() error {
	from, err := os.Executable()
	if err != nil {
		return err
	}
	if sameFile(from, installedExe) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(installedExe), 0o755); err != nil {
		return err
	}
	tmp := installedExe + ".new"
	if err := copyFile(from, tmp, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, installedExe)
}

func finishUpdate(path string) string {
	return "To finish: that file is your own copy, and only you should run it. An administrator updates the service by running get.sh as root, then: dokkit service update"
}

func installedServiceConfig() string {
	if exists(macPlist) {
		return macConfigFile
	}
	return ""
}

func ownedByService(path string) error {
	gid := 0
	if u, err := user.Lookup(macUser); err == nil {
		gid, _ = strconv.Atoi(u.Gid)
	}
	if err := os.Chown(path, 0, gid); err != nil {
		return err
	}
	return os.Chmod(path, 0o640)
}
