package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// The updater's folders. Tests point them at a scratch folder.
type layout struct{ data, updaterExe, programExe, serverBin, serverEnv string }

// What touches Windows itself. Tests replace it.
type hostOps struct {
	admin                     func() bool
	lock                      func(path string) (release func(), err error)
	stopService, startService func(name string) error // stop waits for Stopped; start waits for Running
	installer                 func(ctx context.Context, script string) (string, error)
	portUp                    func(port string) bool
	versionOf                 func(exe string) string
	schedule                  func() // makes the updater's own task, units or plist the current ones; nil in a rehearsal
	tasks                     func() // leaves the list of scheduled tasks for the program to read; Windows only
}

var (
	where = realLayout()
	ops   = realHost()

	loadClient     = load
	runLimit       = 45 * time.Minute
	retryFor       = time.Minute
	minGap         = 30 * time.Second
	programService = "dokkit"
	devVersion     = "v0.0.0-dev"
	serverZip      = "dokkit-windows-x64.zip"
	notInstalledAt = "The updater is not installed. To install it, " // plus elevated(...)
)

type outcome struct {
	Version string `json:"version"`
	OK      bool   `json:"ok"`
	Note    string `json:"note"`
}

type state struct {
	Server  string   `json:"server,omitempty"` // the installed server's version
	Checked string   `json:"checked,omitempty"`
	Ran     string   `json:"ran,omitempty"` // when the last run ended
	LastAt  string   `json:"last_at,omitempty"`
	Last    *outcome `json:"last,omitempty"`
	Unsent  *outcome `json:"unsent,omitempty"` // a result the server has not taken yet
}

func (l layout) statePath() string { return filepath.Join(l.data, "state.json") }
func (l layout) work() string      { return filepath.Join(l.data, "work") }

func readState() (st state, err error) {
	b, err := os.ReadFile(where.statePath())
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil
	}
	if err == nil {
		err = json.Unmarshal(b, &st)
	}
	return st, err
}

func saveState(st state) {
	b, _ := json.Marshal(st)
	if err := writeFile(where.statePath(), b); err != nil {
		logf("could not write state.json: %v", err)
	}
}

func logf(format string, a ...any) {
	line := time.Now().Format(time.RFC3339) + " " + fmt.Sprintf(format, a...)
	fmt.Println(line)
	if f, err := openLog(filepath.Join(where.data, "updater.log")); err == nil {
		fmt.Fprintln(f, line)
		f.Close()
	}
}

// tail keeps the last n bytes of s.
func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		s = strings.ToValidUTF8(s[len(s)-n:], "")
	}
	return s
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func updaterRun() int {
	if !ops.admin() {
		fmt.Fprintln(os.Stderr, "dokkit: updater run needs an administrator prompt (root on Linux and macOS): it is the system account's job, and the updater's folder is closed to everyone else.")
		return 1
	}
	if !exists(where.data) {
		fmt.Fprintln(os.Stderr, "dokkit: "+notInstalledAt+elevated("updater", "install"))
		return 1
	}
	os.MkdirAll(where.work(), 0o700)
	release, err := ops.lock(filepath.Join(where.work(), "run.lock"))
	if err != nil {
		logf("another check is already running; this one does nothing")
		return 0
	}
	defer release()
	if st, err := readState(); err == nil {
		// a nudge can land seconds after a timed check; it waits out the gap instead of being dropped
		if at, err := time.Parse(time.RFC3339Nano, st.Ran); err == nil && time.Since(at) < minGap {
			time.Sleep(minGap - time.Since(at))
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), runLimit)
	defer cancel()
	c, err := loadClient()
	if err != nil {
		logf("cannot read the program's configuration: %v", err)
		return 1
	}
	code := updateOnce(ctx, c)
	if st, err := readState(); err == nil {
		st.Ran = now()
		saveState(st)
	}
	if ops.schedule != nil {
		ops.schedule()
	}
	if ops.tasks != nil {
		ops.tasks()
	}
	return code
}

func (st state) serverVersion() string {
	if st.Server == "" {
		return devVersion
	}
	return st.Server
}

func newer(a, b string) bool { c, _ := compareVersions(a, b); return c > 0 }

// statusExtra prints what a system adds to updater status.
var statusExtra = func() {}

