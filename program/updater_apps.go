package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"
)

var appKinds = []string{"windows-service", "installer", "compose", "systemd", "launchd"}

// appRecipe is a dokkit.toml's [app] table: what the updater runs for that service's releases.
type appRecipe struct {
	Kind, Name, Folder, File, ComposeFile, ComposeService, Tag, Asset string
	Args                                                              []string
	HasArgs                                                           bool
	HealthWait                                                        time.Duration
}

const defaultInstallerArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"

func (d *declaration) readApp() error {
	v, present := d.raw["app"]
	if !present {
		return nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		return errors.New("[app] is a table.")
	}
	text := func(k string) string { s, _ := m[k].(string); return s }
	a := &appRecipe{Kind: text("kind"), Name: text("name"), Folder: text("folder"), File: text("file"),
		ComposeFile: text("compose_file"), ComposeService: text("compose_service"), Tag: text("tag"), Asset: text("asset")}
	if !slices.Contains(appKinds, a.Kind) {
		return errors.New("app.kind is one of " + strings.Join(appKinds, ", ") + ".")
	}
	switch a.Kind {
	case "windows-service", "systemd", "launchd":
		if a.Name == "" {
			return errors.New("app.name names the service, unit or label to restart.")
		}
		if (a.Folder == "") == (a.File == "") {
			return errors.New("app names a folder or a file to replace, one of the two.")
		}
	case "compose":
		if a.ComposeFile == "" || a.ComposeService == "" {
			return errors.New("app.compose_file and app.compose_service name the Compose file and its service.")
		}
	}
	if w, ok := m["health_wait"]; ok {
		s, _ := w.(string)
		if dur, err := time.ParseDuration(s); err != nil || dur < 10*time.Second || dur > time.Hour {
			return errors.New("app.health_wait is a time such as 5m, from 10s to 1h.")
		}
		a.HealthWait, _ = time.ParseDuration(s)
	}
	if v, ok := m["args"]; ok {
		a.HasArgs = true
		switch list := v.(type) {
		case []string:
			a.Args = list
		case []any:
			for _, x := range list {
				s, isText := x.(string)
				if !isText {
					return errors.New("app.args is a list of text.")
				}
				a.Args = append(a.Args, s)
			}
		default:
			return errors.New("app.args is a list of text.")
		}
	}
	if a.Tag == "" {
		a.Tag = "{version}"
	}
	d.App = a
	return nil
}

type appItem struct {
	Service       string `json:"service"`
	Version       string `json:"version"`
	File          string `json:"file"`
	SHA256        string `json:"sha256"`
	Size          int64  `json:"size"`
	Signer        string `json:"signer"`
	HealthSeconds int    `json:"health_seconds"`
	// RequireSignature is nil from a server that does not send it, which keeps the check on.
	RequireSignature *bool `json:"require_signature"`
}

func (it appItem) mustBeSigned() bool {
	return appOS == "windows" && isSigned(it.File) && (it.RequireSignature == nil || *it.RequireSignature)
}

type appResult struct {
	Service string `json:"service"`
	Version string `json:"version"`
	OK      bool   `json:"ok"`
	Note    string `json:"note"`
}

type appLast struct {
	Version string `json:"version"`
	OK      bool   `json:"ok"`
	Note    string `json:"note"`
	At      string `json:"at"`
}

