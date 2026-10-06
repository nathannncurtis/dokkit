package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

// A dokkit.toml, as far as this program reads it. The whole file is sent to the server as it is.
type declaration struct {
	path    string
	raw     map[string]any
	Schema  int
	Service struct{ ID, Name string }
	Logs    struct{ Path string }
	Check   []check
}

type check struct {
	Type, Name, URL, Host string
	Port                  int
	Every, Timeout        string
	name                  string
	next                  time.Time
}

type result struct {
	ok    bool
	note  string
	value float64
}

func readDeclaration(path string) (*declaration, error) {
	d := &declaration{path: path}
	if _, err := toml.DecodeFile(path, d); err != nil {
		return nil, err
	}
	if _, err := toml.DecodeFile(path, &d.raw); err != nil {
		return nil, err
	}
	if d.Schema != 1 {
		return nil, errors.New("schema must be 1")
	}
	if d.Service.ID == "" {
		return nil, errors.New("[service] needs an id")
	}
	// The same names the server gives: the check's name, or its type, numbered when it repeats.
	seen := map[string]int{}
	for i := range d.Check {
		c := &d.Check[i]
		base := c.Type
		if c.Name != "" && c.Type != "process" && c.Type != "windows-service" {
			base = c.Name
		}
		seen[base]++
		c.name = base
		if seen[base] > 1 {
			c.name = base + "-" + strconv.Itoa(seen[base])
		}
		if _, err := c.problem(); err != nil {
			return nil, fmt.Errorf("check %s: %w", c.name, err)
		}
	}
	return d, nil
}

// problem says what is wrong with a check's own fields, and whether this program can run it.
func (c *check) problem() (runs bool, err error) {
	for _, d := range []string{c.Every, c.Timeout} {
		if d != "" {
			if _, err := time.ParseDuration(d); err != nil {
				return false, fmt.Errorf("%q is not a time such as 30s or 5m", d)
			}
		}
	}
	switch c.Type {
	case "http":
		if c.URL == "" {
			return false, errors.New("needs a url")
		}
	case "tcp":
		if c.Port == 0 {
			return false, errors.New("needs a port")
		}
	case "process", "windows-service":
		if c.Name == "" {
			return false, errors.New("needs a name")
		}
	case "beat", "stats", "threshold", "expiry", "custom":
		return false, nil
	default:
		return false, fmt.Errorf("unknown type %q", c.Type)
	}
	return true, nil
}

func (c *check) every() time.Duration {
	if d, err := time.ParseDuration(c.Every); err == nil && d >= time.Second {
		return d
	}
	return 30 * time.Second
}

func (c *check) timeout() time.Duration {
	if d, err := time.ParseDuration(c.Timeout); err == nil && d > 0 {
		return d
	}
	return 5 * time.Second
}

func (c *check) run() result {
	started := time.Now()
	var err error
	switch c.Type {
	case "http":
		var res *http.Response
		res, err = (&http.Client{Timeout: c.timeout()}).Get(c.URL)
		if err == nil {
			res.Body.Close()
			if res.StatusCode >= 400 {
				err = fmt.Errorf("answered %d", res.StatusCode)
			}
		}
	case "tcp":
		host := c.Host
		if host == "" {
			host = "localhost"
		}
		var conn net.Conn
		conn, err = net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(c.Port)), c.timeout())
		if err == nil {
			conn.Close()
		}
	case "process":
		err = processRunning(c.Name)
	case "windows-service":
		err = serviceRunning(c.Name)
	}
	if err != nil {
		return result{note: short(err)}
	}
	return result{ok: true, value: float64(time.Since(started).Milliseconds())}
}

