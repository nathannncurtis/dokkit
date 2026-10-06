package main

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func logSink(t *testing.T) (*client, *[]string) {
	var lines []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		z, _ := gzip.NewReader(r.Body)
		s := bufio.NewScanner(z)
		for s.Scan() {
			var l map[string]any
			json.Unmarshal(s.Bytes(), &l)
			lines = append(lines, l["msg"].(string))
		}
	}))
	t.Cleanup(srv.Close)
	return &client{url: srv.URL, key: "dkm_keys", spool: t.TempDir(), http: &http.Client{}}, &lines
}

func appendTo(t *testing.T, path, text string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(text)
	f.Close()
}

func TestTwoLogFilesWithTheSameFirstLineKeepTheirOwnPositions(t *testing.T) {
	c, lines := logSink(t)
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a.log"), filepath.Join(dir, "b.log")
	os.WriteFile(a, []byte("#Fields: time\na1\na2\n"), 0o600)
	os.WriteFile(b, []byte("#Fields: time\nb1\nb2\nb3\n"), 0o600)
	positions := map[string]int64{}
	for pass, order := range [][]string{{a, b}, {b, a}, {a, b}, {b, a}} {
		if pass == 2 {
			appendTo(t, a, "a3\n")
			appendTo(t, b, "b4\n")
		}
		for _, f := range order {
			c.sendLog("s", f, positions)
		}
	}
	slices.Sort(*lines)
	want := "#Fields: time,#Fields: time,a1,a2,a3,b1,b2,b3,b4"
	if got := strings.Join(*lines, ","); got != want {
		t.Fatalf("lines: %s", got)
	}
}

func TestARenamedLogFileIsStillFollowed(t *testing.T) {
	c, lines := logSink(t)
	dir := t.TempDir()
	a := filepath.Join(dir, "a.log")
	os.WriteFile(a, []byte("banner\none\n"), 0o600)
	positions := map[string]int64{}
	c.sendLog("s", a, positions)
	appendTo(t, a, "two\n")
	moved := filepath.Join(dir, "a.1.log")
	os.Rename(a, moved)
	c.sendLog("s", moved, positions)
	if got := strings.Join(*lines, ","); got != "banner,one,two" {
		t.Fatalf("lines: %s", got)
	}
}

func TestDeletingOneOfTwoSameHeaderFilesDoesNotMoveTheOther(t *testing.T) {
	c, lines := logSink(t)
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a.log"), filepath.Join(dir, "b.log")
	os.WriteFile(a, []byte("#H\na1\na2\na3\n"), 0o600)
	os.WriteFile(b, []byte("#H\nb1\n"), 0o600)
	positions := map[string]int64{}
	c.sendLog("s", a, positions)
	c.sendLog("s", b, positions)
	os.Remove(a)
	appendTo(t, b, "b2\n")
	c.sendLog("s", b, positions)
	slices.Sort(*lines)
	if got := strings.Join(*lines, ","); got != "#H,#H,a1,a2,a3,b1,b2" {
		t.Fatalf("lines: %s", got)
	}
}

func TestAPositionSavedUnderTheFirstLineAloneIsTakenOver(t *testing.T) {
	c, lines := logSink(t)
	a := filepath.Join(t.TempDir(), "a.log")
	os.WriteFile(a, []byte("#H\none\ntwo\n"), 0o600)
	sum := sha256Of("#H")
	positions := map[string]int64{sum: int64(len("#H\none\n"))}
	c.sendLog("s", a, positions)
	if got := strings.Join(*lines, ","); got != "two" {
		t.Fatalf("lines: %s", got)
	}
	if _, still := positions[sum]; still || len(positions) != 1 {
		t.Fatalf("the old key is dropped: %v", positions)
	}
}

func sha256Of(first string) string {
	sum := sha256.Sum256([]byte(first))
	return hex.EncodeToString(sum[:16])
}