// What touches the system for app updates. Tests replace them.
var (
	appOS        = runtime.GOOS
	healthEvery  = 5 * time.Second
	healthUnit   = time.Second
	appRunLimit  = 30 * time.Minute
	trusted      = trustedRecipe
	authenticode = realAuthenticode
	runApp       = func(ctx context.Context, name string, args ...string) (string, error) {
		out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
		return string(out), err
	}
	appName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]*$`)
)

func appsOnce(ctx context.Context, c *client) int {
	st, err := readState()
	if err != nil {
		st = state{}
	}
	var keep []appResult
	for _, r := range st.UnsentApps {
		if postJSON(c, "/api/v1/update/apps/result", r, r.Service+" "+r.Version) {
			logf("sent the earlier result for %s %s", r.Service, r.Version)
		} else {
			keep = append(keep, r)
		}
	}
	if len(keep) != len(st.UnsentApps) {
		st.UnsentApps = keep
		saveState(st)
	}
	var ans struct{ Items []appItem }
	q := url.Values{"os": {runtime.GOOS}, "arch": {runtime.GOARCH}}
	code, err := c.call("GET", "/api/v1/update/apps?"+q.Encode(), "", nil, &ans)
	switch {
	case err != nil:
		logf("could not ask the server for app releases: %v", err)
		return 1
	case code == 204 || code == 404: // a server that does not know app releases yet
		return 0
	case code != 200:
		logf("the server answered %d to the app releases", code)
		return 1
	}
	failed := 0
	for _, it := range ans.Items {
		logf("asked to move %s to %s", it.Service, it.Version)
		res := installApp(ctx, c, it)
		logf("%s %s: ok=%v %s", res.Service, res.Version, res.OK, res.Note)
		if !res.OK {
			failed = 1
		}
		if st, err = readState(); err != nil {
			st = state{}
		}
		if st.Apps == nil {
			st.Apps = map[string]appLast{}
		}
		st.Apps[it.Service] = appLast{res.Version, res.OK, res.Note, now()}
		st.UnsentApps = append(st.UnsentApps, res)
		saveState(st)
		if postJSON(c, "/api/v1/update/apps/result", res, res.Service+" "+res.Version) {
			st.UnsentApps = st.UnsentApps[:len(st.UnsentApps)-1]
			saveState(st)
		} else {
			logf("could not send the result; it will be sent on the next run")
		}
	}
	return failed
}

func installApp(ctx context.Context, c *client, it appItem) appResult {
	note, err := doApp(ctx, c, it)
	r := appResult{Service: it.Service, Version: it.Version, OK: err == nil, Note: tail(note, 2000)}
	if err != nil {
		r.Note = tail(err.Error(), 2000)
	}
	return r
}

func doApp(ctx context.Context, c *client, it appItem) (string, error) {
	if !appName.MatchString(it.Service) || !appName.MatchString(it.Version) || it.File != "" && filepath.Base(it.File) != it.File {
		return "", fmt.Errorf("the server named %q %q %q, which is not a service, version and file", it.Service, it.Version, it.File)
	}
	d, err := recipeFor(c, it.Service)
	if err != nil {
		return "", err
	}
	a := d.App
	if err := onThisSystem(a.Kind); err != nil {
		return "", err
	}
	if a.Kind == "compose" {
		return composeApp(ctx, d, it)
	}
	if err := os.MkdirAll(where.work(), 0o700); err != nil {
		return "", err
	}
	work := filepath.Join(where.work(), "app-"+it.Service)
	os.RemoveAll(work)
	if err := os.MkdirAll(work, 0o700); err != nil {
		return "", err
	}
	defer os.RemoveAll(work)
	file, err := fetchAppFile(ctx, c, it, work)
	if err != nil {
		return "", err
	}
	if a.Kind == "installer" {
		return runInstaller(ctx, d, it, file)
	}
	return swapFiles(ctx, d, it, file, work)
}

func onThisSystem(kind string) error {
	switch {
	case kind == "windows-service" && appOS != "windows":
		return errors.New("a Windows service installs on Windows only")
	case kind == "installer" && appOS != "windows":
		return errors.New("an installer runs on Windows only")
	case kind == "systemd" && appOS != "linux":
		return errors.New("a systemd unit installs on Linux only")
	case kind == "launchd" && appOS != "darwin":
		return errors.New("a launchd job installs on macOS only")
	}
	return nil
}

// recipeFor is the dokkit.toml on this machine that declares [app] for the service. The server's
// copy of it is never what runs, so only a file and folder that administrators alone can change count.
func recipeFor(c *client, service string) (*declaration, error) {
	var untrusted error
	for _, p := range declarations(c.foldersNow()) {
		d, err := readDeclaration(p)
		if err != nil || d.Service.ID != service || d.App == nil {
			continue
		}
		bad := ""
		for _, x := range []string{p, filepath.Dir(p)} {
			if trusted(x) != nil && bad == "" {
				bad = x
			}
		}
		if bad == "" {
			return d, nil
		}
		untrusted = fmt.Errorf("%s can be changed by accounts other than administrators, so its [app] is not used", bad)
	}
	if untrusted != nil {
		return nil, untrusted
	}
	return nil, fmt.Errorf("no dokkit.toml in this machine's folders declares [app] for %s", service)
}

func fetchAppFile(ctx context.Context, c *client, it appItem, work string) (string, error) {
	switch {
	case it.File == "" || it.SHA256 == "":
		return "", fmt.Errorf("the server named no file or checksum for %s %s", it.Service, it.Version)
	}
	path := "/api/v1/update/apps/" + url.PathEscape(it.Service) + "/" + url.PathEscape(it.Version) + "/" + url.PathEscape(it.File)
	p, err := downloadTo(filepath.Join(work, it.File), it.File, strings.ToLower(it.SHA256), "the checksum the server gave", func(fresh func() io.Writer) error {
		return retrying(ctx, it.File, func() error { return c.fetchPath(ctx, path, it.File, fresh()) })
	})
	if err != nil {
		return "", err
	}
	if it.mustBeSigned() {
		signer, valid, err := authenticode(p)
		switch {
		case err != nil:
			return "", fmt.Errorf("could not read the signature of %s: %v", it.File, err)
		case !valid:
			return "", fmt.Errorf("%s does not have a valid signature", it.File)
		case it.Signer != "" && !strings.EqualFold(signer, it.Signer):
			return "", fmt.Errorf("%s is signed by %q, not by the pinned signer %q", it.File, signer, it.Signer)
		}
	}
	return p, nil
}

func isSigned(name string) bool {
	e := strings.ToLower(filepath.Ext(name))
	return e == ".exe" || e == ".msi"
}

func realAuthenticode(path string) (string, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	script := "$s = Get-AuthenticodeSignature -LiteralPath '" + strings.ReplaceAll(path, "'", "''") + "'; $s.Status; if ($s.SignerCertificate) { $s.SignerCertificate.GetNameInfo('SimpleName', $false) }"
	out, err := runApp(ctx, "powershell.exe", "-NoProfile", "-Command", script)
	if err != nil {
		return "", false, fmt.Errorf("%v: %s", err, tail(out, 500))
	}
	signer, valid := parseSignature(out)
	return signer, valid, nil
}

// parseSignature reads the two lines realAuthenticode prints: the status, then the signer's name.
func parseSignature(out string) (signer string, valid bool) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	valid = strings.TrimSpace(lines[0]) == "Valid"
	if len(lines) > 1 {
		signer = strings.TrimSpace(lines[1])
	}
	return
}

func runChecked(ctx context.Context, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, appRunLimit)
	defer cancel()
	if out, err := runApp(ctx, name, args...); err != nil {
		return fmt.Errorf("%s failed (%v). The end of its output: %s", filepath.Base(name), err, tail(out, 1000))
	}
	return nil
}

func healthWait(a *appRecipe, it appItem) time.Duration {
	switch {
	case a.HealthWait > 0:
		return a.HealthWait
	case it.HealthSeconds > 0:
		return time.Duration(it.HealthSeconds) * healthUnit
	}
	return 5 * time.Minute
}

func runInstaller(ctx context.Context, d *declaration, it appItem, file string) (string, error) {
	a := d.App
	name, args := "msiexec", []string{"/i", file, "/qn", "/norestart"}
	switch strings.ToLower(filepath.Ext(file)) {
	case ".msi":
		args = append(args, a.Args...)
	case ".exe":
		name, args = file, a.Args
		if !a.HasArgs {
			args = strings.Fields(defaultInstallerArgs)
		}
	default:
		return "", fmt.Errorf("%s is not an installer: it is a .exe or a .msi", it.File)
	}
	const kept = "Nothing was put back: an installer keeps no previous copy."
	if err := runChecked(ctx, name, args...); err != nil {
		return "", fmt.Errorf("the installer for %s failed: %v. %s", it.Version, err, kept)
	}
	note, err := waitHealthy(ctx, d, it.Version, healthWait(a, it))
	if err != nil {
		return "", fmt.Errorf("%s was installed but %v. %s", it.Version, err, kept)
	}
	return "installed " + it.Version + "; " + note, nil
}

// control gives the stop and the start for a service kind; stop is nil where there is none.
func control(ctx context.Context, a *appRecipe) (stop, start func() error) {
	switch a.Kind {
	case "windows-service":
		return func() error { return ops.stopService(a.Name) }, func() error { return ops.startService(a.Name) }
	case "systemd":
		return nil, func() error { return runChecked(ctx, "systemctl", "restart", a.Name) }
	}
	return nil, func() error { return runChecked(ctx, "launchctl", "kickstart", "-k", "system/"+a.Name) }
}

func swapFiles(ctx context.Context, d *declaration, it appItem, file, work string) (string, error) {
	a := d.App
	path, isDir := a.File, false
	if a.Folder != "" {
		path, isDir = a.Folder, true
	}
	staged, err := stageFiles(it.File, a, file, filepath.Join(work, "stage"))
	if err != nil {
		return "", err
	}
	stop, start := control(ctx, a)
	if stop != nil {
		if err := stop(); err != nil {
			start()
			return "", fmt.Errorf("could not stop %s: %v. Nothing was changed", a.Name, err)
		}
	}
	had, err := backup(path, isDir)
	if err != nil {
		start()
		return "", fmt.Errorf("could not keep the old files: %v. Nothing was changed", err)
	}
	fail := func(what string, err error) (string, error) {
		if stop != nil {
			stop()
		}
		rest := "the previous files were put back"
		if rerr := restore(path, isDir, had); rerr != nil {
			rest = fmt.Sprintf("the previous files could not be put back: %v", rerr)
		} else if serr := start(); serr != nil {
			rest += fmt.Sprintf(" but %s did not start: %v", a.Name, serr)
		} else {
			rest += " and " + a.Name + " was started"
		}
		return "", fmt.Errorf("%s: %v; %s", what, err, rest)
	}
	if isDir {
		err = putTree(staged, path)
	} else {
		err = putFile(staged, path)
	}
	if err != nil {
		return fail("could not put the new files in place", err)
	}
	if err := start(); err != nil {
		return fail("the new version did not start", err)
	}
	note, err := waitHealthy(ctx, d, it.Version, healthWait(a, it))
	if err != nil {
		return fail(it.Version+" was started", err)
	}
	return "installed " + it.Version + "; " + note, nil
}

func archiveKind(name string) string {
	n := strings.ToLower(name)
	switch {
	case strings.HasSuffix(n, ".zip"):
		return "zip"
	case strings.HasSuffix(n, ".tar.gz"), strings.HasSuffix(n, ".tgz"):
		return "tar"
	}
	return ""
}

// stageFiles unpacks the download beside where it goes and returns what to put there: a folder
// for app.folder, a file for app.file. Nothing is changed until it has all been checked.
func stageFiles(name string, a *appRecipe, file, dir string) (string, error) {
	kind := archiveKind(name)
	if kind == "" {
		if a.Folder != "" {
			return "", fmt.Errorf("%s is a single file, but app.folder needs an archive (.zip, .tar.gz or .tgz)", name)
		}
		return file, nil
	}
	var err error
	if kind == "zip" {
		err = unzip(file, dir)
	} else {
		err = untar(file, dir)
	}
	if err != nil {
		return "", err
	}
	if a.Folder != "" {
		return dir, nil
	}
	var found []string
	filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
		if err == nil && e.Type().IsRegular() && e.Name() == filepath.Base(a.File) {
			found = append(found, p)
		}
		return nil
	})
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		return "", fmt.Errorf("%s has no file named %s", name, filepath.Base(a.File))
	}
	return "", fmt.Errorf("%s has more than one file named %s", name, filepath.Base(a.File))
}

func untar(file, dest string) (err error) {
	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(dest)
		}
	}()
	os.RemoveAll(dest)
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if h.Typeflag == tar.TypeXGlobalHeader {
			continue
		}
		if h.Typeflag != tar.TypeDir && h.Typeflag != tar.TypeReg {
			return fmt.Errorf("the archive has an entry, %q, that is a link or not a plain file", h.Name)
		}
		p, err := safeJoin(dest, h.Name)
		if err != nil {
			return err
		}
		if h.Typeflag == tar.TypeDir {
			if err := os.MkdirAll(p, 0o700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			return err
		}
		out, err := os.Create(p)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, tr)
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return err
		}
	}
}

// backup keeps the target as <target>.dokkit-previous and says whether there was one to keep.
func backup(path string, isDir bool) (bool, error) {
	prev := path + ".dokkit-previous"
	os.RemoveAll(prev)
	fi, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if isDir {
		return true, copyAll(path, prev)
	}
	if !fi.Mode().IsRegular() {
		return false, fmt.Errorf("%s is not a plain file", path)
	}
	return true, copyEntry(path, prev, fi)
}

func restore(path string, isDir, had bool) error {
	prev := path + ".dokkit-previous"
	switch {
	case !had:
		return os.RemoveAll(path)
	case isDir:
		if err := os.RemoveAll(path); err != nil {
			return err
		}
		return os.Rename(prev, path)
	}
	return putFile(prev, path)
}

func copyEntry(from, to string, fi fs.FileInfo) error {
	switch {
	case fi.IsDir():
		if err := os.MkdirAll(to, 0o755); err != nil {
			return err
		}
		os.Chmod(to, fi.Mode().Perm())
	case fi.Mode()&fs.ModeSymlink != 0:
		l, err := os.Readlink(from)
		if err == nil {
			err = os.Symlink(l, to)
		}
		if err != nil {
			return err
		}
	case fi.Mode().IsRegular():
		if err := copyPlain(from, to); err != nil {
			return err
		}
		os.Chmod(to, fi.Mode().Perm())
	default:
		return fmt.Errorf("%s is not a plain file, folder or link", from)
	}
	cloneOwner(from, to)
	return nil
}

func copyAll(from, to string) error {
	return filepath.WalkDir(from, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		return copyEntry(p, filepath.Join(to, rel), fi)
	})
}

// putTree puts every file of src over the same path in dst; files only in dst stay. Each goes in
// by rename, so a running program is replaced and never written in place.
func putTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		t := filepath.Join(dst, rel)
		_, gone := os.Lstat(t)
		fresh := gone != nil
		switch {
		case e.IsDir():
			if fresh {
				if err := os.MkdirAll(t, 0o755); err != nil {
					return err
				}
			}
		default:
			if err := putFile(p, t); err != nil {
				return err
			}
		}
		if fresh {
			cloneOwner(filepath.Dir(t), t)
		}
		return nil
	})
}

// replaceBytes writes the file whole beside its place, then renames it in.
func replaceBytes(path string, b []byte) error {
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if err := keepOwner(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	syncDir(filepath.Dir(path))
	return nil
}

func composeTag(tag, version string) string {
	return strings.NewReplacer("{version}", version, "{number}", strings.TrimPrefix(version, "v")).Replace(tag)
}

func composeApp(ctx context.Context, d *declaration, it appItem) (string, error) {
	a := d.App
	orig, err := os.ReadFile(a.ComposeFile)
	if err != nil {
		return "", err
	}
	next, err := retag(string(orig), a.ComposeService, composeTag(a.Tag, it.Version))
	if err != nil {
		return "", fmt.Errorf("%s: %v", a.ComposeFile, err)
	}
	fi, err := os.Stat(a.ComposeFile)
	if err != nil {
		return "", err
	}
	prev := a.ComposeFile + ".dokkit-previous"
	os.Remove(prev)
	if err := os.WriteFile(prev, orig, fi.Mode().Perm()); err != nil {
		return "", fmt.Errorf("could not keep the old file as %s: %v", prev, err)
	}
	cloneOwner(a.ComposeFile, prev)
	fail := func(what string, err error, up bool) (string, error) {
		if rerr := replaceBytes(a.ComposeFile, orig); rerr != nil {
			return "", fmt.Errorf("%s: %v; the old compose file could not be put back: %v", what, err, rerr)
		}
		rest := "the old compose file was put back"
		if up {
			if uerr := runChecked(ctx, "docker", "compose", "-f", a.ComposeFile, "up", "-d", a.ComposeService); uerr != nil {
				rest += fmt.Sprintf(" but %s did not start again: %v", a.ComposeService, uerr)
			} else {
				rest += " and " + a.ComposeService + " was started again"
			}
		}
		return "", fmt.Errorf("%s: %v; %s", what, err, rest)
	}
	if err := replaceBytes(a.ComposeFile, []byte(next)); err != nil {
		return "", fmt.Errorf("could not change %s: %v", a.ComposeFile, err)
	}
	if err := runChecked(ctx, "docker", "compose", "-f", a.ComposeFile, "pull", a.ComposeService); err != nil {
		return fail("the new image was not pulled", err, false)
	}
	if err := runChecked(ctx, "docker", "compose", "-f", a.ComposeFile, "up", "-d", a.ComposeService); err != nil {
		return fail("the new version did not start", err, true)
	}
	note, err := waitHealthy(ctx, d, it.Version, healthWait(a, it))
	if err != nil {
		return fail(it.Version+" was started", err, true)
	}
	return "installed " + it.Version + "; " + note, nil
}

var composeImage = regexp.MustCompile(`^(\s+image:\s*)(["']?)([^\s"'#]+)(["']?)(.*)$`)

// retag sets the tag on the image line of one service and leaves every other byte as it was.
func retag(text, service, tag string) (string, error) {
	lines := strings.Split(text, "\n")
	head := regexp.MustCompile(`^(\s+)["']?` + regexp.QuoteMeta(service) + `["']?\s*:\s*(#.*)?\r?$`)
	top, at, indent := "", -1, 0
	for i, l := range lines {
		if t := strings.TrimSpace(l); t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if l[0] != ' ' && l[0] != '\t' {
			top = strings.TrimSpace(strings.SplitN(l, ":", 2)[0])
			continue
		}
		if m := head.FindStringSubmatch(l); m != nil && top == "services" {
			at, indent = i, len(m[1])
			break
		}
	}
	if at < 0 {
		return "", fmt.Errorf("has no service named %s", service)
	}
	for i := at + 1; i < len(lines); i++ {
		l := lines[i]
		if t := strings.TrimSpace(l); t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if len(l)-len(strings.TrimLeft(l, " \t")) <= indent {
			break
		}
		if m := composeImage.FindStringSubmatch(l); m != nil {
			ref, _, _ := strings.Cut(m[3], "@")
			if c := strings.LastIndex(ref, ":"); c > strings.LastIndex(ref, "/") {
				ref = ref[:c]
			}
			lines[i] = m[1] + m[2] + ref + ":" + tag + m[4] + m[5]
			return strings.Join(lines, "\n"), nil
		}
	}
	return "", fmt.Errorf("service %s has no image line", service)
}