func needAdmin(what string) int {
	fmt.Fprintf(os.Stderr, "dokkit: updater %s needs an administrator prompt. Nothing was changed. Run it %s\n", what, elevated("updater", what))
	return 1
}

// sendResults is false in a rehearsal.
var sendResults = true

func postResult(c *client, r outcome) bool {
	if !sendResults {
		return true
	}
	b, _ := json.Marshal(r)
	code, err := c.call("POST", "/api/v1/update/result", "application/json", b, nil)
	return err == nil && code >= 200 && code < 300
}

func updateOnce(ctx context.Context, c *client) int {
	st, err := readState()
	if err != nil {
		logf("state.json cannot be read, starting it again: %v", err)
		st = state{}
	}
	if st.Unsent != nil {
		if postResult(c, *st.Unsent) {
			logf("sent the earlier result for %s", st.Unsent.Version)
			st.Unsent = nil
			saveState(st)
		} else {
			logf("could not send the earlier result for %s; it stays for the next run", st.Unsent.Version)
		}
	}
	q := url.Values{"program": {ops.versionOf(where.programExe)}, "updater": {version}, "os": {runtime.GOOS}, "arch": {runtime.GOARCH}}
	if exists(where.serverBin) {
		q.Set("server", st.serverVersion())
	}
	var ans struct{ Version string }
	code, err := c.call("GET", "/api/v1/update?"+q.Encode(), "", nil, &ans)
	st.Checked = now()
	switch {
	case err != nil:
		saveState(st)
		logf("could not ask the server: %v", err)
		return 1
	case code == 204:
		saveState(st)
		logf("nothing wanted")
		return 0
	case code != 200:
		saveState(st)
		logf("the server answered %d", code)
		return 1
	}
	logf("asked to move to %s", ans.Version)
	res := apply(ctx, c, ans.Version, &st)
	st.Last, st.LastAt, st.Unsent = &res, now(), &res
	saveState(st)
	logf("%s: ok=%v %s", res.Version, res.OK, res.Note)
	if postResult(c, res) {
		st.Unsent = nil
		saveState(st)
	} else {
		logf("could not send the result; it will be sent on the next run")
	}
	if res.OK {
		return 0
	}
	return 1
}

