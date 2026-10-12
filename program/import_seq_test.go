package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeEvent struct {
	id    string
	at    time.Time
	level string
	msg   string
	props map[string]any
	exc   string
}

type fakeSeq struct {
	mu     sync.Mutex
	events []fakeEvent
	key    string
	reads  int
	down   int
}

func (f *fakeSeq) add(e fakeEvent) {
	f.mu.Lock()
	f.events = append(f.events, e)
	f.mu.Unlock()
}

func (f *fakeSeq) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/api/events" || r.Header.Get("X-Seq-ApiKey") != f.key {
		w.WriteHeader(401)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down > 0 {
		f.down--
		w.WriteHeader(503)
		return
	}
	f.reads++
	q := r.URL.Query()
	count, _ := strconv.Atoi(q.Get("count"))
	from, _ := time.Parse(time.RFC3339Nano, q.Get("fromDateUtc"))
	to, _ := time.Parse(time.RFC3339Nano, q.Get("toDateUtc"))
	var in []fakeEvent
	for _, e := range f.events {
		if !e.at.Before(from) && e.at.Before(to) {
			in = append(in, e)
		}
	}
	sort.Slice(in, func(i, j int) bool { return in[i].id > in[j].id })
	if after := q.Get("afterId"); after != "" {
		i := 0
		for i < len(in) && in[i].id >= after {
			i++
		}
		in = in[i:]
	}
	if len(in) > count {
		in = in[:count]
	}
	out := []map[string]any{}
	for _, e := range in {
		props := []map[string]any{}
		for k, v := range e.props {
			props = append(props, map[string]any{"Name": k, "Value": v})
		}
		ev := map[string]any{"Id": e.id, "Timestamp": e.at.Format("2006-01-02T15:04:05.0000000Z07:00"), "Properties": props, "EventType": "$1"}
		if e.level != "" {
			ev["Level"] = e.level
		}
		if q.Get("render") == "true" {
			ev["RenderedMessage"] = e.msg
		}
		if e.exc != "" {
			ev["Exception"] = e.exc
		}
		out = append(out, ev)
	}
	json.NewEncoder(w).Encode(out)
}

type fakeDokkit struct {
	mu      sync.Mutex
	lines   map[string][]map[string]any
	batches []string
	fail    int
	slow    int
	down    int
}

func (d *fakeDokkit) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.down > 0 {
		d.down--
		w.WriteHeader(503)
		return
	}
	if d.slow > 0 {
		d.slow--
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(429)
		return
	}
	if d.fail > 0 {
		d.fail--
		w.WriteHeader(400)
		fmt.Fprint(w, `{"error":{"code":"x"}}`)
		return
	}
	key := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	d.batches = append(d.batches, r.Header.Get("Dokkit-Batch"))
	sc := bufio.NewScanner(r.Body)
	sc.Buffer(nil, 1<<20)
	n := 0
	for sc.Scan() {
		var l map[string]any
		json.Unmarshal(sc.Bytes(), &l)
		d.lines[key] = append(d.lines[key], l)
		n++
	}
	fmt.Fprintf(w, `{"accepted":%d,"refused":[]}`, n)
}

var seqNow = time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)

func ev(n int, ago time.Duration, msg string, props map[string]any) fakeEvent {
	return fakeEvent{id: fmt.Sprintf("event-%08d", n), at: seqNow.Add(-ago), msg: msg, props: props, level: "Information"}
}

