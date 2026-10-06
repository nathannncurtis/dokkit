package main

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
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

func server(t *testing.T, status *int, got *[]line, batches *[]string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer dka_test" {
			w.WriteHeader(401)
			return
		}
		if *status != 200 {
			w.WriteHeader(*status)
			return
		}
		z, err := gzip.NewReader(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l line
			json.Unmarshal(s.Bytes(), &l)
			*got = append(*got, l)
		}
		*batches = append(*batches, r.Header.Get("Dokkit-Batch"))
		w.Write([]byte(`{"accepted":1,"refused":[]}`))
	}))
}

func TestRunReportsAndKeepsWhatItCannotSend(t *testing.T) {
	status, got, batches := 200, []line{}, []string{}
	srv := server(t, &status, &got, &batches)
	defer srv.Close()
	spool := t.TempDir()
	t.Setenv("DOKKIT_URL", srv.URL+"/")
	t.Setenv("DOKKIT_KEY", "dka_test")
	t.Setenv("DOKKIT_SPOOL", spool)
	self, _ := os.Executable()

	// The test binary stands in for the job: with DOKKIT_FAKE set it prints and exits 3.
	t.Setenv("DOKKIT_FAKE", "3")
	if code := cli([]string{"run", "--job", "backup", "--", self}); code != 3 {
		t.Fatalf("exit code %d, want the command's 3", code)
	}
	if len(got) != 2 || got[0].Event != "start" || got[1].Event != "fail" || got[0].Run != got[1].Run || got[0].Name != "backup" {
		t.Fatalf("lines: %+v", got)
	}
	if *got[1].ExitCode != 3 || !strings.Contains(got[1].Tail, "disk full") || got[1].Duration == nil {
		t.Fatalf("finish line: %+v", got[1])
	}
	if len(batches[0]) != 36 || batches[0] == batches[1] {
		t.Fatalf("batch ids: %v", batches)
	}

	status = 503
	if code := cli([]string{"ping", "backup"}); code != 0 {
		t.Fatalf("ping must not fail the caller, got %d", code)
	}
	if kept, _ := filepath.Glob(filepath.Join(spool, "*.ndjson")); len(kept) != 1 {
		t.Fatalf("want 1 batch kept in the spool, have %d", len(kept))
	}
	status = 200
	if code := cli([]string{"ping", "backup", "ok"}); code != 0 {
		t.Fatal(code)
	}
	if kept, _ := filepath.Glob(filepath.Join(spool, "*.ndjson")); len(kept) != 0 || len(got) != 4 {
		t.Fatalf("spool not drained: %d files, %d lines", len(kept), len(got))
	}

	if code := cli([]string{"run", "--job", "backup", "--", "no-such-command-anywhere"}); code != 127 {
		t.Fatalf("a command that cannot start should exit 127, got %d", code)
	}
	if code := cli([]string{"run", "backup"}); code != 2 {
		t.Fatalf("bad usage should exit 2, got %d", code)
	}
}

func TestEnrolSavesTheKeyAndWatchUsesIt(t *testing.T) {
	var inventory map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/v1/enrol":
			var b map[string]string
			json.NewDecoder(r.Body).Decode(&b)
			if b["token"] != "dke_once" || b["hostname"] == "" {
				w.WriteHeader(401)
				w.Write([]byte(`{"error":{"message":"used"}}`))
				return
			}
			w.Write([]byte(`{"machine":"m1","key":"dkm_machine"}`))
		case r.Header.Get("Authorization") == "Bearer dkm_machine":
			z, _ := gzip.NewReader(r.Body)
			json.NewDecoder(z).Decode(&inventory)
			w.Write([]byte(`{"accepted":1,"refused":[]}`))
		default:
			w.WriteHeader(401)
		}
	}))
	defer srv.Close()
	t.Setenv("DOKKIT_URL", "")
	t.Setenv("DOKKIT_KEY", "")
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "dokkit", "config.json"))
	t.Setenv("DOKKIT_SPOOL", t.TempDir())

	if code := cli([]string{"doctor"}); code != 2 {
		t.Fatalf("with no key anywhere, want 2, got %d", code)
	}
	if code := cli([]string{"enrol", srv.URL, "dke_wrong"}); code != 1 {
		t.Fatalf("a bad token should fail, got %d", code)
	}
	if code := cli([]string{"enrol", srv.URL + "/", "dke_once"}); code != 0 {
		t.Fatalf("enrol failed: %d", code)
	}
	c, err := load()
	if err != nil || c.key != "dkm_machine" || c.url != srv.URL {
		t.Fatalf("saved config not used: %+v %v", c, err)
	}
	c.beat()
	c.flush(5 * time.Second)
	if inventory["type"] != "inventory" || inventory["dokkit"] != version {
		t.Fatalf("inventory: %v", inventory)
	}
	if l := c.job(line{Name: "backup", Event: "ok"}); l.Service != "backup" || l.Type != "job" {
		t.Fatalf("a machine key names the job as a service: %+v", l)
	}
}

