package dokkit

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

type got struct {
	path string
	line map[string]any
}

func TestEverythingIsOffUntilStartedThenSends(t *testing.T) {
	var mu sync.Mutex
	var all []got
	raw := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body io.Reader = r.Body
		if r.Header.Get("Content-Encoding") == "gzip" {
			body, _ = gzip.NewReader(r.Body)
		}
		text, _ := io.ReadAll(body)
		mu.Lock()
		defer mu.Unlock()
		raw += string(text) + r.Header.Get("Authorization")
		for _, l := range strings.Split(string(text), "\n") {
			var m map[string]any
			json.Unmarshal([]byte(l), &m)
			all = append(all, got{r.URL.Path, m})
		}
	}))
	defer server.Close()

	Beat("ignored", 60)
	StartWith("2.3.0", server.URL+"/", "dka_test")
	Beat("worker", 30)
	Check("queue-age", "degraded", 14, "oldest item is 14 minutes old")
	slog.New(Handler(slog.LevelInfo)).Error("Upload failed", "file", "a.pdf")
	err := Job("nightly-purge", func(run *Run) error {
		run.Progress(4000, 9000)
		return errors.New("patient 4411")
	})
	if err == nil {
		t.Fatal("the job's own error comes back")
	}
	Flush()
	Flush()

	mu.Lock()
	defer mu.Unlock()
	var types, events []string
	var report map[string]any
	for _, g := range all {
		if g.path == "/api/v1/errors" {
			report = g.line
			continue
		}
		types = append(types, g.line["type"].(string))
		if e, ok := g.line["event"].(string); ok {
			events = append(events, e)
		}
	}
	if strings.Join(types, " ") != "deploy beat custom log job job job" || strings.Join(events, " ") != "start progress fail" {
		t.Fatalf("lines: %v %v", types, events)
	}
	if report == nil || report["type"] != "*errors.errorString" || report["handled"] != false {
		t.Fatalf("error: %v", report)
	}
	frames := report["frames"].([]any)
	if last := frames[len(frames)-1].(map[string]any); !strings.Contains(last["function"].(string), "TestEverything") || last["own"] != true {
		t.Fatalf("innermost frame last: %v", last)
	}
	if strings.Contains(raw, "4411") || strings.Contains(raw, "ignored") || !strings.Contains(raw, "Bearer dka_test") {
		t.Fatal("message text or an early line was sent, or the key was not")
	}
}
