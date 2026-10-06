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

type secret struct{}

func (secret) LogValue() slog.Value { return slog.StringValue("redacted") }

type boom struct{}

func (boom) MarshalJSON() ([]byte, error) { panic("no") }

func reset() {
	mu.Lock()
	defer mu.Unlock()
	on, lines, errs, queued, held, dropped = false, nil, nil, 0, nil, 0
}

func TestValuesAreResolvedAndCopiedWhenQueued(t *testing.T) {
	reset()
	StartWith("", "http://127.0.0.1:1", "dka_test")
	fields := map[string]any{"a": 1}
	Log("info", "x", fields)
	fields["a"] = 2
	Stats(boom{})
	slog.New(Handler(slog.LevelInfo)).Info("m", "s", secret{}, "err", errors.New("bad"))
	mu.Lock()
	defer mu.Unlock()
	all := ""
	for _, l := range lines {
		all += string(l)
	}
	if !strings.Contains(all, `"a":1`) || !strings.Contains(all, `"s":"redacted"`) || !strings.Contains(all, `"err":"bad"`) || dropped != 1 {
		t.Fatalf("%s dropped=%d", all, dropped)
	}
}

func TestFailedBatchIsRetriedOnceThenCounted(t *testing.T) {
	reset()
	hits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++; w.WriteHeader(503) }))
	defer server.Close()
	StartWith("", server.URL, "dka_test")
	Beat("w", 1)
	Flush()
	Flush()
	Flush()
	if hits != 2 || Dropped() != 1 {
		t.Fatalf("hits=%d dropped=%d", hits, Dropped())
	}
}

func TestHttpToAnotherMachineStaysOffUnlessAllowed(t *testing.T) {
	if secure("http://example.com") || !secure("https://example.com") || !secure("http://localhost:4000") {
		t.Fatal("secure")
	}
	t.Setenv("DOKKIT_INSECURE", "1")
	if !secure("http://example.com") {
		t.Fatal("insecure allowed")
	}
}

func TestQueueIsBoundedByBytes(t *testing.T) {
	reset()
	StartWith("", "http://127.0.0.1:1", "dka_test")
	big := strings.Repeat("x", 900<<10)
	for i := 0; i < 12; i++ {
		Log("info", big, nil)
	}
	mu.Lock()
	defer mu.Unlock()
	if queued > maxBytes || dropped == 0 {
		t.Fatalf("queued=%d dropped=%d", queued, dropped)
	}
}

func TestFramesCarryNoFolders(t *testing.T) {
	if got := relative("/home/bob/go/pkg/mod/github.com/x/y@v1/sub/a.go", "github.com/x/y/sub.F"); got != "github.com/x/y/sub/a.go" {
		t.Fatal(got)
	}
}