func TestWatchDeclaresAndRunsChecks(t *testing.T) {
	var declared map[string]any
	var states []map[string]any
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/broken" {
			w.WriteHeader(500)
		}
	}))
	defer app.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/declare" {
			json.NewDecoder(r.Body).Decode(&declared)
			w.Write([]byte(`{"service":"s1"}`))
			return
		}
		z, _ := gzip.NewReader(r.Body)
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l map[string]any
			json.Unmarshal(s.Bytes(), &l)
			states = append(states, l)
		}
		w.Write([]byte(`{"accepted":1,"refused":[]}`))
	}))
	defer srv.Close()

	folder := t.TempDir()
	os.Mkdir(filepath.Join(folder, "portal"), 0o700)
	file := filepath.Join(folder, "portal", "dokkit.toml")
	port := strings.Split(app.URL, ":")[2]
	os.WriteFile(file, []byte(`schema = 1
[service]
id = "portal"
name = "Upload portal"

[[check]]
type = "http"
url = "`+app.URL+`/healthz"
every = "2s"

[[check]]
type = "http"
url = "`+app.URL+`/broken"

[[check]]
type = "tcp"
port = `+port+`

[[check]]
type = "custom"
name = "queue-age"

[[job]]
id = "purge"
schedule = "0 1 * * *"
`), 0o600)

	t.Setenv("DOKKIT_URL", srv.URL)
	t.Setenv("DOKKIT_KEY", "dkm_machine")
	t.Setenv("DOKKIT_SPOOL", t.TempDir())
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "none.json"))
	t.Setenv("DOKKIT_FOLDERS", folder)

	if code := cli([]string{"check", file}); code != 1 {
		t.Fatalf("check should exit 1 when a check fails, got %d", code)
	}
	if declared != nil || len(states) != 0 {
		t.Fatal("check must not send anything")
	}

	c, _ := load()
	w := &watcher{c: c, folders: c.folders, files: map[string]*declaration{}, modified: map[string]time.Time{}}
	w.refresh()
	if declared["service"].(map[string]any)["id"] != "portal" || len(declared["job"].([]any)) != 1 {
		t.Fatalf("declared: %v", declared)
	}
	at := time.Now()
	if ran := w.tick(at); ran != 3 {
		t.Fatalf("ran %d checks, want 3 (the custom one is the app's)", ran)
	}
	if ran := w.tick(at.Add(time.Second)); ran != 0 {
		t.Fatalf("nothing is due after a second, ran %d", ran)
	}
	if ran := w.tick(at.Add(3 * time.Second)); ran != 1 {
		t.Fatalf("only the 2s check is due, ran %d", ran)
	}
	c.flush(5 * time.Second)
	got := map[string]string{}
	for _, l := range states {
		got[l["check"].(string)] = l["state"].(string)
	}
	if got["http"] != "ok" || got["http-2"] != "down" || got["tcp"] != "ok" {
		t.Fatalf("states: %v", states)
	}

	os.WriteFile(file, []byte("schema = 2"), 0o600)
	os.Chtimes(file, at.Add(time.Hour), at.Add(time.Hour))
	w.refresh()
	if len(w.files) != 1 {
		t.Fatal("a file that stops parsing keeps its last good checks")
	}
	os.Remove(file)
	w.refresh()
	if len(w.files) != 0 {
		t.Fatal("a file that is gone is forgotten")
	}
}

func TestMain(m *testing.M) {
	if os.Getenv("DOKKIT_FAKE") != "" && len(os.Args) == 1 {
		os.Stdout.WriteString("copying\n")
		os.Stderr.WriteString("rsync: disk full\n")
		os.Exit(3)
	}
	os.Exit(m.Run())
}

func TestRingKeepsTheEnd(t *testing.T) {
	r := &ring{max: 5}
	r.Write([]byte("hello "))
	r.Write([]byte("world"))
	if r.String() != "world" {
		t.Fatal(r.String())
	}
}