func setup(t *testing.T) (*fakeSeq, *fakeDokkit, []string) {
	seq := &fakeSeq{key: "readkey"}
	dk := &fakeDokkit{lines: map[string][]map[string]any{}}
	ss := httptest.NewServer(seq)
	ds := httptest.NewServer(dk)
	t.Cleanup(ss.Close)
	t.Cleanup(ds.Close)
	dir := t.TempDir()
	mapping := filepath.Join(dir, "map.json")
	os.WriteFile(mapping, []byte(`{"Upload":{"service":"upload-portal","key":"dka_upload"},"Puller":{"service":"puller","key":"dka_puller"}}`), 0o600)
	args := []string{"--from", ss.URL, "--seq-key", "readkey", "--to", ds.URL, "--map", mapping,
		"--default-service", "misc", "--key", "dka_misc", "--app-pattern", `^\[([a-z-]+)\] `,
		"--state", filepath.Join(dir, "state.json"), "--rate", "100000"}
	return seq, dk, args
}

func runImport(t *testing.T, args []string, extra ...string) (string, error) {
	var out bytes.Buffer
	im, err := parseSeqImport(append(args, extra...), &out)
	if err != nil {
		t.Fatal(err)
	}
	im.now = seqNow
	im.wait = func(time.Duration) {}
	err = im.run()
	return out.String(), err
}

func seed(seq *fakeSeq) {
	d := 24 * time.Hour
	seq.add(ev(1, 400*d, "ancient upload", map[string]any{"Application": "Upload"}))
	seq.add(ev(2, 40*d, "saved a.pdf", map[string]any{"Application": "Upload", "File": "a.pdf"}))
	seq.add(ev(3, 40*d, "same instant", map[string]any{"Application": "Puller"}))
	seq.add(ev(4, 20*d, "[puller] pulled 3", nil))
	seq.add(ev(5, 10*d, "nobody", nil))
	seq.add(ev(6, 10*d-time.Hour, "other app", map[string]any{"Application": "Mailer"}))
	e := ev(7, 2*time.Hour, "failed", map[string]any{"Application": "Upload"})
	e.level, e.exc = "Error", "boom\n at x"
	seq.add(e)
}

func TestDryRunCountsAndWritesNothing(t *testing.T) {
	seq, dk, args := setup(t)
	seed(seq)
	out, err := runImport(t, args, "--dry-run")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Would import 6 events", "upload-portal", "puller", "misc", "2025-09", "2026-09", "more than 364 days old (Dokkit stamps a line that old with its arrival time): 1"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if len(dk.lines) != 0 || len(dk.batches) != 0 {
		t.Error("a dry run wrote")
	}
	if _, err := os.Stat(args[len(args)-3]); err == nil {
		t.Error("a dry run kept a state")
	}
}

func TestImportRoutesKeepsTimesAndResumes(t *testing.T) {
	seq, dk, args := setup(t)
	seed(seq)
	out, err := runImport(t, args)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "Imported 6 events") {
		t.Fatal(out)
	}
	up := dk.lines["dka_upload"]
	if len(up) != 2 || up[0]["msg"] != "saved a.pdf" || up[1]["level"] != "error" {
		t.Fatalf("upload lines: %v", up)
	}
	if up[0]["t"] != seqNow.Add(-40*24*time.Hour).Format(time.RFC3339Nano) {
		t.Errorf("time not kept: %v", up[0]["t"])
	}
	if f := up[1]["fields"].(map[string]any); f["exception"] != "boom\n at x" {
		t.Errorf("exception: %v", f)
	}
	if pu := dk.lines["dka_puller"]; len(pu) != 2 || pu[0]["msg"] != "same instant" || pu[1]["msg"] != "[puller] pulled 3" {
		t.Errorf("puller lines: %v", pu)
	}
	mi := dk.lines["dka_misc"]
	if len(mi) != 2 || mi[1]["fields"].(map[string]any)["service_name"] != "Mailer" {
		t.Errorf("default lines: %v", mi)
	}
	for _, id := range dk.batches {
		if len(id) != 36 {
			t.Errorf("batch id %q", id)
		}
	}

	before := len(dk.batches)
	seq.add(ev(8, time.Hour, "new one", map[string]any{"Application": "Upload"}))
	out, err = runImport(t, args)
	if err != nil || !strings.Contains(out, "Imported 1 events") {
		t.Fatalf("second run: %v\n%s", err, out)
	}
	if len(dk.batches) != before+1 || len(dk.lines["dka_upload"]) != 3 {
		t.Errorf("a second run sent more than what is new")
	}
	out, _ = runImport(t, args)
	if !strings.Contains(out, "Imported 0 events") {
		t.Errorf("third run: %s", out)
	}
}

