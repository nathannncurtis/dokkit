package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// updaterRehearse does one real check against the server, with the real signature and hash
// checks, but installs into a folder of its own: no service is touched, no installer is run,
// and no result is sent. It needs no administrator.
func updaterRehearse(dir string, server bool) int {
	dir, err := filepath.Abs(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	files := filepath.Join(dir, "files")
	where = layout{
		data:       filepath.Join(dir, "data"),
		updaterExe: filepath.Join(files, "dokkit-updater.exe"),
		programExe: filepath.Join(files, "dokkit.exe"),
		serverBin:  filepath.Join(files, "server", "bin", "dokkit.bat"),
		serverEnv:  filepath.Join(files, "server", "settings.env"),
	}
	if err := os.MkdirAll(where.work(), 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	os.MkdirAll(files, 0o700)
	// Stand-ins for what is installed, so there is something to replace.
	self, _ := os.Executable()
	for _, p := range []string{where.updaterExe, where.programExe} {
		if !exists(p) {
			copyPlain(self, p)
		}
	}
	if server {
		os.MkdirAll(filepath.Dir(where.serverBin), 0o700)
		os.WriteFile(where.serverBin, nil, 0o600)
	}
	said := func(what string) func(string) error {
		return func(name string) error { logf("rehearsal: would %s the service %s", what, name); return nil }
	}
	ops = hostOps{
		admin:        func() bool { return true },
		lock:         lockFile,
		stopService:  said("stop"),
		startService: said("start"),
		installer: func(_ context.Context, script string) (string, error) {
			if !exists(script) {
				return "", fmt.Errorf("%s is not in the release", script)
			}
			logf("rehearsal: would run %s", script)
			return "", nil
		},
		portUp:    func(string) bool { return true },
		versionOf: func(string) string { return devVersion },
	}
	sendResults = false
	fmt.Println("Rehearsing in", dir, "- nothing outside it is changed and no result is sent.")
	code := updaterRun()
	if b, err := os.ReadFile(filepath.Join(where.data, "updater.log")); err == nil {
		fmt.Print(string(b))
	}
	return code
}
