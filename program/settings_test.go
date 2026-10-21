package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func pullSettings(t *testing.T, body string) {
	t.Helper()
	all := []*setting{beatEvery, recordEvery, scanFirst, scanEvery, checkEvery, checkTimeout, restartGap, expiryWarn}
	saved := make([]time.Duration, len(all))
	for i, s := range all {
		saved[i] = s.get()
	}
	t.Cleanup(func() {
		for i, s := range all {
			s.set(saved[i])
		}
	})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(body)) }))
	defer srv.Close()
	(&watcher{c: &client{url: srv.URL, key: "k", spool: t.TempDir(), http: &http.Client{}}}).pull()
}

func TestPulledSettingsAreUsed(t *testing.T) {
	pullSettings(t, `{"items":[],"settings":{"report_seconds":20,"scan_first_seconds":7,"scan_every_seconds":3600,
		"check_every_seconds":90,"check_timeout_seconds":2,"expiry_days":10,"restart_gap_seconds":60}}`)
	for name, got := range map[string][2]time.Duration{
		"beat": {beatEvery.get(), 20 * time.Second}, "record": {recordEvery.get(), 20 * time.Second},
		"scan first": {scanFirst.get(), 7 * time.Second}, "scan every": {scanEvery.get(), time.Hour},
		"every": {(&check{}).every(), 90 * time.Second}, "timeout": {(&check{}).timeout(), 2 * time.Second},
		"restart gap": {restartGap.get(), time.Minute},
	} {
		if got[0] != got[1] {
			t.Errorf("%s: %v, want %v", name, got[0], got[1])
		}
	}
	if (&check{Type: "expiry"}).every() != time.Hour {
		t.Error("an expiry check keeps its hour")
	}
	at := time.Now()
	if r := expiryResult(at.Add(15*24*time.Hour), at); !r.ok {
		t.Errorf("15 days out is fine with a 10-day warning: %+v", r)
	}
	if r := expiryResult(at.Add(9*24*time.Hour), at); r.state != "degraded" {
		t.Errorf("%+v", r)
	}
}

func TestNoSettingsKeepTodaysValues(t *testing.T) {
	pullSettings(t, `{"items":[],"settings":{"report_seconds":0,"expiry_days":0}}`)
	pullSettings(t, `{"items":[]}`)
	if beatEvery.get() != time.Minute || recordEvery.get() != time.Minute || scanFirst.get() != 2*time.Minute || scanEvery.get() != 24*time.Hour ||
		(&check{}).every() != 30*time.Second || (&check{}).timeout() != 5*time.Second || restartGap.get() != 10*time.Minute {
		t.Fatal("a missing setting changed a value")
	}
	at := time.Now()
	if r := expiryResult(at.Add(20*24*time.Hour), at); r.state != "degraded" {
		t.Fatalf("%+v", r)
	}
}

func TestRestartGapComesFromTheServer(t *testing.T) {
	pullSettings(t, `{"items":[],"settings":{"restart_gap_seconds":1}}`)
	restartedMu.Lock()
	restarted = map[string]time.Time{"gap-svc": time.Now().Add(-2 * time.Second)}
	restartedMu.Unlock()
	old := startService
	startService = func(string) error { return nil }
	t.Cleanup(func() { startService = old; restarted = map[string]time.Time{} })
	if !(&check{Type: "windows-service", Name: "gap-svc", restart: true}).tryRestart() {
		t.Fatal("a one-second gap had passed")
	}
}