func TestStoppedImportContinues(t *testing.T) {
	seq, dk, args := setup(t)
	seed(seq)
	dk.slow = 1
	seq.add(ev(9, 30*24*time.Hour, "late arrival", map[string]any{"Application": "Upload"}))
	if _, err := runImport(t, args); err != nil {
		t.Fatal(err)
	}
	if got := len(dk.lines["dka_upload"]); got != 3 {
		t.Fatalf("upload lines %d, want 3 after a 429", got)
	}

	seq2, dk2, args2 := setup(t)
	seed(seq2)
	dk2.fail = 1
	if _, err := runImport(t, args2); err == nil {
		t.Fatal("a refused batch should stop the import")
	}
	if _, err := runImport(t, args2); err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, l := range dk2.lines {
		total += len(l)
	}
	if total != 6 {
		t.Errorf("after a stop and a restart %d lines, want 6", total)
	}
}

func TestSeqRefusalIsSaid(t *testing.T) {
	seq, _, args := setup(t)
	seed(seq)
	seq.key = "other"
	if _, err := runImport(t, args); err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("err %v", err)
	}
}

func runQuiet(t *testing.T, args []string) (out, errs string, waited time.Duration, err error) {
	var o, e bytes.Buffer
	im, perr := parseSeqImport(args, &o)
	if perr != nil {
		t.Fatal(perr)
	}
	im.now = seqNow
	im.errOut = &e
	im.wait = func(d time.Duration) { waited += d }
	err = im.run()
	return o.String(), e.String(), waited, err
}

func TestServerRestartIsWaitedOut(t *testing.T) {
	seq, dk, args := setup(t)
	seed(seq)
	dk.down = 4
	out, errs, waited, err := runQuiet(t, args)
	if err != nil {
		t.Fatal(err)
	}
	if waited == 0 || !strings.Contains(errs, "sending to the Dokkit server failed (answered 503)") {
		t.Errorf("waited %v, stderr %q", waited, errs)
	}
	if !strings.Contains(out, "Imported 6 events.") || !strings.Contains(out, "events sent, reached ") {
		t.Errorf("output %q", out)
	}
}

func TestSeqOutageIsWaitedOut(t *testing.T) {
	seq, _, args := setup(t)
	seed(seq)
	seq.down = 3
	_, errs, _, err := runQuiet(t, args)
	if err != nil || !strings.Contains(errs, "reading from Seq failed (answered 503)") {
		t.Fatalf("err %v, stderr %q", err, errs)
	}
}

func TestGivingUpSaysWhichSideAndHowToContinue(t *testing.T) {
	seq, dk, args := setup(t)
	seed(seq)
	dk.down = 1 << 30
	_, _, waited, err := runQuiet(t, args)
	if waited < 10*time.Minute {
		t.Errorf("gave up after %v", waited)
	}
	for _, want := range []string{"sending to the Dokkit server failed", "503", "run the same command again"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("err %v lacks %q", err, want)
		}
	}

	seq2, _, args2 := setup(t)
	seed(seq2)
	seq2.down = 1 << 30
	if _, _, _, err := runQuiet(t, args2); err == nil || !strings.Contains(err.Error(), "reading from Seq failed") {
		t.Fatalf("err %v", err)
	}
}

func TestBatchIDIsStable(t *testing.T) {
	a := batchID("http://s", "k", "event-1", 5)
	if a != batchID("http://s", "k", "event-1", 5) || a == batchID("http://s", "k", "event-2", 5) {
		t.Error("batch id")
	}
	if len(a) != 36 || a[14] != '5' {
		t.Error(a)
	}
}
