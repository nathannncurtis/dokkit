package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
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

// What dokkit watch writes down each minute for dokkit status to read.
type status struct {
	At, Sent time.Time
	URL      string
	Services []string
}

func (w *watcher) saveStatus(at time.Time) {
	s := status{At: at, Sent: w.sent, URL: w.c.url}
	for _, d := range w.files {
		line := fmt.Sprintf("%-24s %d check(s)", d.Service.ID, len(d.Check))
		if d.Logs.Path != "" {
			line += ", logs " + d.Logs.Path
		}
		s.Services = append(s.Services, line+"   "+d.path)
	}
	b, _ := json.Marshal(s)
	os.WriteFile(filepath.Join(w.c.spool, "status.json"), b, 0o600)
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
	if time.Since(s.At) > 3*time.Minute {
		fmt.Println("dokkit watch is not running. It last wrote this", ago(s.At)+".")
		return 1
	}
	return 0
}