// apply installs what the signed list for want allows, server then program then updater,
// and stops at the first failure. What already went in stays.
func apply(ctx context.Context, c *client, want string, st *state) outcome {
	fail := func(format string, a ...any) outcome {
		return outcome{want, false, tail(fmt.Sprintf(format, a...), 2000)}
	}
	if _, ok := parseVersion(want); !ok {
		return fail("the server named %q, which is not a version", want)
	}
	if err := os.MkdirAll(where.work(), 0o700); err != nil {
		return fail("%v", err)
	}
	clearWork()
	sums, err := fetchBytes(ctx, c, want, "SHA256SUMS")
	if err != nil {
		return fail("%v", err)
	}
	sig, err := fetchBytes(ctx, c, want, "SHA256SUMS.sig")
	if err != nil {
		return fail("%v", err)
	}
	hashes, err := verifyRelease(sums, sig, want)
	if err != nil {
		return fail("%s was not installed: %v", want, err)
	}

	programFile := fmt.Sprintf("dokkit-%s-%s", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "windows" {
		programFile += ".exe"
	}
	hosts := exists(where.serverBin)
	var todo, left []string
	older := false
	for _, p := range []struct {
		name, have string
		on         bool
	}{{"server", st.serverVersion(), hosts}, {"program", ops.versionOf(where.programExe), true}, {"updater", version, true}} {
		if !p.on {
			continue
		}
		switch cmp, _ := compareVersions(want, p.have); {
		case cmp > 0:
			todo = append(todo, p.name)
		case cmp == 0:
			left = append(left, p.name+" is already on "+p.have)
		default:
			older = true
			left = append(left, p.name+" is on "+p.have+", newer than "+want+", and was left alone")
		}
	}
	rest := strings.Join(left, "; ")
	if len(todo) == 0 {
		if older {
			return fail("nothing was installed: %s", rest)
		}
		return outcome{want, true, "nothing to install: " + rest}
	}

	// Everything is fetched and checked before anything is changed.
	files := map[string]string{}
	need := func(name string) error {
		if files[name] != "" {
			return nil
		}
		p, err := download(ctx, c, want, name, hashes[name])
		files[name] = p
		return err
	}
	for _, p := range todo {
		name := programFile
		if p == "server" {
			name = serverZip
		}
		if err := need(name); err != nil {
			return fail("%v", err)
		}
	}

	var done []string
	for _, p := range todo {
		var err error
		switch p {
		case "server":
			if err = installServer(ctx, files[serverZip], want); err == nil {
				st.Server = want
				saveState(*st)
			}
		case "program":
			err = installProgram(files[programFile])
		case "updater":
			err = swapSelf(files[programFile], where.updaterExe)
		}
		if err != nil {
			if len(done) > 0 {
				return fail("%s: %v. Already installed: %s", p, err, strings.Join(done, ", "))
			}
			return fail("%s: %v", p, err)
		}
		done = append(done, p)
	}
	note := strings.Join(done, ", ")
	if rest != "" {
		note += "; " + rest
	}
	return outcome{want, true, note}
}

func clearWork() {
	es, _ := os.ReadDir(where.work())
	for _, e := range es {
		if e.Name() != "run.lock" {
			os.RemoveAll(filepath.Join(where.work(), e.Name()))
		}
	}
}

func (c *client) fetch(ctx context.Context, version, name string, to io.Writer) error {
	req, err := http.NewRequestWithContext(ctx, "GET", c.url+"/api/v1/releases/"+url.PathEscape(version)+"/"+url.PathEscape(name), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	res, err := (&http.Client{Transport: toServer}).Do(req)
	if err != nil {
		return fmt.Errorf("could not fetch %s: %w", name, err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("could not fetch %s: the server answered %d", name, res.StatusCode)
	}
	_, err = io.Copy(to, io.LimitReader(res.Body, 300<<20))
	return err
}

func fetchBytes(ctx context.Context, c *client, version, name string) ([]byte, error) {
	var b strings.Builder
	err := c.fetch(ctx, version, name, &b)
	return []byte(b.String()), err
}

// download fetches a file into work and keeps it only if its hash is the signed one.
func download(ctx context.Context, c *client, version, name, hash string) (string, error) {
	if hash == "" {
		return "", fmt.Errorf("%s is not in the signed list", name)
	}
	p := filepath.Join(where.work(), name)
	f, err := os.Create(p)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	err = c.fetch(ctx, version, name, io.MultiWriter(f, h))
	f.Close()
	if err != nil {
		return "", err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != hash {
		os.Remove(p)
		return "", fmt.Errorf("%s does not match the signed list (got %s, expected %s)", name, got, hash)
	}
	return p, nil
}

func serverPort() string {
	b, _ := os.ReadFile(where.serverEnv)
	for _, l := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), "="); ok && k == "PORT" && strings.Trim(strings.TrimSpace(v), `"'`) != "" {
			return strings.Trim(strings.TrimSpace(v), `"'`)
		}
	}
	return "443"
}

func installServer(ctx context.Context, zipFile, want string) error {
	dir := filepath.Join(where.work(), "server-"+want)
	if err := unzip(zipFile, dir); err != nil {
		return err
	}
	out, err := ops.installer(ctx, filepath.Join(dir, "install.ps1"))
	if err != nil {
		return fmt.Errorf("the server's installer failed (%v). The end of its output: %s", err, tail(out, 1500))
	}
	if !ops.portUp(serverPort()) {
		return fmt.Errorf("the server's installer finished but the server does not answer on port %s. The end of its output: %s", serverPort(), tail(out, 1500))
	}
	return nil
}

// safeJoin is where a zip entry goes, or an error when it would land outside dest.
func safeJoin(dest, name string) (string, error) {
	p := filepath.Join(dest, name)
	if p != filepath.Clean(dest) && !strings.HasPrefix(p, filepath.Clean(dest)+string(filepath.Separator)) {
		return "", fmt.Errorf("the zip has an entry, %q, that would land outside its folder", name)
	}
	return p, nil
}

func unzip(zipFile, dest string) error {
	r, err := zip.OpenReader(zipFile)
	if err != nil {
		return err
	}
	defer r.Close()
	for _, f := range r.File {
		if _, err := safeJoin(dest, f.Name); err != nil {
			return err
		}
		if f.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("the zip has a link, %q", f.Name)
		}
	}
	os.RemoveAll(dest)
	for _, f := range r.File {
		p, _ := safeJoin(dest, f.Name)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(p, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			return err
		}
		in, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(p)
		if err == nil {
			_, err = io.Copy(out, in)
			out.Close()
		}
		in.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func copyPlain(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// putFile writes the file beside its place, then renames it in, retrying while the place is in use.
func putFile(from, to string) error {
	tmp := to + ".new"
	os.Remove(tmp)
	if err := copyPlain(from, tmp); err != nil {
		return err
	}
	if err := keepOwner(tmp, to); err != nil {
		os.Remove(tmp)
		return err
	}
	deadline := time.Now().Add(retryFor)
	for {
		err := os.Rename(tmp, to)
		if err == nil {
			syncDir(filepath.Dir(to))
		}
		if err == nil || time.Now().After(deadline) {
			return err
		}
		time.Sleep(time.Second)
	}
}

func installProgram(newFile string) error {
	to := where.programExe
	prev := to + ".previous"
	if fi, err := os.Lstat(to); err == nil && !fi.Mode().IsRegular() {
		return fmt.Errorf("%s is not a plain file, so nothing was replaced", to)
	}
	if err := ops.stopService(programService); err != nil {
		ops.startService(programService)
		return fmt.Errorf("could not stop the service: %w", err)
	}
	os.Remove(prev)
	if err := copyPlain(to, prev); err != nil {
		ops.startService(programService)
		return fmt.Errorf("could not keep the old file as %s: %w", prev, err)
	}
	keepOwner(prev, to)
	if err := putFile(newFile, to); err != nil {
		putFile(prev, to)
		ops.startService(programService)
		return fmt.Errorf("could not put the new file in place: %w", err)
	}
	err := ops.startService(programService)
	if err == nil {
		return nil
	}
	ops.stopService(programService)
	if rerr := putFile(prev, to); rerr != nil {
		return fmt.Errorf("the new program did not start (%v) and the previous file could not be put back: %v", err, rerr)
	}
	if serr := ops.startService(programService); serr != nil {
		return fmt.Errorf("the new program did not start (%v); the previous file was put back but did not start either: %v", err, serr)
	}
	return fmt.Errorf("the new program did not start (%v); the previous file was put back and is running", err)
}

// swapSelf replaces a file that may be running: a running file can be renamed but not written.
func swapSelf(newFile, to string) error {
	prev := to + ".previous"
	had := exists(to)
	if had {
		os.Remove(prev)
		if err := os.Rename(to, prev); err != nil {
			return err
		}
	}
	if err := putFile(newFile, to); err != nil {
		if had {
			os.Rename(prev, to)
		}
		return err
	}
	return nil
}

// updaterStatus prints what is installed, the last check and the last result.
func updaterStatus() int {
	if !exists(where.updaterExe) {
		fmt.Println(notInstalledAt + elevated("updater", "install"))
		return 0
	}
	fmt.Println("Program:", ops.versionOf(where.programExe))
	fmt.Println("Updater:", ops.versionOf(where.updaterExe))
	statusExtra()
	st, err := readState()
	if errors.Is(err, fs.ErrPermission) {
		fmt.Println("The rest is kept where only administrators can read it. To see it, " + elevated("updater", "status"))
		return 0
	}
	if exists(where.serverBin) {
		fmt.Println("Server:", st.serverVersion())
	} else {
		fmt.Println("Server: not on this machine")
	}
	if err != nil {
		fmt.Println("The updater's state could not be read:", err)
		return 1
	}
	if st.Checked == "" {
		fmt.Println("Last check: none yet")
	} else {
		fmt.Println("Last check:", st.Checked)
	}
	if st.Last == nil {
		fmt.Println("Last result: none yet")
	} else {
		word := "failed"
		if st.Last.OK {
			word = "ok"
		}
		fmt.Printf("Last result: %s, %s, %s: %s\n", st.Last.Version, word, st.LastAt, st.Last.Note)
	}
	if st.Unsent != nil {
		fmt.Println("That result has not reached the server yet.")
	}
	return 0
}
