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
// size and a goroutine sends them. An error report carries the error's type and stack, never
// its message. A log line carries the text and fields the app logs.
package dokkit

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	queue    = 1000
	maxBytes = 8 << 20 // queued bytes
	maxLine  = 64 << 10
	maxBatch = 4 << 20 // the server refuses an unzipped batch over 5 MB
)

type line = map[string]any

// AnnounceVersion is whether Start sends a deploy line with the version. The server records a deploy only when the version changes.
var AnnounceVersion = true

// FlushTimeout is the longest Flush, and so Recover, waits for the server.
var FlushTimeout = 5 * time.Second

// batch is what one request carries. One that fails is kept for a second try.
type batch struct {
	path  string
	items [][]byte
	id    string
	tried bool
}

var (
	mu                                 sync.Mutex
	flushing                           sync.Mutex
	on                                 bool
	address, key, version, environment string
	host, module                       string
	lines, errs                        [][]byte
	queued                             int
	held                               *batch
	dropped                            int
	wake                               = make(chan struct{}, 1)
	client                             = &http.Client{Timeout: 10 * time.Second}
)

// Start turns the library on. With no address or key it stays off and every call does nothing.
func Start(release string) { StartWith(release, os.Getenv("DOKKIT_URL"), os.Getenv("DOKKIT_KEY")) }

// StartWith is Start with the address and key given instead of read from the environment.
func StartWith(release, addr, appKey string) {
	mu.Lock()
	if on || addr == "" || appKey == "" || !secure(addr) {
		mu.Unlock()
		return
	}
	on, address, key, version = true, strings.TrimRight(addr, "/"), appKey, release
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
			flush()
		}
	}()
	if release != "" && AnnounceVersion {
		add(line{"type": "deploy", "version": release})
	}
}

// secure is false for an http address to another machine, unless DOKKIT_INSECURE=1.
func secure(addr string) bool {
	u, err := url.Parse(addr)
	if err != nil || u.Host == "" {
		return false
	}
	if u.Scheme == "https" || os.Getenv("DOKKIT_INSECURE") == "1" {
		return true
	}
	h := u.Hostname()
	if ip := net.ParseIP(h); h == "localhost" || (ip != nil && ip.IsLoopback()) {
		return true
	}
	fmt.Fprintln(os.Stderr, "dokkit: off, the address is http and not this machine; use https or set DOKKIT_INSECURE=1")
	return false
}

// Dropped is how many lines and error reports were dropped: the queue was full, or they could not be sent.
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

// encode marshals a line. One that cannot be marshalled gives nil.
func encode(l line) (b []byte) {
	defer func() {
		if recover() != nil {
			b = nil
		}
	}()
	b, err := json.Marshal(l)
	if err != nil {
		return nil
	}
	return b
}

// fit cuts a line over maxLine bytes: its fields go, then its msg is cut at a character boundary and ends in " [cut]".
func fit(l line, b []byte) []byte {
	msg, ok := l["msg"].(string)
	if len(b) <= maxLine || !ok {
		return b
	}
	delete(l, "fields")
	keep := len(msg)
	for keep > 0 {
		if over := len(encode(l)) - maxLine; over > 0 {
			keep -= over + 16
		} else {
			break
		}
		if keep < 0 {
			keep = 0
		}
		for keep > 0 && keep < len(msg) && !utf8.RuneStart(msg[keep]) {
			keep--
		}
		l["msg"] = msg[:keep] + " [cut]"
	}
	return encode(l)
}

