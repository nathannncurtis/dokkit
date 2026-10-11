package main

import (
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// capture runs f and returns what it wrote to standard output and standard error.
func capture(t *testing.T, f func()) (string, string) {
	t.Helper()
	oldOut, oldErr := os.Stdout, os.Stderr
	ro, wo, _ := os.Pipe()
	re, we, _ := os.Pipe()
	os.Stdout, os.Stderr = wo, we
	f()
	wo.Close()
	we.Close()
	os.Stdout, os.Stderr = oldOut, oldErr
	o, _ := io.ReadAll(ro)
	e, _ := io.ReadAll(re)
	return string(o), string(e)
}

// ownConfig points the person's own configuration at a new file and returns its path.
func ownConfig(t *testing.T, content string) string {
	p := filepath.Join(t.TempDir(), "config.json")
	if content != "" {
		os.WriteFile(p, []byte(content), 0o600)
	}
	t.Setenv("DOKKIT_CONFIG", p)
	t.Setenv("DOKKIT_FOLDERS", "")
	return p
}

func savedFolderList(t *testing.T, p string) []string {
	var s saved
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(b, &s)
	return s.Folders
}

func TestFolderAddRemoveAndListEditOnlyTheFolderList(t *testing.T) {
	p := ownConfig(t, `{"url":"https://s","key":"dkm_x","pin":"sha256:aa"}`)
	dir := t.TempDir()
	t.Chdir(filepath.Dir(dir))
	rel := filepath.Base(dir)

	if code := folderCommand([]string{"add", rel}); code != 0 {
		t.Fatal(code)
	}
	if got := savedFolderList(t, p); len(got) != 1 || !filepath.IsAbs(got[0]) || !sameFolder(got[0], dir) {
		t.Fatalf("the path is made absolute: %v", got)
	}
	var kept map[string]any
	b, _ := os.ReadFile(p)
	json.Unmarshal(b, &kept)
	if kept["url"] != "https://s" || kept["key"] != "dkm_x" || kept["pin"] != "sha256:aa" {
		t.Fatalf("the rest of the file is kept: %v", kept)
	}
	before, _ := os.ReadFile(p)
	out, _ := capture(t, func() { folderCommand([]string{"add", dir}) })
	if after, _ := os.ReadFile(p); string(before) != string(after) || !strings.Contains(out, "already") {
		t.Fatalf("adding twice changes nothing: %s", out)
	}
	out, _ = capture(t, func() { folderCommand([]string{"list"}) })
	if !strings.Contains(out, dir) {
		t.Fatalf("%s", out)
	}
	if folderCommand([]string{"remove", dir}) != 0 || len(savedFolderList(t, p)) != 0 {
		t.Fatal("remove takes it out")
	}
	if code := folderCommand([]string{"remove", dir}); code != 0 {
		t.Fatal("removing what is not there is not an error")
	}
}

func TestFolderAddNeedsAFolderThatExists(t *testing.T) {
	p := ownConfig(t, "")
	file := filepath.Join(t.TempDir(), "a-file")
	os.WriteFile(file, nil, 0o600)
	for _, bad := range []string{filepath.Join(t.TempDir(), "gone"), file} {
		if code := folderCommand([]string{"add", bad}); code != 1 {
			t.Fatalf("%s: %d", bad, code)
		}
	}
	if _, err := os.Stat(p); err == nil {
		t.Fatal("nothing was written")
	}
	for _, bad := range [][]string{{}, {"add"}, {"list", "x"}, {"nope", "x"}} {
		if folderCommand(bad) != 2 {
			t.Fatalf("%v", bad)
		}
	}
}

func TestTheInstalledServicesListNeedsAnAdministrator(t *testing.T) {
	t.Setenv("DOKKIT_CONFIG", "")
	t.Setenv("DOKKIT_FOLDERS", "")
	svc := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(svc, []byte(`{"url":"https://s","key":"dkm_x","restart":["web"]}`), 0o600)
	oldConfig, oldOwn := serviceConfig, ownService
	t.Cleanup(func() { serviceConfig, ownService = oldConfig, oldOwn })
	serviceConfig = func() string { return svc }
	dir := t.TempDir()

	// Not an administrator: the file cannot be written.
	ownService = func(string) error { return fs.ErrPermission }
	var code int
	_, errOut := capture(t, func() { code = folderCommand([]string{"add", dir}) })
	exe, _ := os.Executable()
	if code != 1 || !strings.Contains(errOut, "administrator") || !strings.Contains(errOut, "folder add "+quoteArg(dir)) || !strings.Contains(errOut, quoteArg(exe)) {
		t.Fatalf("%d %s", code, errOut)
	}
	if runtime.GOOS != "windows" && !strings.Contains(errOut, "sudo ") {
		t.Fatalf("the exact sudo line: %s", errOut)
	}
	if len(savedFolderList(t, svc)) != 0 {
		t.Fatal("the service's list is unchanged")
	}

	// An administrator: the service's file changes, the person's own does not exist.
	ownService = func(string) error { return nil }
	own := filepath.Join(t.TempDir(), "own.json")
	t.Setenv("DOKKIT_CONFIG", "")
	if code := folderCommand([]string{"add", dir}); code != 0 {
		t.Fatal(code)
	}
	if got := savedFolderList(t, svc); len(got) != 1 || !sameFolder(got[0], dir) {
		t.Fatalf("%v", got)
	}
	var kept saved
	b, _ := os.ReadFile(svc)
	json.Unmarshal(b, &kept)
	if !slices.Equal(kept.Restart, []string{"web"}) {
		t.Fatalf("the restart list is kept: %+v", kept)
	}
	if _, err := os.Stat(own); err == nil {
		t.Fatal("not the person's own")
	}
	if line := folderAddLine(dir); !strings.Contains(line, "folder add") || (runtime.GOOS != "windows" && !strings.HasPrefix(line, "sudo ")) {
		t.Fatalf("with the service installed the line is the elevated one: %s", line)
	}
}

func TestInitEndsWithTheFolderAddLine(t *testing.T) {
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "c.json"))
	dir := t.TempDir()
	t.Chdir(dir)
	out, _ := capture(t, func() { initFile("dokkit.toml", strings.NewReader("App\n\n\n\n")) })
	last := strings.TrimSpace(out[strings.LastIndex(strings.TrimSpace(out), "\n")+1:])
	abs, _ := filepath.Abs(".")
	if !strings.HasSuffix(last, "dokkit folder add "+quoteArg(abs)) {
		t.Fatalf("%q", last)
	}
}

