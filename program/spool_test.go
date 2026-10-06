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

func TestAResentLogBatchKeepsItsID(t *testing.T) {
	var ids []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ids = append(ids, r.Header.Get("Dokkit-Batch"))
		if len(ids) == 1 {
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	file := filepath.Join(t.TempDir(), "plain.log")
	os.WriteFile(file, []byte("first line\nsecond line\n"), 0o600)
	c := &client{url: srv.URL, key: "dkm_resend", spool: t.TempDir(), http: &http.Client{}}
	positions := map[string]int64{}
	c.sendLog("s", file, positions)
	time.Sleep(2 * time.Millisecond)
	c.sendLog("s", file, positions)
	if len(ids) != 2 || ids[0] != ids[1] {
		t.Fatalf("batch ids: %v", ids)
	}
}

func TestFlushSetsAsideAcrossSeparateProcesses(t *testing.T) {
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
	for _, n := range []string{"1", "2", "3"} {
		spoolFile(t, dir, "0000000000000000000"+n+"-xxxxxxxx", "poison")
	}
	for i := 0; i < 6; i++ {
		spoolFile(t, dir, "0000000000000000001"+string(rune('0'+i))+"-good", "fine")
		c := &client{url: srv.URL, key: "dka_fresh", spool: dir, http: &http.Client{}}
		c.flush(5 * time.Second)
	}
	left, _ := filepath.Glob(filepath.Join(dir, "*.ndjson"))
	aside, _ := filepath.Glob(filepath.Join(dir, "*.rejected"))
	if len(left) != 0 || len(aside) != 3 {
		t.Fatalf("left %v, set aside %v", left, aside)
	}
}

func TestTrimCountsSetAsideBatchesAndFlushClearsOldTempFiles(t *testing.T) {
	dir := t.TempDir()
	c := &client{url: "http://127.0.0.1:1", key: "dka_trim", spool: dir, spoolMB: 1, http: &http.Client{}}
	aside := filepath.Join(dir, "00000000000000000001-a.ndjson.rejected")
	keep := filepath.Join(dir, "00000000000000000002-b.ndjson")
	os.WriteFile(aside, make([]byte, 600<<10), 0o600)
	os.WriteFile(keep, make([]byte, 600<<10), 0o600)
	if kept := c.trim([]string{keep}); len(kept) != 1 {
		t.Fatalf("kept %v", kept)
	}
	if _, err := os.Stat(aside); err == nil {
		t.Fatal("the set-aside batch goes first")
	}
	tmp := filepath.Join(dir, "00000000000000000003-c.ndjson.tmp")
	os.WriteFile(tmp, []byte("x"), 0o600)
	old := time.Now().Add(-time.Hour)
	os.Chtimes(tmp, old, old)
	c.flush(time.Second)
	if _, err := os.Stat(tmp); err == nil {
		t.Fatal("an old temp file stays")
	}
}

func TestLogLinesKeepAFieldsValueAndAClefService(t *testing.T) {
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		z, _ := gzip.NewReader(r.Body)
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l map[string]any
			json.Unmarshal(s.Bytes(), &l)
			got = append(got, l)
		}
	}))
	defer srv.Close()
	file := filepath.Join(t.TempDir(), "mixed.log")
	os.WriteFile(file, []byte("{\"msg\":\"a\",\"service\":\"x\",\"fields\":\"text\"}\n{\"@m\":\"b\",\"service\":\"y\"}\n"), 0o600)
	c := &client{url: srv.URL, key: "dkm_fields", spool: t.TempDir(), http: &http.Client{}}
	c.sendLog("portal", file, map[string]int64{})
	if len(got) != 2 {
		t.Fatalf("lines: %v", got)
	}
	if f, _ := got[0]["fields"].(map[string]any); f["service"] != "x" || f["fields"] != "text" {
		t.Fatalf("fields: %v", got[0])
	}
	if got[1]["service_name"] != "y" || got[1]["service"] != "portal" {
		t.Fatalf("clef: %v", got[1])
	}
}

func TestAJobNamedByTwoServicesIsNotGuessed(t *testing.T) {
	root := t.TempDir()
	for _, s := range []string{"ambig-one", "ambig-two"} {
		os.Mkdir(filepath.Join(root, s), 0o700)
		os.WriteFile(filepath.Join(root, s, "dokkit.toml"), []byte("schema = 1\n[service]\nid = \""+s+"\"\n[[job]]\nid = \"ambig-backup\"\n"), 0o600)
	}
	c := &client{key: "dkm_x", folders: []string{root}}
	if s := c.job(line{Name: "ambig-backup"}).Service; s != "ambig-backup" {
		t.Fatalf("guessed %q", s)
	}
}
