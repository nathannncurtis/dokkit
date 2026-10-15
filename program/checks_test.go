package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestExpiryCountsWholeDaysAndASelfSignedCertificateIsRead(t *testing.T) {
	at := time.Now()
	if r := expiryResult(at.Add(-time.Hour), at); r.state != "down" {
		t.Fatalf("a date an hour past is down: %+v", r)
	}
	if r := expiryResult(at.Add(10*time.Hour), at); r.state != "degraded" || r.value != 1 {
		t.Fatalf("ten hours left is degraded and shows 1 day: %+v", r)
	}
	for _, left := range []time.Duration{30 * 24 * time.Hour, 29*24*time.Hour + 12*time.Hour, 30*24*time.Hour - time.Minute} {
		if r := expiryResult(at.Add(left), at); r.state != "degraded" {
			t.Fatalf("%s left is within 30 days: %+v", left, r)
		}
	}
	if r := expiryResult(at.Add(30*24*time.Hour+time.Minute), at); !r.ok || r.value != 31 {
		t.Fatalf("just over 30 days is fine: %+v", r)
	}
	if r := expiryResult(at.Add(40*24*time.Hour), at); !r.ok {
		t.Fatalf("forty days is fine: %+v", r)
	}
	srv := httptest.NewTLSServer(http.NotFoundHandler())
	defer srv.Close()
	c := &check{Type: "expiry", DateFrom: strings.TrimPrefix(srv.URL, "https://")}
	if r := c.run(); r.state == "down" || r.note != "" {
		t.Fatalf("a self-signed certificate is read: %+v", r)
	}
}

func TestDiskUseIsWorkedOutFromBytes(t *testing.T) {
	used, ok := diskUsed(found{"total_bytes": "2040109466", "free_bytes": "966367641"})
	if !ok || used < 52 || used > 53 {
		t.Fatalf("a 1.9 GB disk with 0.9 GB free is 52%% used, was %v", used)
	}
}

func TestFilesAndKeysStayWhereTheFileAllows(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "app")
	os.Mkdir(dir, 0o700)
	os.WriteFile(filepath.Join(root, "secret.log"), []byte("secret\n"), 0o600)
	os.WriteFile(filepath.Join(root, "VERSION"), []byte("9.9\n"), 0o600)
	os.WriteFile(filepath.Join(dir, "own.log"), []byte("mine\n"), 0o600)
	file := filepath.Join(dir, "dokkit.toml")
	os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"app\"\nversion_from = \"../VERSION\"\n[logs]\npath = \"../*.log\"\n"), 0o600)
	d, err := readDeclaration(file)
	if err != nil {
		t.Fatal(err)
	}
	w := &watcher{files: map[string]*declaration{file: d}}
	if v := w.versions(); len(v) != 0 {
		t.Fatalf("a version outside the folder is not read: %v", v)
	}
	if within(dir, filepath.Join(root, "secret.log")) || !within(dir, filepath.Join(dir, "own.log")) {
		t.Fatal("only what is inside the folder is inside")
	}
	c := &check{Type: "expiry", DateFrom: filepath.Join(root, "VERSION"), dir: dir}
	if _, err := c.expires(); err == nil {
		t.Fatal("a date file outside the folder is not read")
	}
	os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"app\"\n[stats]\nurl = \"http://x\"\nkey_env = \"PATH\"\n"), 0o600)
	d, err = readDeclaration(file)
	if err != nil {
		t.Fatal("the file is kept; only the key is refused:", err)
	}
	if line := fetchStats(d).(map[string]any); line["type"] != "log" || line["level"] != "warn" || !strings.Contains(line["msg"].(string), statsKeyPrefix) {
		t.Fatalf("key_env outside the stats prefix is reported: %v", line)
	}
	day := filepath.Join(dir, "when")
	os.WriteFile(day, []byte(time.Now().UTC().Format("2006-01-02")+"\n"), 0o600)
	c = &check{Type: "expiry", DateFrom: "when", dir: dir}
	if until, err := c.expires(); err != nil || expiryResult(until, time.Now()).state == "down" {
		t.Fatalf("a date is good through its own day: %v %v", until, err)
	}
}

