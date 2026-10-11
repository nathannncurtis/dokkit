package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const statsTimeout = 5 * time.Second

// statsSoon fetches the stats documents on their own goroutine, so a slow address holds no check back.
func (w *watcher) statsSoon() {
	if !w.statsBusy.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer w.statsBusy.Store(false)
		if lines := w.stats(); len(lines) > 0 {
			w.c.report(lines...)
			w.statsReady.Store(true)
		}
	}()
}

// stats fetches the stats document of each service whose file says where it is.
func (w *watcher) stats() []any {
	var todo []*declaration
	w.mu.Lock()
	for _, d := range w.files {
		if d.Stats.URL != "" {
			todo = append(todo, d)
		}
	}
	w.mu.Unlock()
	lines := make([]any, len(todo))
	parallel(len(todo), func(i int) { lines[i] = fetchStats(todo[i]) })
	out := lines[:0]
	for _, l := range lines {
		if m := l.(map[string]any); m["type"] == "log" {
			// A key the machine does not have is said once an hour, not every minute.
			msg := m["service"].(string) + m["msg"].(string)
			if time.Since(w.statsNoted[msg]) < time.Hour {
				continue
			}
			if w.statsNoted == nil {
				w.statsNoted = map[string]time.Time{}
			}
			w.statsNoted[msg] = time.Now()
			fmt.Fprintln(os.Stderr, "dokkit:", m["msg"])
		}
		out = append(out, l)
	}
	return out
}

// fetchStats is the stats line, or a warning log line when the key the file names cannot be sent: no
// request is made then, and the service is not reported down for a fault on this machine.
func fetchStats(d *declaration) any {
	var document map[string]any
	req, err := http.NewRequest("GET", d.Stats.URL, nil)
	if k := d.Stats.KeyEnv; err == nil && k != "" {
		why := ""
		switch {
		case !strings.HasPrefix(k, statsKeyPrefix):
			why = k + " does not start with " + statsKeyPrefix
		case os.Getenv(k) == "":
			why = k + " is not set where dokkit runs"
		}
		if why != "" {
			return map[string]any{"type": "log", "t": now(), "level": "warn", "service": d.Service.ID, "msg": "dokkit: stats of " + d.Service.ID + " not fetched, key_env: " + why}
		}
		req.Header.Set("X-Stats-Key", os.Getenv(k))
	}
	if err == nil {
		var res *http.Response
		if res, err = (&http.Client{Timeout: statsTimeout}).Do(req); err == nil {
			if res.StatusCode != 200 {
				err = fmt.Errorf("answered %d", res.StatusCode)
			} else {
				err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&document)
			}
			res.Body.Close()
		}
	}
	if err != nil {
		return map[string]any{"type": "state", "at": now(), "service": d.Service.ID, "check": "stats", "state": "down", "note": "stats: " + short(err)}
	}
	return map[string]any{"type": "stats", "at": now(), "service": d.Service.ID, "document": document}
}