func add(l line) {
	mu.Lock()
	h, env, live := host, environment, on
	mu.Unlock()
	if !live {
		return
	}
	if env != "" && env != "production" {
		l["environment"] = env
	}
	if l["at"] == nil {
		l["at"] = now()
	}
	l["host"] = h
	b := fit(l, encode(l))
	mu.Lock()
	defer mu.Unlock()
	if len(b) == 0 || len(b) > maxLine {
		dropped++
		return
	}
	for len(lines) > 0 && (len(lines) >= queue || queued+len(b) > maxBytes) {
		queued -= len(lines[0])
		lines = lines[1:]
		dropped++
	}
	queued += len(b)
	lines = append(lines, b)
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

// relative is the package path and file name, so no folder of the machine is sent.
func relative(file, function string) string {
	if i := strings.IndexByte(function, '['); i >= 0 {
		function = function[:i]
	}
	slash := strings.LastIndexByte(function, '/') + 1
	dot := strings.IndexByte(function[slash:], '.')
	if dot < 0 {
		return path.Base(file)
	}
	return function[:slash+dot] + "/" + path.Base(file)
}

func capture(kind string, handled bool, tags map[string]string, skip int) {
	mu.Lock()
	module := module
	mu.Unlock()
	pcs := make([]uintptr, 64)
	walk := runtime.CallersFrames(pcs[:runtime.Callers(skip+1, pcs)])
	frames := []line{}
	for {
		f, more := walk.Next()
		// Innermost last, as the format asks.
		frames = append([]line{{
			"file": relative(f.File, f.Function), "function": f.Function, "line": f.Line,
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
	if !on {
		return
	}
	if len(errs) >= 100 {
		dropped++
		return
	}
	b := encode(line{
		"at": now(), "type": kind, "handled": handled, "release": version,
		"environment": environment, "host": host, "frames": frames, "tags": tags,
	})
	if len(b) == 0 {
		return
	}
	errs = append(errs, b)
	nudge()
}

func nudge() {
	select {
	case wake <- struct{}{}:
	default:
	}
}

// Flush sends what is waiting and returns after at most FlushTimeout. Call it before the app exits.
func Flush() {
	done := make(chan struct{})
	go func() {
		flush()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(FlushTimeout):
	}
}

// flush sends the lines first: all of them fit in a few requests, and an error report is one
// request each. Neither stops the other when it fails.
func flush() {
	flushing.Lock()
	defer flushing.Unlock()
	for sendLines() {
	}
	for sendError() {
	}
}

// sendLines sends the held batch or the next one, and says whether to go on.
func sendLines() bool {
	mu.Lock()
	b := held
	held = nil
	if b == nil && len(lines) > 0 {
		n, size := 0, 0
		for n < len(lines) && n < 500 && (n == 0 || size+len(lines[n]) <= maxBatch) {
			size += len(lines[n])
			n++
		}
		b = &batch{path: "/api/v1/report", items: lines[:n:n], id: id()}
		lines = lines[n:]
		queued -= size
	}
	mu.Unlock()
	if b == nil {
		return false
	}
	result := send(b)
	mu.Lock()
	defer mu.Unlock()
	switch {
	case result == sent:
		return true
	case result == failed && !b.tried:
		b.tried = true
		held = b
		return false
	}
	dropped += len(b.items)
	return result == refused
}

// sendError sends the oldest error report, and says whether to go on. One the server did not
// answer for stays for the next pass; the hundred that capture keeps is the bound.
func sendError() bool {
	mu.Lock()
	var report []byte
	if len(errs) > 0 {
		report = errs[0]
	}
	mu.Unlock()
	if report == nil {
		return false
	}
	result := send(&batch{path: "/api/v1/errors", items: [][]byte{report}})
	if result == failed {
		return false
	}
	mu.Lock()
	defer mu.Unlock()
	if len(errs) > 0 && &errs[0][0] == &report[0] {
		errs = errs[1:]
	}
	if result == refused {
		dropped++
	}
	return true
}

const (
	sent = iota
	refused
	failed
)

// send tells whether the batch was taken, refused (not tried again) or not delivered.
func send(b *batch) int {
	body, kind, zipped := b.items[0], "application/json", false
	if b.path == "/api/v1/report" {
		var text bytes.Buffer
		z := gzip.NewWriter(&text)
		z.Write(bytes.Join(b.items, []byte("\n")))
		z.Close()
		body, kind, zipped = text.Bytes(), "application/x-ndjson", true
	}
	req, err := http.NewRequest("POST", address+b.path, bytes.NewReader(body))
	if err != nil {
		return refused
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", kind)
	if zipped {
		req.Header.Set("Content-Encoding", "gzip")
		req.Header.Set("Dokkit-Batch", b.id)
	}
	g := gid()
	sending.Store(g, true)
	res, err := client.Do(req)
	sending.Delete(g)
	if err != nil {
		return failed
	}
	res.Body.Close()
	switch {
	case res.StatusCode >= 500 || res.StatusCode == 429:
		return failed
	case res.StatusCode >= 400:
		return refused
	}
	return sent
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

// sending holds the goroutines that are inside the library's own request, so what the HTTP stack logs there is not queued.
var sending sync.Map

func gid() int {
	var b [32]byte
	f := strings.Fields(string(b[:runtime.Stack(b[:], false)]))
	n, _ := strconv.Atoi(f[1])
	return n
}

func (h *handler) Handle(_ context.Context, r slog.Record) error {
	if _, own := sending.Load(gid()); own {
		return nil
	}
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
		fields[a.Key] = plain(a.Value)
	}
	r.Attrs(func(a slog.Attr) bool { fields[a.Key] = plain(a.Value); return true })
	add(line{"type": "log", "t": r.Time.UTC().Format(time.RFC3339Nano), "level": level, "msg": r.Message, "fields": fields})
	return nil
}

// plain resolves a LogValuer first, and turns an error into its text, which marshals as {}.
func plain(v slog.Value) (out any) {
	defer func() {
		if recover() != nil {
			out = nil
		}
	}()
	a := v.Resolve().Any()
	if err, ok := a.(error); ok {
		return err.Error()
	}
	return a
}
