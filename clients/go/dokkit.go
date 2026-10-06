// Package dokkit is the Dokkit client library for Go. One file, standard library only.
//
//	dokkit.Start("2.3.0")           // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//	dokkit.Beat("worker", 60)       // from the main loop
//	err := dokkit.Job("nightly-purge", func(run *dokkit.Run) error { run.Progress(4000, 9000); return nil })
//	dokkit.Check("queue-age", "degraded", 14, "oldest item is 14 minutes old")
//	dokkit.Capture(err)
//	slog.SetDefault(slog.New(dokkit.Handler(slog.LevelInfo)))
//
// Nothing here panics into the app or waits on the network. Lines wait in a queue of fixed
// size and a goroutine sends them. Error message text is never sent.
package dokkit

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

const queue = 1000

type line = map[string]any

var (
	mu                             sync.Mutex
	on                             bool
	url, key, version, environment string
	host, module                   string
	lines, errs                    []line
	dropped                        int
	wake                           = make(chan struct{}, 1)
	client                         = &http.Client{Timeout: 10 * time.Second}
)

// Start turns the library on. With no address or key it stays off and every call does nothing.
func Start(release string) { StartWith(release, os.Getenv("DOKKIT_URL"), os.Getenv("DOKKIT_KEY")) }

// StartWith is Start with the address and key given instead of read from the environment.
func StartWith(release, address, appKey string) {
	mu.Lock()
	if on || address == "" || appKey == "" {
		mu.Unlock()
		return
	}
	on, url, key, version = true, strings.TrimRight(address, "/"), appKey, release
	environment = os.Getenv("DOKKIT_ENV")
	host, _ = os.Hostname()
	if info, ok := debug.ReadBuildInfo(); ok {
		module = info.Main.Path
	}
	mu.Unlock()
	go func() {
		for {
			select {
			case <-wake:
			case <-time.After(2 * time.Second):
			}
			Flush()
		}
	}()
	if release != "" {
		add(line{"type": "deploy", "version": release})
	}
}

// Dropped is how many lines were dropped because the queue was full.
func Dropped() int {
	mu.Lock()
	defer mu.Unlock()
	return dropped
}

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func id() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func add(l line) {
	mu.Lock()
	defer mu.Unlock()
	if !on {
		return
	}
	if len(lines) >= queue {
		lines = lines[1:]
		dropped++
	}
	if l["at"] == nil {
		l["at"] = now()
	}
	l["host"] = host
	lines = append(lines, l)
}

// Beat says the app is alive. Call it from the main loop.
func Beat(name string, everySeconds int) {
	add(line{"type": "beat", "name": name, "every_seconds": everySeconds})
}

// Check reports one of the app's own checks. state is "ok", "degraded" or "down".
func Check(name, state string, value float64, note string) {
	add(line{"type": "custom", "check": name, "state": state, "value": value, "note": note})
}

// Metric reports a number.
func Metric(name string, value float64, unit string) {
	add(line{"type": "metric", "name": name, "value": value, "unit": unit})
}

// Log sends one log line. level is trace, debug, info, warn, error or fatal.
func Log(level, msg string, fields map[string]any) {
	add(line{"type": "log", "t": now(), "level": level, "msg": msg, "fields": fields})
}

// Stats sends a stats document, for an app dokkit cannot reach.
func Stats(document any) { add(line{"type": "stats", "document": document}) }

// Run is one run of a job.
type Run struct{ name, id string }

func (r *Run) send(event string, more line) {
	l := line{"type": "job", "name": r.name, "run": r.id, "event": event}
	for k, v := range more {
		l[k] = v
	}
	add(l)
}

// Progress says how far the run has got. A total of 0 means not known.
func (r *Run) Progress(done, total int64) {
	more := line{"done": done}
	if total > 0 {
		more["total"] = total
	}
	r.send("progress", more)
}

// Job reports a run of a job: its start, its progress, and how it ended. It returns what work
// returns. A panic in work is reported as a failure and then carries on up.
func Job(name string, work func(*Run) error) (err error) {
	run, began := &Run{name, id()}, time.Now()
	run.send("start", nil)
	end := func(event string, code int) {
		run.send(event, line{"exit_code": code, "duration_ms": time.Since(began).Milliseconds()})
		nudge()
	}
	defer func() {
		if p := recover(); p != nil {
			end("fail", 1)
			capture(fmt.Sprintf("%T", p), false, nil, 3)
			panic(p)
		}
		if err != nil {
			end("fail", 1)
			capture(fmt.Sprintf("%T", err), false, nil, 3)
			return
		}
		end("ok", 0)
	}()
	return work(run)
}

