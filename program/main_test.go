package main

import (
	"bufio"
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
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
	c.beat(nil)
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
		if r.URL.Path == "/api/v1/checks" {
			w.Write([]byte(`{"items":[{"service":"port-1","name":"tcp","type":"tcp","config":{"port":1}}]}`))
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
version_from = "VERSION"

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
	os.WriteFile(filepath.Join(folder, "portal", "VERSION"), []byte("2.3.1\nbuilt on a Tuesday\n"), 0o600)
	if v := w.versions(); len(v) != 1 || v[0]["id"] != "portal" || v[0]["version"] != "2.3.1" {
		t.Fatalf("versions: %v", v)
	}
	at := time.Now()
	if ran := w.tick(at); ran != 4 {
		t.Fatalf("ran %d checks, want the file's 3 (the custom one is the app's) and the 1 added in the interface", ran)
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
	if got["http"] != "ok" || got["http-2"] != "down" {
		t.Fatalf("states: %v", states)
	}
	added := false
	for _, l := range states {
		added = added || (l["service"] == "port-1" && l["state"] == "down")
	}
	if !added {
		t.Fatalf("the check added in the interface did not report: %v", states)
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
	pin := tasks(declarations([]string{dir}))["hello"].pin()
	offers := []string{
		`{"run":"r1","task":"hello","command_sha256":"` + pin + `"}`,
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

func TestStatsVitalsAndExpiry(t *testing.T) {
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Stats-Key") != "s3cret" {
			w.WriteHeader(404)
			return
		}
		w.Write([]byte(`{"schema":1,"version":"2.3.0"}`))
	}))
	defer app.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "licence"), []byte(time.Now().Add(10*24*time.Hour+time.Hour).Format("2006-01-02")+"\n"), 0o600)
	file := filepath.Join(dir, "dokkit.toml")
	os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"portal\"\n[stats]\nurl = \""+app.URL+"\"\nkey_env = \"DOKKIT_STATS_TEST\"\n[[check]]\ntype = \"expiry\"\ndate_from = \"licence\"\n"), 0o600)
	d, err := readDeclaration(file)
	if err != nil {
		t.Fatal(err)
	}
	w := &watcher{files: map[string]*declaration{file: d}}

	lines := w.stats()
	if len(lines) != 1 || lines[0].(map[string]any)["state"] != "down" {
		t.Fatalf("without the key the fetch fails: %v", lines)
	}
	t.Setenv("DOKKIT_STATS_TEST", "s3cret")
	lines = w.stats()
	if got := lines[0].(map[string]any); got["type"] != "stats" || got["document"].(map[string]any)["version"] != "2.3.0" {
		t.Fatalf("stats: %v", lines)
	}

	r := d.Check[0].run()
	if l := stateLine(d, &d.Check[0], r); l["state"] != "degraded" || l["value"].(float64) > 11 || l["value"].(float64) < 9 {
		t.Fatalf("expiry: %v", l)
	}

	vitals()
	time.Sleep(500 * time.Millisecond)
	found := map[string]bool{}
	for _, l := range vitals() {
		m := l.(map[string]any)
		if v := m["value"].(float64); v < 0 || v > 100 {
			t.Fatalf("out of range: %v", m)
		}
		found[strings.SplitN(m["name"].(string), ".", 2)[0]] = true
	}
	if !found["memory"] || !found["cpu"] || !found["disk"] {
		t.Fatalf("vitals: %v", found)
	}
}