func TestAWatchPicksUpAChangedFolderListWithoutARestart(t *testing.T) {
	p := ownConfig(t, `{"url":"https://s","key":"dkm_x"}`)
	t.Setenv("DOKKIT_SPOOL", t.TempDir())
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("{}")) }))
	defer srv.Close()
	c, err := load()
	if err != nil || len(c.folders) != 0 {
		t.Fatalf("%v %v", err, c.folders)
	}
	c.http, c.url, c.key = &http.Client{}, srv.URL, "dkm_machine"
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"late\"\n"), 0o600)
	w := &watcher{c: c, files: map[string]*declaration{}, modified: map[string]time.Time{}}
	w.reload()
	w.refresh()
	if len(w.files) != 0 {
		t.Fatal("nothing yet")
	}
	if folderCommand([]string{"add", dir}) != 0 {
		t.Fatal("add")
	}
	w.reload()
	w.refresh()
	if len(w.files) != 1 || len(w.folders) != 1 || len(c.foldersNow()) != 1 {
		t.Fatalf("the list is read again at each refresh: %v", w.folders)
	}
	// DOKKIT_FOLDERS still wins when it is set.
	t.Setenv("DOKKIT_FOLDERS", "/elsewhere")
	w.reload()
	if len(w.folders) != 1 || w.folders[0] != "/elsewhere" {
		t.Fatalf("%v", w.folders)
	}
	_ = p
}

func TestTheWordHelpAfterACommandPrintsHelpAndRunsNothing(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++ }))
	defer srv.Close()
	spool := t.TempDir()
	t.Setenv("DOKKIT_URL", srv.URL)
	t.Setenv("DOKKIT_KEY", "dkm_machine")
	t.Setenv("DOKKIT_SPOOL", spool)
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "none.json"))
	t.Setenv("DOKKIT_FOLDERS", "")
	dir := t.TempDir()
	t.Chdir(dir)
	for _, name := range []string{"scan", "propose", "watch", "status", "doctor", "startup", "service", "init", "check", "apply", "enrol", "folder"} {
		type answer struct {
			code int
			out  string
		}
		done := make(chan answer, 1)
		go func() {
			var code int
			out, _ := capture(t, func() { code = cli([]string{name, "help"}) })
			done <- answer{code, out}
		}()
		select {
		case a := <-done:
			if a.code != 0 || !strings.Contains(a.out, "dokkit "+name) {
				t.Fatalf("%s help: %d %q", name, a.code, a.out)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%s help ran the command", name)
		}
	}
	if hits != 0 {
		t.Fatalf("nothing was sent: %d requests", hits)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("nothing was written here: %v", entries)
	}
	if left, _ := filepath.Glob(filepath.Join(spool, "*")); len(left) != 0 {
		t.Fatalf("nothing was spooled: %v", left)
	}
}
