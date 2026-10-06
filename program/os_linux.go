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
		fmt.Fprintln(os.Stderr, "dokkit: a service needs root. Run this as root, for example with sudo.")
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
	return 0
}

// installService copies this program and the saved configuration to where only root can change
// them, then runs watch under systemd as the dokkit user, which has no login and no rights.
func installService() error {
	if _, err := os.Stat(unitPath); err == nil {
		return errors.New("the service is already installed")
	}
	var lists saved
	if p := listsPath(); p != "" {
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &lists)
		}
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
	b, _ := json.Marshal(saved{URL: c.url, Key: c.key, Pin: c.pin, Folders: c.folders, Restart: lists.Restart, Hosts: lists.Hosts, SystemTasks: c.system, UpdateSha256: c.updateSha})
	if err := writeOwned(configFile, b, gid); err != nil {
		return err
	}
	if err := installBinary(); err != nil {
		return err
	}
	if err := os.WriteFile(unitPath, []byte(unitFile(installedExe)), 0o644); err != nil {
		return err
	}
	return runSteps("install")
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

func uninstallService() error {
	if err := runSteps("uninstall"); err != nil {
		return err
	}
	if err := os.Remove(unitPath); err != nil {
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
	return systemctl("daemon-reload")
}

// updateService puts this copy in the installed one's place. It is run by a person, from the newer copy.
func updateService() error {
	from, err := os.Executable()
	if err != nil {
		return err
	}
	if sameFile(from, installedExe) {
		return errors.New("run this from the newer copy, not from the installed one")
	}
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
