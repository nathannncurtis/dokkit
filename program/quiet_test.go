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
)

func quietRun(t *testing.T, url string, args ...string) (int, string, string, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DOKKIT_URL", url)
	t.Setenv("DOKKIT_KEY", "dkm_test")
	t.Setenv("DOKKIT_SPOOL", dir)
	t.Setenv("DOKKIT_CONFIG", filepath.Join(dir, "none.json"))
	var code int
	out, errs := capture(t, func() { code = cli(append([]string{"quiet"}, args...)) })
	return code, out, errs, dir
}

func TestQuietTellsTheServerAndSaysSo(t *testing.T) {
	var order []string
	var got map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		order = append(order, r.URL.Path)
		if r.URL.Path == "/api/v1/quiet" {
			b, _ := io.ReadAll(r.Body)
			json.Unmarshal(b, &got)
			if r.Header.Get("Authorization") != "Bearer dkm_test" {
				t.Errorf("key not sent")
			}
			w.Write([]byte(`{"ok":true,"until":"2026-10-12T03:20:00.000000Z"}`))
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	spoolFile(t, dir, "00000000000000000001-aaaaaaaa", "waiting")
	t.Setenv("DOKKIT_SPOOL", dir)
	t.Setenv("DOKKIT_URL", srv.URL)
	t.Setenv("DOKKIT_KEY", "dkm_test")
	t.Setenv("DOKKIT_CONFIG", filepath.Join(dir, "none.json"))
	var code int
	out, _ := capture(t, func() { code = cli([]string{"quiet", "20m", "nightly", "update"}) })
	if code != 0 || out != "Told the server this machine is down on purpose until 03:20 UTC.\n" {
		t.Fatalf("code %d, out %q", code, out)
	}
	if len(order) != 2 || order[0] != "/api/v1/report" || order[1] != "/api/v1/quiet" {
		t.Fatalf("the spool should go first: %v", order)
	}
	if got["for"] != "20m" || got["reason"] != "nightly update" {
		t.Fatalf("sent %v", got)
	}
}

func TestQuietEndAsksForZero(t *testing.T) {
	var got map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/quiet" {
			b, _ := io.ReadAll(r.Body)
			json.Unmarshal(b, &got)
			w.Write([]byte(`{"ok":true,"until":null}`))
		}
	}))
	defer srv.Close()
	code, out, _, _ := quietRun(t, srv.URL, "end")
	if code != 0 || got["for"] != "0" || !strings.Contains(out, "planned downtime is over") {
		t.Fatalf("code %d, sent %v, out %q", code, got, out)
	}
}

func TestQuietFailsWhenTheServerCannotBeReached(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	code, out, errs, _ := quietRun(t, url, "20m")
	if code != 1 || out != "" || !strings.Contains(errs, "the server was not told") {
		t.Fatalf("code %d, out %q, err %q", code, out, errs)
	}
}

func TestQuietPassesOnWhatTheServerRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/quiet" {
			w.WriteHeader(422)
			w.Write([]byte(`{"error":{"code":"bad_duration","message":"for is a duration up to 4h, such as 15m, or 0 to end it."}}`))
		}
	}))
	defer srv.Close()
	code, out, errs, _ := quietRun(t, srv.URL, "9h")
	if code != 1 || out != "" || !strings.Contains(errs, "(422): for is a duration up to 4h") {
		t.Fatalf("code %d, out %q, err %q", code, out, errs)
	}
}

func TestQuietNeedsALength(t *testing.T) {
	code, _, errs, _ := quietRun(t, "http://127.0.0.1:1")
	if code != 2 || !strings.Contains(errs, "needs a length") {
		t.Fatalf("code %d, err %q", code, errs)
	}
	_ = os.Stderr
}
