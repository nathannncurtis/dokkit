package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestExpiryCountsWholeDaysAndASelfSignedCertificateIsRead(t *testing.T) {
	at := time.Now()
	if r := expiryResult(at.Add(-time.Hour), at); r.state != "down" {
		t.Fatalf("a date an hour past is down: %+v", r)
	}
	if r := expiryResult(at.Add(10*time.Hour), at); r.state != "degraded" || r.value != 0 {
		t.Fatalf("ten hours left is degraded with 0 days: %+v", r)
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
	if _, err := readDeclaration(file); err == nil {
		t.Fatal("key_env outside the stats prefix is refused")
	}
}

func TestPulledChecksNeedThisMachinesLeave(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"items":[
			{"service":"s","name":"allowed-svc","type":"windows-service","restart":true,"config":{"name":"Allowed-Svc"}},
			{"service":"s","name":"other-svc","type":"windows-service","restart":true,"config":{"name":"Other"}},
			{"service":"s","name":"far","type":"tcp","config":{"host":"10.9.9.9","port":1}},
			{"service":"s","name":"named","type":"tcp","config":{"host":"db.example","port":1}},
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
	if len(got) != 4 || !got["allowed-svc"] || got["other-svc"] {
		t.Fatalf("only a named service is started: %v", got)
	}
	if _, ok := got["far"]; ok {
		t.Fatal("a host nobody named is not reached")
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
