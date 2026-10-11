package main

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type fakeServer struct {
	mu     sync.Mutex
	got    []string
	posts  int
	answer func(lines []string) (int, string)
}

func (f *fakeServer) serve(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		z, err := gzip.NewReader(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		b, _ := io.ReadAll(z)
		lines := strings.Split(strings.TrimSpace(string(b)), "\n")
		f.mu.Lock()
		defer f.mu.Unlock()
		f.posts++
		status, body := f.answer(lines)
		if status/100 == 2 {
			f.got = append(f.got, lines...)
		}
		w.WriteHeader(status)
		w.Write([]byte(body))
	}))
}

func msgs(lines []string) (out []string) {
	for _, l := range lines {
		var m map[string]any
		json.Unmarshal([]byte(l), &m)
		s, _ := m["msg"].(string)
		out = append(out, s)
	}
	return
}

func logFixture(t *testing.T, text string) (string, string, *client, map[string]int64, *fakeServer) {
	t.Helper()
	f := &fakeServer{answer: func([]string) (int, string) { return 200, `{"accepted":1,"refused":[]}` }}
	srv := f.serve(t)
	t.Cleanup(srv.Close)
	file := filepath.Join(t.TempDir(), "app.log")
	os.WriteFile(file, []byte(text), 0o600)
	spool := t.TempDir()
	return file, spool, &client{url: srv.URL, key: "dkm_x", spool: spool, http: &http.Client{}}, map[string]int64{}, f
}

func aside(t *testing.T, spool string) string {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(spool, "*.rejected"))
	var all strings.Builder
	for _, f := range files {
		b, _ := os.ReadFile(f)
		all.Write(b)
	}
	return all.String()
}

func reported(t *testing.T, spool string) string {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(spool, "*.ndjson"))
	var all strings.Builder
	for _, f := range files {
		b, _ := os.ReadFile(f)
		all.Write(b)
	}
	return all.String()
}

func TestATooLargeLogBatchIsSplitAndNothingIsLost(t *testing.T) {
	var text strings.Builder
	for i := 0; i < 10; i++ {
		fmt.Fprintf(&text, "line %d\n", i)
	}
	file, spool, c, pos, f := logFixture(t, text.String())
	f.answer = func(lines []string) (int, string) {
		if len(lines) > 3 {
			return 413, `{"error":{"code":"too_large"}}`
		}
		return 200, `{"accepted":3,"refused":[]}`
	}
	if !c.sendLog("s", file, pos) {
		t.Fatal("position did not move")
	}
	if got := msgs(f.got); len(got) != 10 || got[0] != "line 0" || got[9] != "line 9" {
		t.Fatalf("delivered %v", got)
	}
	if aside(t, spool) != "" || reported(t, spool) != "" {
		t.Fatal("nothing was lost, so nothing is reported or set aside")
	}
	for _, p := range pos {
		if p != int64(len(text.String())) {
			t.Fatalf("position %d", p)
		}
	}
}

func TestALineOverTheLimitIsCutWithAMarkerAndCounted(t *testing.T) {
	big := strings.Repeat("x", 3*logMsgMax)
	file, spool, c, pos, f := logFixture(t, "before\n"+big+"\nafter\n")
	f.answer = func(lines []string) (int, string) {
		for _, l := range lines {
			if len(l) > 2*logMsgMax {
				return 413, `{}`
			}
		}
		return 200, `{"accepted":1,"refused":[]}`
	}
	c.sendLog("s", file, pos)
	got := msgs(f.got)
	if len(got) != 3 || got[0] != "before" || got[2] != "after" || !strings.HasPrefix(got[1], "xxxx") || !strings.Contains(got[1], "[dokkit cut") || len(got[1]) > logMsgMax+64 {
		t.Fatalf("delivered %d lines, middle %d bytes", len(got), len(got[1]))
	}
	if r := reported(t, spool); !strings.Contains(r, "1 line(s)") || !strings.Contains(r, "cut to") {
		t.Fatalf("the cut is counted and reported: %q", r)
	}
	if aside(t, spool) != "" {
		t.Fatal("a cut line is delivered, not set aside")
	}
}

func TestAMalformedLineIsSetAsideAloneWithItsReason(t *testing.T) {
	file, spool, c, pos, f := logFixture(t, "good one\npoison\ngood two\n")
	f.answer = func(lines []string) (int, string) {
		for _, l := range lines {
			if strings.Contains(l, "poison") {
				return 422, `{"error":{"code":"bad_gzip"}}`
			}
		}
		return 200, `{"accepted":1,"refused":[]}`
	}
	c.sendLog("s", file, pos)
	if got := msgs(f.got); len(got) != 2 || got[0] != "good one" || got[1] != "good two" {
		t.Fatalf("delivered %v", got)
	}
	if a := aside(t, spool); !strings.Contains(a, "poison") || !strings.Contains(a, "reason") || strings.Contains(a, "good") {
		t.Fatalf("set aside: %q", a)
	}
	if !strings.Contains(reported(t, spool), "1 line(s)") {
		t.Fatal("the loss is reported to the server")
	}
	for _, p := range pos {
		if p != int64(len("good one\npoison\ngood two\n")) {
			t.Fatalf("position %d", p)
		}
	}
}

