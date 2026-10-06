package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// initFile asks what the app is and writes its dokkit.toml.
func initFile(path string, in io.Reader) int {
	if _, err := os.Stat(path); err == nil {
		fmt.Fprintln(os.Stderr, path, "is already here.")
		return 1
	}
	r := bufio.NewReader(in)
	ask := func(question, fallback string) string {
		if fallback != "" {
			question += " [" + fallback + "]"
		}
		fmt.Print(question + ": ")
		s, _ := r.ReadString('\n')
		if s = strings.TrimSpace(s); s == "" {
			return fallback
		}
		return s
	}
	dir, _ := os.Getwd()
	name := ask("What is the app called", filepath.Base(dir))
	slug := strings.Trim(regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(strings.ToLower(name), "-"), "-")
	id := ask("Its id, which never changes", slug)
	health := ask("An address that answers when it is healthy, or a port it listens on (blank for neither)", "")
	logs := ask("Log files to read, such as logs/*.jsonl (blank for none)", "")

	var b strings.Builder
	fmt.Fprintf(&b, "schema = 1\n\n[service]\nid = %q\nname = %q\n", id, name)
	if port, err := strconv.Atoi(health); err == nil {
		fmt.Fprintf(&b, "\n[[check]]\ntype = \"tcp\"\nport = %d\n", port)
	} else if health != "" {
		fmt.Fprintf(&b, "\n[[check]]\ntype = \"http\"\nurl = %q\n", health)
	}
	if logs != "" {
		fmt.Fprintf(&b, "\n[logs]\npath = %q\n", logs)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Printf("Wrote %s. Run dokkit check to try it.\n", path)
	return 0
}

var lastIdle, lastTotal uint64

// vitals reads this machine's processor, memory and disk use as metric lines.
func vitals() (lines []any) {
	add := func(name string, value float64) {
		lines = append(lines, map[string]any{"type": "metric", "at": now(), "name": name, "value": value, "unit": "percent"})
	}
	if used, ok := memoryUsed(); ok {
		add("memory.used_percent", used)
	}
	if idle, total, ok := cpuTimes(); ok {
		// Use since the last look. The first look has nothing to compare with.
		if lastTotal != 0 && total > lastTotal {
			add("cpu.percent", 100*(1-float64(idle-lastIdle)/float64(total-lastTotal)))
		}
		lastIdle, lastTotal = idle, total
	}
	for _, d := range findDisks() {
		if used, ok := diskUsed(d); ok {
			add("disk.used_percent."+strings.TrimSuffix(d["mount"], `:\`), used)
		}
	}
	return
}

// diskUsed is the percent of a disk in use, worked out from bytes: whole gigabytes would
// make a small disk with space left look full.
func diskUsed(d found) (float64, bool) {
	total, _ := strconv.ParseFloat(d["total_bytes"], 64)
	free, _ := strconv.ParseFloat(d["free_bytes"], 64)
	return 100 * (total - free) / total, total > 0
}

// stats fetches the stats document of each service whose file says where it is.
func (w *watcher) stats() []any {
	var todo []*declaration
	for _, d := range w.files {
		if d.Stats.URL != "" {
			todo = append(todo, d)
		}
	}
	lines := make([]any, len(todo))
	parallel(len(todo), func(i int) { lines[i] = fetchStats(todo[i]) })
	return lines
}

func fetchStats(d *declaration) any {
	var document map[string]any
	req, err := http.NewRequest("GET", d.Stats.URL, nil)
	if k := d.Stats.KeyEnv; err == nil && k != "" && !strings.HasPrefix(k, statsKeyPrefix) {
		err = errors.New("key_env must name a variable that starts with " + statsKeyPrefix)
	}
	if err == nil {
		if d.Stats.KeyEnv != "" {
			req.Header.Set("X-Stats-Key", os.Getenv(d.Stats.KeyEnv))
		}
		var res *http.Response
		if res, err = (&http.Client{Timeout: 5 * time.Second}).Do(req); err == nil {
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

// What dokkit watch writes down each minute for dokkit status to read.
type status struct {
	At, Sent time.Time
	Pid      int
	URL      string
	Services []string
	Blocked  []string
}

func (w *watcher) saveStatus(at time.Time) {
	s := status{At: at, Sent: w.sent, Pid: os.Getpid(), URL: w.c.url, Blocked: w.blocked}
	for _, d := range w.files {
		line := fmt.Sprintf("%-24s %d check(s)", d.Service.ID, len(d.Check))
		if d.Logs.Path != "" {
			line += ", logs " + d.Logs.Path
		}
		s.Services = append(s.Services, line+"   "+d.path)
	}
	b, _ := json.Marshal(s)
	writeFile(filepath.Join(w.c.spool, "status.json"), b)
}

func (c *client) status() int {
	var s status
	b, err := os.ReadFile(filepath.Join(c.spool, "status.json"))
	if err != nil || json.Unmarshal(b, &s) != nil {
		fmt.Println("dokkit watch has not run on this machine yet.")
		return 1
	}
	ago := func(t time.Time) string {
		if t.IsZero() {
			return "never"
		}
		return fmt.Sprintf("%s (%s ago)", t.Local().Format("Jan 2 15:04:05"), time.Since(t).Round(time.Second))
	}
	waiting, _ := filepath.Glob(filepath.Join(c.spool, "*.ndjson"))
	fmt.Println("Reporting to", s.URL)
	fmt.Printf("Last sent %s. %d report(s) waiting.\n", ago(s.Sent), len(waiting))
	for _, line := range s.Services {
		fmt.Println(" ", line)
	}
	if len(s.Services) == 0 {
		fmt.Println("  No dokkit.toml files are being read.")
	}
	for _, b := range s.Blocked {
		fmt.Println("  Cannot read the folder", b)
	}
	if time.Since(s.At) > 3*time.Minute {
		fmt.Println("dokkit watch is not running. It last wrote this", ago(s.At)+".")
		return 1
	}
	fmt.Println("dokkit watch is running as process", s.Pid)
	return 0
}

// openLog opens a log to add to, starting it again once it is over 5 MB.
func openLog(path string) (*os.File, error) {
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(path); err == nil && info.Size() > 5<<20 {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	return os.OpenFile(path, flags, 0o600)
}

// background starts watch as an ordinary program that keeps running after this one ends.
func (c *client) background() int {
	var s status
	if b, err := os.ReadFile(filepath.Join(c.spool, "status.json")); err == nil && json.Unmarshal(b, &s) == nil && time.Since(s.At) < 90*time.Second {
		fmt.Println("dokkit watch is already running as process", s.Pid)
		return 0
	}
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	log := filepath.Join(c.spool, "watch.log")
	out, err := openLog(log)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	cmd := exec.Command(exe, "watch")
	cmd.Stdout, cmd.Stderr = out, out
	detach(cmd)
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	fmt.Printf("dokkit watch is running as process %d. It writes to %s\n", cmd.Process.Pid, log)
	return 0
}