func versionFile(d *declaration) string {
	from := d.Service.VersionFrom
	if from == "" || from == "stats" {
		return ""
	}
	dir := filepath.Dir(d.path)
	if !filepath.IsAbs(from) {
		from = filepath.Join(dir, from)
	}
	if !within(dir, from) {
		return ""
	}
	return from
}

// unhealthy is what is wrong right now, or "" when every check that can run is ok and the
// version file, when there is one, names the release.
func unhealthy(d *declaration, version string) string {
	var todo []*check
	for i := range d.Check {
		if runs, _ := d.Check[i].problem(); runs {
			todo = append(todo, &d.Check[i])
		}
	}
	out := make([]result, len(todo))
	parallel(len(todo), func(i int) { out[i] = todo[i].run() })
	for i, r := range out {
		switch {
		case r.blind:
			return todo[i].name + " could not be made by this account"
		case !r.ok:
			return todo[i].name + ": " + r.note
		}
	}
	if p := versionFile(d); p != "" {
		b, err := os.ReadFile(p)
		line, _, _ := strings.Cut(strings.TrimSpace(string(b)), "\n")
		line = strings.TrimSpace(line)
		if err != nil || strings.TrimPrefix(line, "v") != strings.TrimPrefix(version, "v") {
			return fmt.Sprintf("the version file says %q, not %s", line, version)
		}
	}
	return ""
}

func waitHealthy(ctx context.Context, d *declaration, version string, wait time.Duration) (string, error) {
	runs := false
	for i := range d.Check {
		r, _ := d.Check[i].problem()
		runs = runs || r
	}
	if !runs && versionFile(d) == "" {
		return "no checks to wait on", nil
	}
	start := time.Now()
	for {
		why := unhealthy(d, version)
		if why == "" {
			return fmt.Sprintf("checks ok after %d s", int(time.Since(start).Round(time.Second).Seconds())), nil
		}
		if time.Since(start) >= wait || ctx.Err() != nil {
			return "", fmt.Errorf("checks did not pass within %s: %s", wait, why)
		}
		select {
		case <-ctx.Done():
		case <-time.After(healthEvery):
		}
	}
}