// Capture sends an error: its type and where Capture was called from, never its message.
func Capture(err error) {
	if err != nil {
		capture(fmt.Sprintf("%T", err), true, nil, 2)
	}
}

// CaptureTagged is Capture with a few tags.
func CaptureTagged(err error, tags map[string]string) {
	if err != nil {
		capture(fmt.Sprintf("%T", err), true, tags, 2)
	}
}

// Recover reports a panic nothing caught and lets it carry on. Use as: defer dokkit.Recover()
func Recover() {
	if p := recover(); p != nil {
		capture(fmt.Sprintf("%T", p), false, nil, 3)
		Flush()
		panic(p)
	}
}

func capture(kind string, handled bool, tags map[string]string, skip int) {
	pcs := make([]uintptr, 64)
	walk := runtime.CallersFrames(pcs[:runtime.Callers(skip+1, pcs)])
	frames := []line{}
	for {
		f, more := walk.Next()
		// Innermost last, as the format asks.
		frames = append([]line{{
			"file": f.File, "function": f.Function, "line": f.Line,
			"own": strings.HasPrefix(f.Function, "main.") || (module != "" && strings.HasPrefix(f.Function, module)),
		}}, frames...)
		if !more {
			break
		}
	}
	if tags == nil {
		tags = map[string]string{}
	}
	mu.Lock()
	defer mu.Unlock()
	if !on || len(errs) >= 100 {
		return
	}
	errs = append(errs, line{
		"at": now(), "type": kind, "handled": handled, "release": version,
		"environment": environment, "host": host, "frames": frames, "tags": tags,
	})
	nudge()
}

func nudge() {
	select {
	case wake <- struct{}{}:
	default:
	}
}

// Flush sends what is waiting. Call it before the app exits.
func Flush() {
	for {
		mu.Lock()
		var one line
		var batch []line
		if len(errs) > 0 {
			one, errs = errs[0], errs[1:]
		} else {
			n := min(len(lines), 500)
			batch, lines = lines[:n:n], lines[n:]
		}
		mu.Unlock()
		// What cannot be sent is dropped. The app is never told.
		switch {
		case one != nil:
			body, _ := json.Marshal(one)
			post("/api/v1/errors", body, "application/json", false)
		case len(batch) > 0:
			var text bytes.Buffer
			z := gzip.NewWriter(&text)
			for i, l := range batch {
				if i > 0 {
					z.Write([]byte("\n"))
				}
				b, _ := json.Marshal(l)
				z.Write(b)
			}
			z.Close()
			post("/api/v1/report", text.Bytes(), "application/x-ndjson", true)
		default:
			return
		}
	}
}

func post(path string, body []byte, kind string, zipped bool) {
	req, err := http.NewRequest("POST", url+path, bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", kind)
	if zipped {
		req.Header.Set("Content-Encoding", "gzip")
		req.Header.Set("Dokkit-Batch", id())
	}
	if res, err := client.Do(req); err == nil {
		res.Body.Close()
	}
}

type handler struct {
	level slog.Level
	attrs []slog.Attr
}

// Handler is a handler for log/slog. Its lines go to the Logs page.
func Handler(level slog.Level) slog.Handler { return &handler{level: level} }

func (h *handler) Enabled(_ context.Context, l slog.Level) bool { return l >= h.level }
func (h *handler) WithGroup(string) slog.Handler                { return h }
func (h *handler) WithAttrs(a []slog.Attr) slog.Handler {
	return &handler{h.level, append(h.attrs[:len(h.attrs):len(h.attrs)], a...)}
}

func (h *handler) Handle(_ context.Context, r slog.Record) error {
	level := "debug"
	switch {
	case r.Level >= slog.LevelError:
		level = "error"
	case r.Level >= slog.LevelWarn:
		level = "warn"
	case r.Level >= slog.LevelInfo:
		level = "info"
	}
	fields := map[string]any{}
	for _, a := range h.attrs {
		fields[a.Key] = a.Value.Any()
	}
	r.Attrs(func(a slog.Attr) bool { fields[a.Key] = a.Value.Any(); return true })
	add(line{"type": "log", "t": r.Time.UTC().Format(time.RFC3339Nano), "level": level, "msg": r.Message, "fields": fields})
	return nil
}