func TestPulledChecksNeedThisMachinesLeave(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"items":[
			{"service":"s","name":"allowed-svc","type":"windows-service","restart":true,"config":{"name":"Allowed-Svc"}},
			{"service":"s","name":"other-svc","type":"windows-service","restart":true,"config":{"name":"Other"}},
			{"service":"s","name":"far","type":"tcp","config":{"host":"10.9.9.9","port":1}},
			{"service":"s","name":"named","type":"tcp","config":{"host":"db.example","port":1}},
			{"service":"s","name":"spoof","type":"tcp","config":{"host":"127.example.com","port":1}},
			{"service":"s","name":"near","type":"tcp","config":{"host":"localhost","port":1}}]}`))
	}))
	defer srv.Close()
	c := &client{url: srv.URL, key: "k", spool: t.TempDir(), http: &http.Client{}, restartable: []string{"Allowed-Svc"}, hosts: []string{"db.example"}}
	w := &watcher{c: c}
	w.pull()
	got := map[string]bool{}
	for _, d := range w.added {
		got[d.Check[0].name] = d.Check[0].restart
	}
	if !got["allowed-svc"] || got["other-svc"] {
		t.Fatalf("only a named service is started: %v", got)
	}
	for _, name := range []string{"far", "spoof"} {
		for _, d := range w.added {
			if c := d.Check[0]; c.name == name && c.run().state != "down" || c.name == name && c.refused == "" {
				t.Fatalf("a host nobody named is refused and reported: %s", name)
			}
		}
	}
	if _, ok := got["named"]; !ok {
		t.Fatal("a host the configuration names is")
	}
}

func TestChecksRunAtOnce(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { time.Sleep(300 * time.Millisecond) }))
	defer slow.Close()
	d := &declaration{}
	d.Service.ID = "slow"
	for range 4 {
		d.Check = append(d.Check, check{Type: "http", URL: slow.URL})
	}
	w := &watcher{c: &client{spool: t.TempDir()}, files: map[string]*declaration{"f": d}}
	start := time.Now()
	if ran := w.tick(start); ran != 4 {
		t.Fatalf("ran %d", ran)
	}
	if took := time.Since(start); took > 900*time.Millisecond {
		t.Fatalf("four 300 ms checks one after another took %v", took)
	}
}

func TestASlowAnswerIsDegradedNotDown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { time.Sleep(150 * time.Millisecond) }))
	defer srv.Close()
	r := (&check{Type: "http", URL: srv.URL, Slow: "50ms"}).run()
	if r.ok || r.state != "degraded" || r.value < 150 || !strings.Contains(r.note, "slower than 0.05 s") {
		t.Fatalf("a slow answer is degraded and keeps its time: %+v", r)
	}
	if r := (&check{Type: "http", URL: srv.URL, Slow: "5s"}).run(); !r.ok {
		t.Fatalf("a quick enough answer is fine: %+v", r)
	}
	if r := (&check{Type: "http", URL: srv.URL}).run(); !r.ok {
		t.Fatalf("with no slow, nothing changes: %+v", r)
	}
	if _, err := (&check{Type: "http", URL: srv.URL, Slow: "soon"}).problem(); err == nil {
		t.Fatal("slow must be a time such as 2s")
	}
}

func TestADeclarationWithoutSchemaSaysWhatToDo(t *testing.T) {
	file := filepath.Join(t.TempDir(), "dokkit.toml")
	os.WriteFile(file, []byte("[service]\nid = \"app\"\n"), 0o600)
	if _, err := readDeclaration(file); err == nil || err.Error() != "add schema = 1 as the first line." {
		t.Fatalf("got %v", err)
	}
}

func TestAProcessWithALongNameIsCountedWithoutCommandHas(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the long-name cut is a Linux and macOS one")
	}
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip(err)
	}
	b, _ := os.ReadFile(sleep)
	long := filepath.Join(t.TempDir(), "dokkit-long-process-name")
	os.WriteFile(long, b, 0o755)
	cmd := exec.Command(long, "5")
	if err := cmd.Start(); err != nil {
		t.Skip(err)
	}
	defer cmd.Process.Kill()
	time.Sleep(200 * time.Millisecond)
	if n, err := processCount("dokkit-long-process-name", ""); err != nil || n != 1 {
		t.Fatalf("%d %v", n, err)
	}
}

func TestChecksAddedInTheInterfaceKeepTheirSettingsAndTheirTime(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"items":[
			{"service":"s","name":"workers","type":"process","config":{"name":"python","command_has":"worker.py","at_least":3,"every":"10m"}},
			{"service":"s","name":"web","type":"http","config":{"url":"http://localhost:1/","status":[401,"200-299"]}},
			{"service":"s","name":"cert","type":"expiry","config":{"date_from":"localhost:443"}}]}`))
	}))
	defer srv.Close()
	w := &watcher{c: &client{url: srv.URL, key: "k", spool: t.TempDir(), http: &http.Client{}}}
	w.pull()
	got := map[string]check{}
	for _, d := range w.added {
		got[d.Check[0].name] = d.Check[0]
	}
	if c := got["workers"]; c.CommandHas != "worker.py" || c.AtLeast != 3 {
		t.Fatalf("%+v", c)
	}
	if c := got["cert"]; c.DateFrom != "localhost:443" {
		t.Fatalf("%+v", c)
	}
	if r, err := statusRanges(got["web"].Status); err != nil || len(r) != 2 || r[0] != [2]int{401, 401} {
		t.Fatalf("%v %v", r, err)
	}
	if _, err := statusRanges(float64(401.5)); err == nil {
		t.Fatal("a fraction is not a status")
	}
	at := time.Now()
	w.tick(at)
	w.pull()
	for _, d := range w.added {
		if c := d.Check[0]; c.name == "workers" && !c.next.Equal(at.Add(10*time.Minute)) {
			t.Fatalf("pulling again ran it early: %v", c.next)
		}
	}
}

func TestAFilePathIsNotACertificateAddress(t *testing.T) {
	for from, want := range map[string]string{`C:\apps\x.txt`: "", "C:x.txt": "", "host:8443": "host:8443", "https://host": "host:443"} {
		if got := (&check{DateFrom: from}).certAddr(); got != want {
			t.Errorf("%q gave %q", from, got)
		}
	}
}
