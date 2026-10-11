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
	if _, serr := os.Stat(unitPath); serr != nil && action != "install" && !(action == "uninstall" && leftoverConfig()) {
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

// leftoverConfig is true when a failed install left an address or key in the service's configuration.
func leftoverConfig() bool {
	var s saved
	b, err := os.ReadFile(configFile)
	return err == nil && json.Unmarshal(b, &s) == nil && (s.URL != "" || s.Key != "")
}

// useEnrolment points the configuration at the enrolment of the account that ran sudo, or at
// root's own when that account has none. It returns the file used and whose it is.
func useEnrolment() (string, string, error) {
	if os.Getenv("DOKKIT_CONFIG") != "" || (os.Getenv("DOKKIT_URL") != "" && os.Getenv("DOKKIT_KEY") != "") {
		return "", "", nil
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
		return "", "", fmt.Errorf("this machine is not enrolled for the account that ran sudo or for root. Run: %s enrol <address> <token>, then install again", exe)
	}
	who := "the account that ran sudo"
	if p == own {
		who = "root"
	}
	return p, who, os.Setenv("DOKKIT_CONFIG", p)
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
	from, who, err := useEnrolment()
	if err != nil {
		return err
	}
	c, err := load()
	if err != nil {
		return err
	}
	if from != "" {
		fmt.Println("Using the enrolment of " + who + ", in " + from + ", for " + c.url + ".")
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
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, Restart: lists.Restart, Hosts: lists.Hosts, SpoolMB: int(c.spoolMB), UpdateSha256: c.updateSha})
	installed := false
	// A failed install must not leave the address and key on disk.
	defer func() {
		if !installed {
			scrubConfig(lists)
		}
	}()
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
	installed = true
	if len(c.folders) == 0 {
		fmt.Println("The service reads no folders yet. To add one, run: " + elevated("folder", "add", "<path>"))
	}
	return nil
}

// scrubConfig rewrites the service's configuration with the restart and hosts lists only.
func scrubConfig(l saved) error {
	b, _ := json.Marshal(saved{Restart: l.Restart, Hosts: l.Hosts})
	gid := 0
	if u, err := user.Lookup(unitUser); err == nil {
		gid, _ = strconv.Atoi(u.Gid)
	}
	return writeOwned(configFile, b, gid)
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
		if err := scrubConfig(l); err != nil {
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

func finishUpdate(path string) string {
	return "To finish: that file is your own copy, and only you should run it. An administrator updates the service by running get.sh as root, then: dokkit service update"
}

// installedServiceConfig is the installed service's configuration file, or "" when none is installed.
func installedServiceConfig() string {
	if _, err := os.Stat(unitPath); err == nil {
		return configFile
	}
	return ""
}

// ownedByService makes a file one only root can change and the dokkit group can read.
func ownedByService(path string) error {
	gid := 0
	if u, err := user.Lookup(unitUser); err == nil {
		gid, _ = strconv.Atoi(u.Gid)
	}
	if err := os.Chown(path, 0, gid); err != nil {
		return err
	}
	return os.Chmod(path, 0o640)
}
