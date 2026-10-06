package main

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func spoolFile(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name+".ndjson"), []byte(body+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestFlushSetsAsideABatchTheServerCannotTake(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		z, _ := gzip.NewReader(r.Body)
		b := make([]byte, 64)
		n, _ := z.Read(b)
		if strings.Contains(string(b[:n]), "poison") {
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	c := &client{url: srv.URL, key: "dka_test", spool: dir, http: &http.Client{}}
	spoolFile(t, dir, "00000000000000000001-aaaaaaaa", "poison")
	for i := 0; i < 6; i++ {
		spoolFile(t, dir, "0000000000000000001"+string(rune('0'+i))+"-good", "fine")
		time.Sleep(time.Millisecond)
		c.flush(5 * time.Second)
	}
	left, _ := filepath.Glob(filepath.Join(dir, "*.ndjson"))
	aside, _ := filepath.Glob(filepath.Join(dir, "*.rejected"))
	if len(left) != 0 || len(aside) != 1 {
		t.Fatalf("left %v, set aside %v", left, aside)
	}
}

func TestFlushStopsAtItsDeadline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
	}))
	defer srv.Close()
	dir := t.TempDir()
	c := &client{url: srv.URL, key: "dka_test", spool: dir, http: &http.Client{}}
	for i := 0; i < 20; i++ {
		spoolFile(t, dir, "0000000000000000000"+string(rune('a'+i))+"-x", "x")
	}
	started := time.Now()
	left, _ := c.flush(350 * time.Millisecond)
	if left == 0 || time.Since(started) > time.Second {
		t.Fatalf("left %d after %s", left, time.Since(started))
	}
}

func TestJobsAreReportedUnderTheirService(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \"upload-portal\"\n[[job]]\nid = \"nightly-purge\"\n"), 0o600)
	c := &client{key: "dkm_x", folders: []string{dir}}
	if s := c.job(line{Name: "nightly-purge"}).Service; s != "upload-portal" {
		t.Fatalf("declared job: %q", s)
	}
	if s := c.job(line{Name: "other"}).Service; s != "other" {
		t.Fatalf("undeclared job: %q", s)
	}
	c.service = "named"
	if s := c.job(line{Name: "nightly-purge"}).Service; s != "named" {
		t.Fatalf("--service: %q", s)
	}
	rest, svc := takeService([]string{"run", "--service", "a", "--job", "j", "--", "cmd", "--service", "b"})
	if svc != "a" || strings.Join(rest, " ") != "run --job j -- cmd --service b" {
		t.Fatalf("%q %v", svc, rest)
	}
}

func TestLogLinesKeepToTheFilesServiceAndGetAMessage(t *testing.T) {
	var got []map[string]any
	var batches []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		batches = append(batches, r.Header.Get("Dokkit-Batch"))
		z, _ := gzip.NewReader(r.Body)
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l map[string]any
			json.Unmarshal(s.Bytes(), &l)
			got = append(got, l)
		}
		w.Write([]byte(`{"accepted":1,"refused":[]}`))
	}))
	defer srv.Close()
	dir := t.TempDir()
	file := filepath.Join(dir, "app.log")
	os.WriteFile(file, []byte("{\"message\":\"hello\",\"service\":\"other\"}\n{\"event\":\"started\"}\n{\"n\":1}\n"), 0o600)
	for _, key := range []string{"dkm_one", "dkm_two"} {
		c := &client{url: srv.URL, key: key, spool: t.TempDir(), http: &http.Client{}}
		c.sendLog("portal", file, map[string]int64{})
	}
	if len(got) != 6 || got[0]["msg"] != "hello" || got[0]["service"] != "portal" || got[1]["msg"] != "started" || got[2]["msg"] != `{"n":1}` {
		t.Fatalf("lines: %v", got)
	}
	if f, _ := got[0]["fields"].(map[string]any); f["service"] != "other" {
		t.Fatalf("the line's own service is kept as a field: %v", got[0])
	}
	if len(batches) != 2 || batches[0] == batches[1] {
		t.Fatalf("each machine has its own batch ids: %v", batches)
	}
}

func TestLogLinesThatKeepDrawingAnErrorAreSkipped(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		z, _ := gzip.NewReader(r.Body)
		b := make([]byte, 200)
		n, _ := z.Read(b)
		if strings.Contains(string(b[:n]), "poison") {
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.log")
	os.WriteFile(bad, []byte("poison\n"), 0o600)
	c := &client{url: srv.URL, key: "dkm_x", spool: t.TempDir(), http: &http.Client{}}
	positions := map[string]int64{}
	moved := false
	for i := 0; i < 6 && !moved; i++ {
		if i == 1 {
			os.WriteFile(filepath.Join(dir, "ok.log"), []byte("fine\n"), 0o600)
			c.sendLog("s", filepath.Join(dir, "ok.log"), positions)
		}
		moved = c.sendLog("s", bad, positions)
	}
	if !moved {
		t.Fatal("the bad lines stay forever")
	}
}

func TestTrimReportsWhatItDropped(t *testing.T) {
	dir := t.TempDir()
	c := &client{spool: dir, spoolMB: 1}
	var files []string
	for _, n := range []string{"a", "b", "c"} {
		f := filepath.Join(dir, "0000000000000000000"+n+"-x.ndjson")
		os.WriteFile(f, make([]byte, 600<<10), 0o600)
		files = append(files, f)
	}
	if kept := c.trim(files); len(kept) != 1 {
		t.Fatalf("kept %v", kept)
	}
	found := false
	all, _ := filepath.Glob(filepath.Join(dir, "*.ndjson"))
	for _, f := range all {
		if b, _ := os.ReadFile(f); strings.Contains(string(b), "dropped the 2 oldest") {
			found = true
		}
	}
	if !found {
		t.Fatal("the drop is reported to the server")
	}
}
