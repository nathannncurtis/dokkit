package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func statsWatcher(t *testing.T, url, keyEnv string) *watcher {
	t.Helper()
	dir := t.TempDir()
	file := filepath.Join(dir, "dokkit.toml")
	body := "schema = 1\n[service]\nid = \"portal\"\n[stats]\nurl = \"" + url + "\"\n"
	if keyEnv != "" {
		body += "key_env = \"" + keyEnv + "\"\n"
	}
	os.WriteFile(file, []byte(body), 0o600)
	d, err := readDeclaration(file)
	if err != nil {
		t.Fatal(err)
	}
	return &watcher{c: &client{spool: t.TempDir()}, files: map[string]*declaration{file: d}}
}

func TestAKeyThatIsNotThereMakesNoRequestAndDoesNotMarkTheServiceDown(t *testing.T) {
	var asked atomic.Int32
	app := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { asked.Add(1) }))
	defer app.Close()
	for _, name := range []string{"DOKKIT_STATS_NOT_SET", "HOME"} {
		lines := statsWatcher(t, app.URL, name).stats()
		if len(lines) != 1 {
			t.Fatalf("%s: %v", name, lines)
		}
		if got := lines[0].(map[string]any); got["type"] != "log" || got["service"] != "portal" {
			t.Fatalf("%s: a warning for the service, not a state: %v", name, got)
		}
	}
	if asked.Load() != 0 {
		t.Fatal("a request went out without a key")
	}
}

func TestAnAddressThatAnswersAnErrorIsDown(t *testing.T) {
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer app.Close()
	lines := statsWatcher(t, app.URL, "").stats()
	if got := lines[0].(map[string]any); got["state"] != "down" || got["check"] != "stats" {
		t.Fatalf("%v", got)
	}
}

func TestASlowStatsAddressHoldsNothingBack(t *testing.T) {
	release := make(chan struct{})
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release
		w.Write([]byte(`{"schema":1}`))
	}))
	defer app.Close()
	w := statsWatcher(t, app.URL, "")
	defer func() {
		close(release)
		for end := time.Now().Add(5 * time.Second); w.statsBusy.Load() && time.Now().Before(end); time.Sleep(time.Millisecond) {
		}
	}()
	started := time.Now()
	w.statsSoon()
	w.statsSoon()
	if time.Since(started) > time.Second {
		t.Fatal("the fetch ran inline")
	}
	if !w.statsBusy.Load() {
		t.Fatal("one fetch is under way, and a second does not start")
	}
}

func TestAStatsDocumentFetchedInTheBackgroundIsReported(t *testing.T) {
	app := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"schema":1}`)) }))
	defer app.Close()
	w := statsWatcher(t, app.URL, "")
	w.statsSoon()
	for end := time.Now().Add(5 * time.Second); !w.statsReady.Load() && time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
	}
	if files, _ := filepath.Glob(filepath.Join(w.c.spool, "*.ndjson")); len(files) != 1 {
		t.Fatalf("spooled %v", files)
	}
}
