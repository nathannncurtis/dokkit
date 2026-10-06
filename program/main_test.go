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
	if inventory["type"] != "inventory" || inventory["dokkit"] != version {
		t.Fatalf("inventory: %v", inventory)
	}
	if l := c.job(line{Name: "backup", Event: "ok"}); l.Service != "backup" || l.Type != "job" {
		t.Fatalf("a machine key names the job as a service: %+v", l)
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
