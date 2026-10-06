//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

const installedExe = "/usr/local/bin/dokkit"

func serviceCommand(action string) int {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "dokkit: a service needs root. Run this as root, for example with sudo and the full path of this program.")
		return 1
	}
	var err error
	if _, serr := os.Stat(unitPath); serr != nil && action != "install" {
		err = errors.New("the service is not installed")
	} else {
		switch action {
		case "install":
			err = installService()
		case "uninstall":
			err = uninstallService()
		case "update":
			err = updateService()
		default:
			err = runSteps(action)
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

// useEnrolment points the configuration at the person who ran dokkit enrol: root's own, or
// the account that ran sudo, whose home sudo usually hides.
func useEnrolment() error {
	if os.Getenv("DOKKIT_CONFIG") != "" || (os.Getenv("DOKKIT_URL") != "" && os.Getenv("DOKKIT_KEY") != "") {
		return nil
	}
	own, _ := configPath()
	home := ""
	if name := os.Getenv("SUDO_USER"); name != "" && name != "root" {
		if u, err := user.Lookup(name); err == nil {
			home = u.HomeDir
		}
	}
	p := enrolmentPath(own, home)
	if p == "" {
		exe, _ := os.Executable()
		return fmt.Errorf("this machine is not enrolled for root or for the account that ran sudo. Run: %s enrol <address> <token>, then install again", exe)
	}
	return os.Setenv("DOKKIT_CONFIG", p)
}

// installService copies this program and the saved configuration to where only root can change
// them, then runs watch under systemd as the dokkit user, which has no login and no rights.
func installService() error {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return errors.New("systemctl is not here, so this machine does not run systemd. dokkit service needs it")
	}
	if _, err := os.Stat(unitPath); err == nil {
		// A unit file with nothing enabled is what a failed install leaves; it is written again.
		if _, err := runCmd("systemctl", "is-enabled", "--", unitName); err == nil {
			return errors.New("the service is already installed")
		}
	}
	var lists saved
	if p := listsPath(); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &lists)
		}
	}
	if err := useEnrolment(); err != nil {
		return err
	}
	c, err := load()
	if err != nil {
		return err
	}
	if _, err := user.Lookup(unitUser); err != nil {
		if _, err := exec.LookPath("useradd"); err != nil {
			return errors.New("there is no user named " + unitUser + " and useradd is not here. Create a system user with that name, then install again")
		}
		if out, err := runCmd("useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", unitUser); err != nil {
			return fmt.Errorf("could not create the user %s: %s", unitUser, out)
		}
	}
	u, err := user.Lookup(unitUser)
	if err != nil {
		return err
	}
	gid, _ := strconv.Atoi(u.Gid)
	dir := filepath.Dir(configFile)
	if fi, err := os.Stat(dir); err == nil {
		if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 {
			return fmt.Errorf("%s already exists and is not owned by root. Delete it, then install again", dir)
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	os.Chmod(dir, 0o755)
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, Restart: lists.Restart, Hosts: lists.Hosts, SpoolMB: int(c.spoolMB), SystemTasks: c.system, UpdateSha256: c.updateSha})
	if err := writeOwned(configFile, b, gid); err != nil {
		return err
	}
	if err := installBinary(); err != nil {
		return err
	}
	for _, f := range c.folders {
		if why := othersCannotRead(f); why != "" {
			fmt.Fprintf(os.Stderr, "dokkit: the %s user may not be able to read the folder %s (%s). Open it to that user, or the service will find nothing there.\n", unitUser, f, why)
		}
	}
	if err := os.WriteFile(unitPath, []byte(unitFile(installedExe)), 0o644); err != nil {
		return err
	}
	if err := runSteps("install"); err != nil {
		// Leave nothing half done, so the install can be run again.
		runCmd("systemctl", "disable", "--now", unitName)
		os.Remove(unitPath)
		runCmd("systemctl", "daemon-reload")
		return err
	}
	return nil
}

// othersCannotRead says why an account that owns nothing here may not be able to list path, or "".
func othersCannotRead(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err.Error()
	}
	for dir := abs; ; dir = filepath.Dir(dir) {
		fi, err := os.Stat(dir)
		if err != nil {
			return err.Error()
		}
		need := os.FileMode(0o001)
		if dir == abs {
			need = 0o005
		}
		if fi.Mode().Perm()&need != need {
			return dir + " is closed to other accounts"
		}
		if dir == filepath.Dir(dir) {
			return ""
		}
	}
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
	if err := runSteps("uninstall"); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: warning:", err)
	}
	if err := os.Remove(unitPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// The address and key go; the restart and hosts lists stay for the next install.
	if _, err := os.Stat(configFile); err == nil {
		var l saved
		if p := listsPath(); p != "" {
			if b, err := os.ReadFile(p); err == nil {
				json.Unmarshal(b, &l)
			}
		}
		b, _ := json.Marshal(saved{Restart: l.Restart, Hosts: l.Hosts})
		gid := 0
		if u, err := user.Lookup(unitUser); err == nil {
			gid, _ = strconv.Atoi(u.Gid)
		}
		if err := writeOwned(configFile, b, gid); err != nil {
			return err
		}
	}
	if err := systemctl("daemon-reload"); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: warning:", err)
	}
	return nil
}

// updateService puts this copy in the installed one's place, unless it already is that copy
// (get.sh run as root), and restarts the service. It is run by a person.
func updateService() error {
	if err := installBinary(); err != nil {
		return err
	}
	return runSteps("update")
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
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := installedExe + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil { // a restrictive umask must not lock the dokkit user out
		return err
	}
	return os.Rename(tmp, installedExe)
}

func sameFile(a, b string) bool {
	x, err1 := os.Stat(a)
	y, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(x, y)
}

func finishUpdate(path string) string {
	return "To finish, on that machine, as root: " + path + " service update"
}