// short keeps the last part of a Go network error, which is the part a person wants.
func short(err error) string {
	s := err.Error()
	var op *net.OpError
	if errors.As(err, &op) && op.Err != nil {
		s = op.Err.Error()
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func processRunning(name string) error {
	if runtime.GOOS == "windows" {
		out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq "+name, "/NH", "/FO", "CSV").Output()
		if err != nil {
			return err
		}
		if !strings.Contains(strings.ToLower(string(out)), strings.ToLower(`"`+name+`"`)) {
			return errors.New("not running")
		}
		return nil
	}
	if err := exec.Command("pgrep", "-x", name).Run(); err != nil {
		return errors.New("not running")
	}
	return nil
}

func serviceRunning(name string) error {
	if runtime.GOOS != "windows" {
		return errors.New("only on Windows")
	}
	out, err := exec.Command("sc", "query", name).Output()
	if err != nil {
		return errors.New("no such service")
	}
	if !bytes.Contains(out, []byte("RUNNING")) {
		return errors.New("not running")
	}
	return nil
}

func (c *check) target() string {
	switch c.Type {
	case "http":
		return c.URL
	case "tcp":
		return "port " + strconv.Itoa(c.Port)
	}
	return c.Name
}

func stateLine(d *declaration, c *check, r result) map[string]any {
	l := map[string]any{"type": "state", "at": now(), "service": d.Service.ID, "check": c.name, "state": "ok"}
	if r.ok {
		l["value"] = r.value
	} else {
		l["state"], l["note"] = "down", r.note
	}
	return l
}

// checkOnce validates a file, runs every check once and prints what would be sent. It needs no server.
func checkOnce(path string) int {
	d, err := readDeclaration(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		return 1
	}
	fmt.Printf("%s: %s, %d check(s)\n", path, d.Service.ID, len(d.Check))
	bad := 0
	for i := range d.Check {
		c := &d.Check[i]
		if runs, _ := c.problem(); !runs {
			fmt.Printf("  %-18s reported by the app, not run here\n", c.name)
			continue
		}
		r := c.run()
		line, _ := json.Marshal(stateLine(d, c, r))
		mark := "ok  "
		if !r.ok {
			mark, bad = "FAIL", bad+1
		}
		fmt.Printf("  %s %-14s %s\n       would send %s\n", mark, c.name, c.target(), line)
	}
	if bad > 0 {
		return 1
	}
	return 0
}

func (c *client) apply(path string) int {
	d, err := readDeclaration(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		return 1
	}
	if err := c.declare(d); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Println("Sent", d.Service.ID)
	return 0
}

func (c *client) declare(d *declaration) error {
	body, _ := json.Marshal(d.raw)
	req, _ := http.NewRequest("PUT", c.url+"/api/v1/declare", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+c.key)
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		var a struct{ Error struct{ Message string } }
		json.NewDecoder(res.Body).Decode(&a)
		return fmt.Errorf("the server refused %s (%d). %s", d.path, res.StatusCode, a.Error.Message)
	}
	return nil
}

// watcher holds the dokkit.toml files found in the folders this machine may read.
type watcher struct {
	c        *client
	folders  []string
	files    map[string]*declaration
	modified map[string]time.Time
	logs     map[string]int64
	sent     time.Time
}

// refresh re-reads files that are new or changed, declares them, and forgets files that are gone.
func (w *watcher) refresh() {
	found := map[string]bool{}
	for _, folder := range w.folders {
		paths, _ := filepath.Glob(filepath.Join(folder, "dokkit.toml"))
		more, _ := filepath.Glob(filepath.Join(folder, "*", "dokkit.toml"))
		for _, p := range append(paths, more...) {
			found[p] = true
			info, err := os.Stat(p)
			if err != nil || info.ModTime().Equal(w.modified[p]) {
				continue
			}
			w.modified[p] = info.ModTime()
			d, err := readDeclaration(p)
			if err == nil {
				err = w.c.declare(d)
			}
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s  %s: %v\n", time.Now().Format("15:04:05"), p, err)
				// Tried again on the next pass, in case the server was only away.
				delete(w.modified, p)
				continue
			}
			fmt.Printf("%s  watching %s from %s\n", time.Now().Format("15:04:05"), d.Service.ID, p)
			w.files[p] = d
		}
	}
	for p := range w.files {
		if !found[p] {
			delete(w.files, p)
			delete(w.modified, p)
		}
	}
}

// tick runs the checks that are due and returns how many it ran.
func (w *watcher) tick(at time.Time) int {
	var lines []any
	for _, d := range w.files {
		for i := range d.Check {
			c := &d.Check[i]
			if runs, _ := c.problem(); !runs || at.Before(c.next) {
				continue
			}
			c.next = at.Add(c.every())
			lines = append(lines, stateLine(d, c, c.run()))
		}
	}
	if len(lines) > 0 {
		w.c.report(lines...)
	}
	return len(lines)
}

func (c *client) watch() int {
	w := &watcher{c: c, folders: c.folders, files: map[string]*declaration{}, modified: map[string]time.Time{}, logs: map[string]int64{}}
	if b, err := os.ReadFile(filepath.Join(c.spool, "logs.json")); err == nil {
		json.Unmarshal(b, &w.logs)
	}
	fmt.Println("Reporting to", c.url)
	if len(w.folders) == 0 {
		fmt.Println("No folders to read dokkit.toml files from. Set DOKKIT_FOLDERS, or add folders to the saved configuration.")
	}
	var beat, tailed time.Time
	for {
		at := time.Now()
		ran := 0
		if at.Sub(beat) >= beatEvery {
			beat = at
			w.refresh()
			c.beat()
			ran++
		}
		ran += w.tick(at)
		if ran > 0 {
			if left, err := c.flush(20 * time.Second); left > 0 {
				fmt.Fprintf(os.Stderr, "%s  %d report(s) waiting: %v\n", at.Format("15:04:05"), left, err)
			} else {
				w.sent = at
			}
		}
		if at.Sub(tailed) >= 5*time.Second {
			tailed = at
			w.tail()
		}
		if beat.Equal(at) {
			w.saveStatus(at)
		}
		time.Sleep(time.Second)
	}
}