func TestAPinnedServerIsTheOnlyOneTrusted(t *testing.T) {
	defer func() { toServer = http.DefaultTransport }()
	hello := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"key":"dkm_new"}`)) })
	// The test servers all share one built-in certificate, so the other one gets its own.
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	about := &x509.Certificate{SerialNumber: big.NewInt(1), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, _ := x509.CreateCertificate(rand.Reader, about, about, &key.PublicKey, key)
	real, other := httptest.NewTLSServer(hello), httptest.NewUnstartedServer(hello)
	other.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	other.StartTLS()
	defer real.Close()
	defer other.Close()
	sum := sha256.Sum256(real.Certificate().Raw)
	pin := "sha256:" + hex.EncodeToString(sum[:])
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "config.json"))
	t.Setenv("DOKKIT_URL", "")
	t.Setenv("DOKKIT_KEY", "")
	t.Setenv("DOKKIT_SPOOL", t.TempDir())

	if code := enrol(real.URL, "dke_token", ""); code != 1 {
		t.Fatal("without a pin, a certificate nobody vouches for is refused")
	}
	if code := enrol(other.URL, "dke_token", pin); code != 1 {
		t.Fatal("another server must be refused")
	}
	if code := enrol(real.URL, "dke_token", pin); code != 0 {
		t.Fatal("the pinned server must be accepted")
	}
	c, err := load()
	if err != nil || c.pin != pin {
		t.Fatalf("the pin is saved: %v %+v", err, c)
	}
	if status, err := c.call("GET", "/api/v1/ping", "", nil, nil); err != nil || status != 200 {
		t.Fatalf("later requests use the pin: %d %v", status, err)
	}
	c.url = other.URL
	if _, err := c.call("GET", "/api/v1/ping", "", nil, nil); err == nil {
		t.Fatal("and refuse any other server")
	}
}

func TestAStoppedServiceIsStartedOnlyWhenAllowedAndNotOver(t *testing.T) {
	defer func() { startService = nil }()
	started := 0
	startService = func(string) error { started++; return nil }
	no, yes := &check{Name: "no-such-service-a"}, &check{Name: "no-such-service-b", restart: true}
	if no.tryRestart() || started != 0 {
		t.Fatal("a service nobody allowed is left alone")
	}
	if !yes.tryRestart() || yes.tryRestart() || started != 1 {
		t.Fatalf("an allowed one is started once in ten minutes, was %d", started)
	}
	startService = nil
	restarted = map[string]time.Time{}
	if yes.tryRestart() {
		t.Fatal("only the installed service starts things")
	}
}

func TestATaskIsAcceptedOnlyAsItWasWritten(t *testing.T) {
	dir := t.TempDir()
	zap := task{ID: "zap", Run: "scripts/zap.ps1", dir: dir, file: filepath.Join(dir, "dokkit.toml")}
	sha := zap.pin()
	if got := standing(zap, sha, true); got != "accepted" {
		t.Fatal(got)
	}
	more := zap
	more.Run = "scripts/zap.ps1 --all"
	if got := standing(more, sha, true); got != "changed since it was accepted" {
		t.Fatal(got)
	}
	if got := standing(zap, "", false); got != "not accepted yet" {
		t.Fatal(got)
	}
	if _, asked := accepted(nil); asked {
		t.Fatal("a machine that is not enrolled has nobody to ask")
	}
}

func TestATaskPinCoversItsScriptAndItsFolder(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(a, "backup.bat"), []byte("echo one"), 0o600)
	os.WriteFile(filepath.Join(b, "backup.bat"), []byte("echo one"), 0o600)
	at := func(dir string) task {
		return task{ID: "backup", Run: "backup.bat --all", dir: dir, file: filepath.Join(dir, "dokkit.toml")}
	}
	before := at(a).pin()
	if before != at(a).pin() {
		t.Fatal("the same task has the same pin")
	}
	if at(b).pin() == before {
		t.Fatal("the same task text declared from another folder has another pin")
	}
	os.WriteFile(filepath.Join(a, "backup.bat"), []byte("echo two"), 0o600)
	if at(a).pin() == before {
		t.Fatal("the pin follows the script's contents")
	}
}

func TestAnUpdateIsFetchedAndNothingIsReplaced(t *testing.T) {
	said := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/v1/program/"):
			w.Write([]byte("the newer copy"))
		case strings.HasSuffix(r.URL.Path, "/output"):
			b, _ := io.ReadAll(r.Body)
			said += string(b)
		}
	}))
	defer server.Close()
	dir := t.TempDir()
	c := &client{url: server.URL, key: "dkm_test", spool: filepath.Join(dir, "spool")}
	c.update("run-1")
	fetched, _ := filepath.Glob(filepath.Join(dir, "update", "dokkit*"))
	if len(fetched) != 1 {
		t.Fatalf("one file is left beside the spool: %v", fetched)
	}
	b, err := os.ReadFile(fetched[0])
	if err != nil || string(b) != "the newer copy" {
		t.Fatalf("the copy is left beside the spool: %q %v", b, err)
	}
	if !strings.Contains(said, "The newer copy is at") || !strings.Contains(said, "To finish") {
		t.Fatalf("the run says where it is and how to finish: %q", said)
	}
}

func TestANameDeclaredTwiceBelongsToNeither(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	toml := func(dir, run string) string {
		p := filepath.Join(dir, "dokkit.toml")
		os.WriteFile(p, []byte("schema = 1\n[service]\nid = \"s\"\n[[task]]\nid = \"same\"\nrun = \""+run+"\"\n[[task]]\nid = \"only\"\nrun = \"x\"\n"), 0o600)
		return p
	}
	pa, pb := toml(a, "echo a"), toml(b, "echo b")
	if got := tasks([]string{pa, pa}); len(got) != 2 {
		t.Fatalf("one file listed twice is still one file: %v", got)
	}
	got := tasks([]string{pa, pb})
	if _, ok := got["same"]; ok {
		t.Fatal("a name two files declare must not run")
	}
}

func TestATimedOutTaskDoesNotWaitForWhatItStarted(t *testing.T) {
	killWait = 500 * time.Millisecond
	slow := "sleep 20 & wait"
	if runtime.GOOS == "windows" {
		slow = "ping -n 20 127.0.0.1"
	}
	start := time.Now()
	code := task{ID: "slow", Run: slow, Timeout: "1s", dir: "."}.run(&chunks{}, &chunks{}, nil)
	if code != 124 || time.Since(start) > 10*time.Second {
		t.Fatalf("code %d after %s", code, time.Since(start))
	}
}

func TestSystemTasksNeedTheMachinesOwnSay(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"s\"\n[[task]]\nid = \"hello\"\nrun = \"echo hi\"\n"), 0o600)
	pin := tasks(declarations([]string{dir}))["hello"].pin()
	offered := false
	posts := make(chan string, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			if !offered {
				offered = true
				w.Write([]byte(`{"run":"s1","task":"hello","as":"system","command_sha256":"` + pin + `"}`))
				return
			}
			time.Sleep(100 * time.Millisecond)
			w.WriteHeader(204)
			return
		}
		b, _ := io.ReadAll(r.Body)
		posts <- r.URL.Path + " " + string(b)
	}))
	defer srv.Close()
	go (&client{url: srv.URL, key: "k", folders: []string{dir}}).work()
	select {
	case g := <-posts:
		if !strings.HasPrefix(g, `/api/v1/work/s1/result {"refused"`) || !strings.Contains(g, "system_tasks") {
			t.Fatal(g)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no answer")
	}
}

func TestAResultIsSentAgainWhenTheServerFails(t *testing.T) {
	resultWait = time.Millisecond
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls++; calls < 3 {
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	(&client{url: srv.URL, key: "k"}).postResult("/api/v1/work/r/result", []byte(`{}`))
	if calls != 3 {
		t.Fatalf("expected 3 posts, got %d", calls)
	}
}

func TestAFetchedUpdateMustMatchTheHashItIsHeldTo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("the newer copy")) }))
	defer srv.Close()
	dir := t.TempDir()
	c := &client{url: srv.URL, key: "k", spool: filepath.Join(dir, "spool"), updateSha: strings.Repeat("0", 64)}
	if _, _, err := c.fetchUpdate(); err == nil {
		t.Fatal("a copy with another hash was kept")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "update", "dokkit*")); len(left) != 0 {
		t.Fatalf("nothing is left to run: %v", left)
	}
	sum := sha256.Sum256([]byte("the newer copy"))
	c.updateSha = hex.EncodeToString(sum[:])
	if _, _, err := c.fetchUpdate(); err != nil {
		t.Fatal(err)
	}
	c.updateSha = strings.Repeat("1", 64)
	if _, _, err := c.fetchUpdate(); err == nil {
		t.Fatal("a copy with another hash was kept")
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "update", "dokkit*")); len(left) != 0 {
		t.Fatalf("an earlier copy is still there: %v", left)
	}
}

func TestOneFileReachedTwoWaysIsOneFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "dokkit.toml")
	os.WriteFile(p, []byte("schema = 1\n[service]\nid = \"s\"\n[[task]]\nid = \"a\"\nrun = \"x\"\n"), 0o600)
	alias := filepath.Join(dir, ".", "dokkit.toml")
	if runtime.GOOS == "windows" {
		alias = strings.ToUpper(p)
	}
	if got := tasks([]string{p, alias}); len(got) != 1 {
		t.Fatalf("the same file twice must not clash with itself: %v", got)
	}
}

func TestATaskThatLeavesSomethingRunningStillSucceeds(t *testing.T) {
	killWait = 500 * time.Millisecond
	run := "sleep 20 & echo done"
	if runtime.GOOS == "windows" {
		run = "start /b ping -n 12 127.0.0.1 & echo done"
	}
	if code := (task{ID: "bg", Run: run, Timeout: "30s", dir: "."}).run(&chunks{}, &chunks{}, nil); code != 0 {
		t.Fatalf("code %d", code)
	}
}

func TestABareNameInTheTasksFolderRuns(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("cmd only")
	}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "hello.bat"), []byte("@echo hi\r\n"), 0o600)
	var out chunks
	if code := (task{ID: "h", Run: "hello.bat", dir: dir}).run(&out, &out, nil); code != 0 {
		t.Fatalf("code %d: %s", code, out.take())
	}
}

func TestHelp(t *testing.T) {
	for _, args := range [][]string{{"help"}, {"--help"}, {"check", "--help"}} {
		if code := cli(args); code != 0 {
			t.Fatalf("%v should exit 0, got %d", args, code)
		}
	}
	for _, tp := range topics {
		if !strings.Contains(usage, "dokkit "+tp.name) || cli([]string{"help", tp.name}) != 0 {
			t.Fatalf("help for %q does not match the usage", tp.name)
		}
	}
	if cli([]string{"help", "nope"}) != 2 {
		t.Fatal("help for an unknown command should exit 2")
	}
}