func TestLinesTheServerNamesAsRefusedAreSetAsideAndTheRestKept(t *testing.T) {
	for _, status := range []int{200, 422} {
		file, spool, c, pos, f := logFixture(t, "a\nb\nc\n")
		first := true
		f.answer = func(lines []string) (int, string) {
			if first && len(lines) == 3 {
				first = false
				return status, `{"accepted":2,"refused":[{"line":2,"code":"bad_line","message":"nope"}]}`
			}
			return 200, `{"accepted":2,"refused":[]}`
		}
		c.sendLog("s", file, pos)
		a := aside(t, spool)
		if !strings.Contains(a, `"msg":"b"`) || !strings.Contains(a, "bad_line: nope") || strings.Contains(a, `"msg":"a"`) {
			t.Fatalf("%d: set aside %q", status, a)
		}
		if status == 422 {
			if got := msgs(f.got); strings.Join(got, "") != "ac" {
				t.Fatalf("%d: delivered %v", status, got)
			}
		}
	}
}

func TestAServerErrorNeverSkipsLogLines(t *testing.T) {
	file, spool, c, pos, f := logFixture(t, "keep me\n")
	f.answer = func([]string) (int, string) { return 500, "" }
	for i := 0; i < 8; i++ {
		if c.sendLog("s", file, pos) {
			t.Fatal("moved past lines the server never took")
		}
	}
	if f.posts >= 8 {
		t.Fatalf("no backoff: %d posts", f.posts)
	}
	for _, p := range pos {
		if p != 0 {
			t.Fatalf("position %d", p)
		}
	}
	f.answer = func([]string) (int, string) { return 200, `{"accepted":1,"refused":[]}` }
	c.stuck = nil
	if !c.sendLog("s", file, pos) || len(f.got) != 1 {
		t.Fatalf("delivered %v", f.got)
	}
	if aside(t, spool) != "" {
		t.Fatal("nothing set aside")
	}
}

func TestASpooledBatchTheServerCannotTakeIsSplitNotDeleted(t *testing.T) {
	f := &fakeServer{}
	f.answer = func(lines []string) (int, string) {
		for _, l := range lines {
			if strings.Contains(l, "poison") {
				return 422, `{}`
			}
		}
		if len(lines) > 2 {
			return 413, `{}`
		}
		return 200, `{"accepted":1,"refused":[]}`
	}
	srv := f.serve(t)
	defer srv.Close()
	dir := t.TempDir()
	c := &client{url: srv.URL, key: "dkm_x", spool: dir, http: &http.Client{}}
	spoolFile(t, dir, "00000000000000000001-aaaaaaaa", `{"type":"log","msg":"1"}`+"\n"+`{"type":"log","msg":"2"}`+"\n"+`{"type":"log","msg":"poison"}`+"\n"+`{"type":"log","msg":"4"}`+"\n"+`{"type":"log","msg":"5"}`)
	left, err := c.flush(5e9)
	if left != 0 || err != nil {
		t.Fatalf("left %d, %v", left, err)
	}
	if got := strings.Join(msgs(f.got), ","); got != "1,2,4,5" {
		t.Fatalf("delivered %s", got)
	}
	if a := aside(t, dir); !strings.Contains(a, "poison") || strings.Contains(a, `"msg":"4"`) {
		t.Fatalf("set aside %q", a)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, "00000000000000000001-aaaaaaaa.ndjson")); len(left) != 0 {
		t.Fatal("the spooled file is finished")
	}
}

func TestASpooledBatchStopsWhereAServerErrorFindsItAndKeepsTheRest(t *testing.T) {
	f := &fakeServer{}
	f.answer = func(lines []string) (int, string) {
		if len(lines) > 1 {
			return 413, `{}`
		}
		if strings.Contains(lines[0], `"3"`) {
			return 500, ``
		}
		return 200, `{"accepted":1,"refused":[]}`
	}
	srv := f.serve(t)
	defer srv.Close()
	dir := t.TempDir()
	c := &client{url: srv.URL, key: "dkm_x", spool: dir, http: &http.Client{}}
	spoolFile(t, dir, "00000000000000000001-aaaaaaaa", `{"type":"log","msg":"1"}`+"\n"+`{"type":"log","msg":"2"}`+"\n"+`{"type":"log","msg":"3"}`+"\n"+`{"type":"log","msg":"4"}`)
	left, _ := c.flush(5e9)
	b, _ := os.ReadFile(filepath.Join(dir, "00000000000000000001-aaaaaaaa.ndjson"))
	if left != 1 || strings.Join(msgs(f.got), ",") != "1,2" || strings.Contains(string(b), `"1"`) || !strings.Contains(string(b), `"3"`) || !strings.Contains(string(b), `"4"`) {
		t.Fatalf("left %d, delivered %v, kept %q", left, f.got, b)
	}
}