func TestLogFilesAreSentOnceTheServerHasThem(t *testing.T) {
	var got []map[string]any
	batches := map[string]bool{}
	status := 503
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status != 200 {
			w.WriteHeader(status)
			return
		}
		batches[r.Header.Get("Dokkit-Batch")] = true
		z, _ := gzip.NewReader(r.Body)
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l map[string]any
			json.Unmarshal(s.Bytes(), &l)
			got = append(got, l)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"portal\"\n[logs]\npath = \"*.log\"\n"), 0o600)
	file := filepath.Join(dir, "app.log")
	os.WriteFile(file, []byte(`{"t":"2026-10-05T21:14:03Z","level":"error","msg":"Upload failed","type":"state"}`+"\nplain words\r\nhalf a li"), 0o600)
	d, err := readDeclaration(filepath.Join(dir, "dokkit.toml"))
	if err != nil {
		t.Fatal(err)
	}
	c := &client{url: srv.URL, key: "dkm_machine", spool: t.TempDir(), http: &http.Client{}}
	w := &watcher{c: c, files: map[string]*declaration{d.path: d}, logs: map[string]int64{}}

	w.tail()
	if len(got) != 0 || len(w.logs) != 0 {
		t.Fatal("nothing moves while the server is away")
	}
	status = 200
	w.tail()
	if len(got) != 2 || got[0]["type"] != "log" || got[0]["service"] != "portal" || got[1]["msg"] != "plain words" {
		t.Fatalf("lines: %v", got)
	}
	w.tail()
	if len(got) != 2 {
		t.Fatal("a half line waits, and sent lines are not sent again")
	}
	f, _ := os.OpenFile(file, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("ne\n")
	f.Close()
	os.Rename(file, filepath.Join(dir, "app.1.log"))
	w.tail()
	if len(got) != 3 || got[2]["msg"] != "half a line" || len(batches) != 2 {
		t.Fatalf("after a rename: %v", got)
	}
	if b, _ := os.ReadFile(filepath.Join(c.spool, "logs.json")); !strings.Contains(string(b), ":") {
		t.Fatal("positions are saved")
	}
}

func TestInitWritesAFileThatChecks(t *testing.T) {
	t.Chdir(t.TempDir())
	if code := initFile("dokkit.toml", strings.NewReader("Upload portal\n\n8080\nlogs/*.jsonl\n")); code != 0 {
		t.Fatal(code)
	}
	d, err := readDeclaration("dokkit.toml")
	if err != nil || d.Service.ID != "upload-portal" || d.Check[0].Port != 8080 || d.Logs.Path != "logs/*.jsonl" {
		t.Fatalf("%v %+v", err, d)
	}
	if initFile("dokkit.toml", strings.NewReader("")) != 1 {
		t.Fatal("init must not overwrite")
	}
}

func TestScanWritesAFileAndTasksRunWhereTheirFileIs(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("DOKKIT_CONFIG", filepath.Join(dir, "none.json"))
	t.Setenv("DOKKIT_URL", "")
	os.WriteFile("dokkit.toml", []byte("schema = 1\n[service]\nid = \"portal\"\n[[task]]\nid = \"mark\"\nrun = \"echo done > marked.txt\"\n[[task]]\nid = \"bad\"\nrun = \"exit 4\"\n"), 0o600)

	if code := cli([]string{"scan", "--no-tasks", "--no-services", "--no-ports", "--no-containers", "--no-sites"}); code != 0 {
		t.Fatal(code)
	}
	var p struct{ Found map[string][]found }
	b, _ := os.ReadFile(proposalFile)
	json.Unmarshal(b, &p)
	if _, there := p.Found["services"]; there || len(p.Found["disks"]) == 0 {
		t.Fatalf("proposal: %s", b)
	}

	if cli([]string{"task", "list"}) != 0 || cli([]string{"task", "run", "nope"}) != 1 {
		t.Fatal("list works and an unknown task is refused")
	}
	if code := cli([]string{"task", "run", "mark"}); code != 0 {
		t.Fatal(code)
	}
	if _, err := os.Stat("marked.txt"); err != nil {
		t.Fatal("the task did not run in its file's folder")
	}
	if code := cli([]string{"task", "run", "bad"}); code != 4 {
		t.Fatalf("a task exits as its command did, got %d", code)
	}
}

func TestWorkRunsOnlyTheAcceptedCommand(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"portal\"\n[[task]]\nid = \"hello\"\nrun = \"echo hello from the task\"\n"), 0o600)
	sum := sha256.Sum256([]byte("echo hello from the task"))
	offers := []string{
		`{"run":"r1","task":"hello","command_sha256":"` + hex.EncodeToString(sum[:]) + `"}`,
		`{"run":"r2","task":"hello","command_sha256":"some other command"}`,
	}
	got := make(chan string, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			if len(offers) == 0 {
				time.Sleep(100 * time.Millisecond)
				w.WriteHeader(204)
				return
			}
			w.Write([]byte(offers[0]))
			offers = offers[1:]
			return
		}
		b, _ := io.ReadAll(r.Body)
		got <- r.URL.Path + " " + string(b)
	}))
	defer srv.Close()
	c := &client{url: srv.URL, key: "dkm_machine", folders: []string{dir}}
	go c.work()
	want := []string{"/api/v1/work/r1/output hello from the task", "/api/v1/work/r1/result {", "/api/v1/work/r2/result {\"refused\""}
	for _, w := range want {
		select {
		case g := <-got:
			if !strings.HasPrefix(g, w) || (strings.Contains(w, "r1/result") && !strings.Contains(g, `"exit_code":0`)) {
				t.Fatalf("got %q, want %q", g, w)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("nothing arrived for " + w)
		}
	}
}
