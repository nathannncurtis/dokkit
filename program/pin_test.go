package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAPinCoversEveryScriptTheCommandNamesInsideItsFolder(t *testing.T) {
	dir, outside := t.TempDir(), t.TempDir()
	files := []string{"x.py", "b.bat", "b"}
	for _, f := range files {
		os.WriteFile(filepath.Join(dir, f), []byte("one"), 0o600)
	}
	os.WriteFile(filepath.Join(outside, "tool"), []byte("one"), 0o600)
	pin := func(run string) string {
		return task{ID: "t", Run: run, dir: dir, file: filepath.Join(dir, "dokkit.toml")}.pin()
	}
	for run, named := range map[string]string{
		"python x.py":   "x.py",
		`"b.bat" --all`: "b.bat",
		`.\b`:           "b",
		"cmd /c b.bat":  "b.bat",
		"echo nothing":  "",
	} {
		before := pin(run)
		for _, f := range files {
			os.WriteFile(filepath.Join(dir, f), []byte("two"), 0o600)
			if changed := pin(run) != before; changed != (f == named) {
				t.Fatalf("%q, %s edited: pin changed %v", run, f, changed)
			}
			os.WriteFile(filepath.Join(dir, f), []byte("one"), 0o600)
		}
	}
	abs := "echo " + filepath.Join(outside, "tool")
	before := pin(abs)
	os.WriteFile(filepath.Join(outside, "tool"), []byte("two"), 0o600)
	if pin(abs) != before {
		t.Fatal("a file outside the task's folder is not hashed")
	}
}

func TestAPinFollowsALinkOnlyWhileItStaysInside(t *testing.T) {
	dir, outside := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(outside, "real.sh"), []byte("one"), 0o600)
	if os.Symlink(filepath.Join(outside, "real.sh"), filepath.Join(dir, "link.sh")) != nil {
		t.Skip("links need a privilege here")
	}
	task := task{ID: "t", Run: "link.sh", dir: dir, file: filepath.Join(dir, "dokkit.toml")}
	if len(task.scripts()) != 0 {
		t.Fatal("a link out of the folder is not a script of the task")
	}
}

func TestDeclareSendsAPinForEitherWayOfWritingTasks(t *testing.T) {
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		json.Unmarshal(b, &m)
		bodies = append(bodies, m)
	}))
	defer srv.Close()
	dir := t.TempDir()
	forms := []string{
		"schema = 1\ntask = [{id = \"hello\", run = \"echo hi\"}]\n[service]\nid = \"inline\"\n",
		"schema = 1\n[service]\nid = \"table\"\n[[task]]\nid = \"hello\"\nrun = \"echo hi\"\n",
	}
	for i, form := range forms {
		p := filepath.Join(dir, "dokkit"+string(rune('a'+i))+".toml")
		os.WriteFile(p, []byte(form), 0o600)
		d, err := readDeclaration(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := (&client{url: srv.URL, key: "k"}).declare(d); err != nil {
			t.Fatal(err)
		}
	}
	if len(bodies) != 2 {
		t.Fatalf("sent %d", len(bodies))
	}
	for _, m := range bodies {
		var one map[string]any
		switch v := m["task"].(type) {
		case []any:
			one, _ = v[0].(map[string]any)
		}
		if one == nil || one["pin"] == nil || one["pin"] == "" || !strings.HasSuffix(one["file"].(string), ".toml") {
			t.Fatalf("a task is sent with its pin and file: %v", m["task"])
		}
	}
}

func TestAnEditedScriptIsDeclaredAgain(t *testing.T) {
	puts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" {
			puts++
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"edited\"\n[[task]]\nid = \"go\"\nrun = \"go.bat\"\n"), 0o600)
	script := filepath.Join(dir, "go.bat")
	os.WriteFile(script, []byte("echo one"), 0o600)
	w := &watcher{c: &client{url: srv.URL, key: "k"}, folders: []string{dir}, files: map[string]*declaration{}, modified: map[string]time.Time{}}
	w.refresh()
	w.refresh()
	if puts != 1 {
		t.Fatalf("an unchanged file is sent once, sent %d", puts)
	}
	os.WriteFile(script, []byte("echo two"), 0o600)
	w.refresh()
	if puts != 2 {
		t.Fatalf("an edited script is sent again, sent %d", puts)
	}
}
