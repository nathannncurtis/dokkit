// dokkit is the command-line tool and the program that runs on each machine.
// The contract it follows is in ../spec/program.md and ../spec/api.md.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	tailBytes = 16 * 1024
	spoolCap  = 500 * 1024 * 1024
	version   = "0.1.0"
	usage     = `dokkit run --job <name> -- <command> [arguments]
dokkit ping <name> [start|ok|fail]
dokkit init
dokkit check [dokkit.toml]
dokkit apply [dokkit.toml]
dokkit enrol <address> <token> [sha256:<certificate fingerprint>]
dokkit watch [--background]
dokkit startup on|off
dokkit status
dokkit doctor
dokkit service install|uninstall|update|start|stop
dokkit scan [--no-services] [--no-ports] [--no-tasks] [--no-containers] [--no-sites] [--no-disks] [--no-declarations]
dokkit propose
dokkit task list
dokkit task run <name>

Reads DOKKIT_URL (the server's address) and DOKKIT_KEY (an app key),
or the address and machine key that dokkit enrol saved.
dokkit watch reads dokkit.toml files from the folders in DOKKIT_FOLDERS
or in the saved configuration, and from the folders directly inside them.
It runs their checks and sends the log files they name. It is an ordinary program:
no administrator, no service. --background leaves it running with no window, and
dokkit startup on starts it that way each time you sign in.`
)

// How often watch tells the server this machine is alive.
var beatEvery = time.Minute

func main() {
	if !asService() {
		os.Exit(cli(os.Args[1:]))
	}
}

func cli(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	if args[0] == "enrol" {
		if len(args) != 3 && len(args) != 4 {
			fmt.Fprintln(os.Stderr, usage)
			return 2
		}
		return enrol(args[1], args[2], strings.Join(args[3:], ""))
	}
	if args[0] == "check" {
		return checkOnce(fileArg(args))
	}
	if args[0] == "init" {
		return initFile("dokkit.toml", os.Stdin)
	}
	if args[0] == "service" {
		if len(args) != 2 || !strings.Contains(" install uninstall update start stop ", " "+args[1]+" ") {
			fmt.Fprintln(os.Stderr, usage)
			return 2
		}
		return serviceCommand(args[1])
	}
	c, err := load()
	// These two need no server, only the folders when there are any.
	if args[0] == "scan" || args[0] == "task" {
		var folders []string
		if c != nil {
			folders = c.folders
		}
		if args[0] == "scan" {
			return scan(args[1:], folders)
		}
		return taskCommand(args[1:], folders, c)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 2
	}
	switch args[0] {
	case "run":
		if len(args) < 5 || args[1] != "--job" || args[3] != "--" {
			fmt.Fprintln(os.Stderr, usage)
			return 2
		}
		return c.run(args[2], args[4:])
	case "ping":
		event := "ok"
		if len(args) == 3 {
			event = args[2]
		}
		if len(args) < 2 || len(args) > 3 || (event != "start" && event != "ok" && event != "fail") {
			fmt.Fprintln(os.Stderr, usage)
			return 2
		}
		c.report(c.job(line{Name: args[1], Event: event}))
		return c.settle(15 * time.Second)
	case "watch":
		if len(args) > 1 && args[1] == "--background" {
			return c.background()
		}
		return c.watch()
	case "startup":
		if len(args) != 2 || (args[1] != "on" && args[1] != "off") {
			fmt.Fprintln(os.Stderr, usage)
			return 2
		}
		if err := startup(args[1] == "on"); err != nil {
			fmt.Fprintln(os.Stderr, "dokkit:", err)
			return 1
		}
		fmt.Println("Starting at sign-in is", args[1]+".")
		return 0
	case "apply":
		return c.apply(fileArg(args))
	case "status":
		return c.status()
	case "propose":
		return c.propose()
	case "doctor":
		return c.doctor()
	}
	fmt.Fprintln(os.Stderr, usage)
	return 2
}

// toServer is how every request to the Dokkit server travels. Checks of other things do not use it.
var toServer http.RoundTripper = http.DefaultTransport

// pinTo makes the server's certificate the only thing trusted: the one with this fingerprint
// and no other, whatever name or authority it carries. With no pin, the usual checks apply.
func pinTo(pin string) {
	if pin == "" {
		return
	}
	want := strings.ToLower(strings.TrimPrefix(pin, "sha256:"))
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.TLSClientConfig = &tls.Config{
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(certificates [][]byte, _ [][]*x509.Certificate) error {
			if len(certificates) > 0 {
				if sum := sha256.Sum256(certificates[0]); hex.EncodeToString(sum[:]) == want {
					return nil
				}
			}
			return errors.New("the server's certificate is not the one this machine enrolled with")
		},
	}
	toServer = t
}

type client struct {
	pin             string
	url, key, spool string
	folders         []string
	system          bool   // this machine's own config allows tasks accepted for the system account
	updateSha       string // the hash a fetched update must have, when the config names one
	http            *http.Client
}

func fileArg(args []string) string {
	if len(args) > 1 {
		return args[1]
	}
	return "dokkit.toml"
}

type line struct {
	Type     string `json:"type"`
	At       string `json:"at"`
	Service  string `json:"service,omitempty"`
	Name     string `json:"name"`
	Run      string `json:"run,omitempty"`
	Event    string `json:"event"`
	ExitCode *int   `json:"exit_code,omitempty"`
	Duration *int64 `json:"duration_ms,omitempty"`
	Tail     string `json:"tail,omitempty"`
}

type saved struct {
	URL     string   `json:"url"`
	Key     string   `json:"key"`
	Pin     string   `json:"pin,omitempty"`
	Folders []string `json:"folders,omitempty"`
	// SystemTasks lets tasks accepted for the system account run as it. UpdateSha256 is the
	// SHA-256 a fetched update must have.
	SystemTasks  bool   `json:"system_tasks,omitempty"`
	UpdateSha256 string `json:"update_sha256,omitempty"`
}

func configPath() (string, error) {
	if p := os.Getenv("DOKKIT_CONFIG"); p != "" {
		return p, nil
	}
	dir, err := os.UserConfigDir()
	return filepath.Join(dir, "dokkit", "config.json"), err
}

func load() (*client, error) {
	c := &client{url: os.Getenv("DOKKIT_URL"), key: os.Getenv("DOKKIT_KEY"), spool: os.Getenv("DOKKIT_SPOOL"), http: &http.Client{}}
	defer func() { c.http.Transport = toServer }()
	var s saved
	if p, err := configPath(); err == nil {
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &s)
		}
	}
	// An installed service's configuration wins for whoever is allowed to read it.
	if dir := machineDir(); dir != "" && os.Getenv("DOKKIT_CONFIG") == "" {
		if b, err := os.ReadFile(filepath.Join(dir, "config.json")); err == nil && json.Unmarshal(b, &s) == nil && c.spool == "" {
			c.spool = filepath.Join(dir, "spool")
		}
	}
	c.folders, c.pin, c.system, c.updateSha = s.Folders, s.Pin, s.SystemTasks, strings.ToLower(s.UpdateSha256)
	pinTo(s.Pin)
	if f := os.Getenv("DOKKIT_FOLDERS"); f != "" {
		c.folders = filepath.SplitList(f)
	}
	if c.url == "" || c.key == "" {
		if s.URL == "" || s.Key == "" {
			return nil, errors.New("set DOKKIT_URL and DOKKIT_KEY, or run dokkit enrol")
		}
		c.url, c.key = s.URL, s.Key
	}
	c.url = strings.TrimRight(c.url, "/")
	if c.spool == "" {
		dir, err := os.UserCacheDir()
		if err != nil {
			return nil, err
		}
		c.spool = filepath.Join(dir, "dokkit", "spool")
	}
	return c, os.MkdirAll(c.spool, 0o700)
}

// enrol trades a one-use token for this machine's key and saves it for this user only.
func enrol(address, token, pin string) int {
	address = strings.TrimRight(address, "/")
	pinTo(pin)
	host, _ := os.Hostname()
	body, _ := json.Marshal(map[string]string{"token": token, "hostname": host, "os": runtime.GOOS, "arch": runtime.GOARCH, "dokkit": version})
	res, err := (&http.Client{Timeout: 15 * time.Second, Transport: toServer}).Post(address+"/api/v1/enrol", "application/json", bytes.NewReader(body))
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: cannot reach the server:", err)
		return 1
	}
	defer res.Body.Close()
	var a struct {
		Key   string
		Error struct{ Message string }
	}
	json.NewDecoder(res.Body).Decode(&a)
	if res.StatusCode != 200 || a.Key == "" {
		fmt.Fprintf(os.Stderr, "dokkit: the server said no (%d). %s\n", res.StatusCode, a.Error.Message)
		return 1
	}
	p, err := configPath()
	if err == nil {
		err = os.MkdirAll(filepath.Dir(p), 0o700)
	}
	if err == nil {
		b, _ := json.Marshal(saved{URL: address, Key: a.Key, Pin: pin})
		err = os.WriteFile(p, b, 0o600)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: enrolled, but could not save the key:", err)
		return 1
	}
	fmt.Printf("%s is enrolled. Its key is in %s\nRun dokkit watch to start reporting.\n", host, p)
	return 0
}

// beat says this machine is alive.
func (c *client) beat(services []map[string]string) {
	inventory := map[string]any{"type": "inventory", "at": now(), "os": runtime.GOOS, "arch": runtime.GOARCH, "dokkit": version, "services": services}
	c.report(append([]any{inventory}, vitals()...)...)
}

// job fills in what every job line carries. A machine key names the job as a service of its machine.
func (c *client) job(l line) line {
	l.Type, l.At = "job", now()
	if strings.HasPrefix(c.key, "dkm_") {
		l.Service = l.Name
	}
	return l
}

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func id() string {
	b := make([]byte, 16)
	rand.Read(b)
	return uuid(b)
}

// uuid writes 16 bytes the way the server expects a batch id.
func uuid(b []byte) string {
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// run wraps a command: it reports the start, lets the command's output through
// untouched, and reports how it ended. It exits as the command did.
func (c *client) run(job string, command []string) int {
	run := id()
	c.report(c.job(line{Name: job, Run: run, Event: "start"}))
	c.flush(5 * time.Second)

	tail := &ring{max: tailBytes}
	cmd := exec.Command(command[0], command[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, io.MultiWriter(os.Stdout, tail), io.MultiWriter(os.Stderr, tail)
	started := time.Now()
	err := cmd.Run()
	took := time.Since(started).Milliseconds()

	code, event := 0, "ok"
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		code, event = exit.ExitCode(), "fail"
	case err != nil:
		code, event = 127, "fail"
		fmt.Fprintln(tail, "dokkit: could not start the command:", err)
		fmt.Fprintln(os.Stderr, "dokkit: could not start the command:", err)
	}
	c.report(c.job(line{Name: job, Run: run, Event: event, ExitCode: &code, Duration: &took, Tail: tail.String()}))
	c.settle(15 * time.Second)
	return code
}

// report puts lines in the spool, where they stay until the server has them.
func (c *client) report(lines ...any) {
	var b bytes.Buffer
	for _, l := range lines {
		j, _ := json.Marshal(l)
		b.Write(j)
		b.WriteByte('\n')
	}
	name := fmt.Sprintf("%020d-%s.ndjson", time.Now().UnixNano(), id())
	if err := os.WriteFile(filepath.Join(c.spool, name), b.Bytes(), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: could not write to the spool:", err)
	}
}

// settle flushes and says so when something is still waiting. It never fails the caller's job.
func (c *client) settle(wait time.Duration) int {
	if left, err := c.flush(wait); left > 0 {
		fmt.Fprintf(os.Stderr, "dokkit: %d report(s) kept in %s to send later: %v\n", left, c.spool, err)
	}
	return 0
}

// flush sends spooled batches oldest first and returns how many are left.
func (c *client) flush(wait time.Duration) (int, error) {
	files, _ := filepath.Glob(filepath.Join(c.spool, "*.ndjson"))
	sort.Strings(files)
	files = c.trim(files)
	c.http.Timeout = wait
	for i, f := range files {
		body, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		batch := strings.TrimSuffix(filepath.Base(f)[21:], ".ndjson")
		status, answer, err := c.post(batch, body)
		switch {
		case err != nil:
			return len(files) - i, err
		case status/100 == 2:
			var a struct {
				Refused []struct {
					Line          int
					Code, Message string
				}
			}
			json.Unmarshal(answer, &a)
			for _, r := range a.Refused {
				fmt.Fprintf(os.Stderr, "dokkit: the server refused a line (%s): %s\n", r.Code, r.Message)
			}
			os.Remove(f)
		case status == 413 || status == 422:
			fmt.Fprintf(os.Stderr, "dokkit: the server will never take this batch (%d), dropping it\n", status)
			os.Remove(f)
		default:
			return len(files) - i, fmt.Errorf("the server answered %d", status)
		}
	}
	return 0, nil
}

func (c *client) post(batch string, body []byte) (int, []byte, error) {
	var z bytes.Buffer
	w := gzip.NewWriter(&z)
	w.Write(body)
	w.Close()
	req, err := http.NewRequest("POST", c.url+"/api/v1/report", &z)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	req.Header.Set("Content-Type", "application/x-ndjson")
	req.Header.Set("Content-Encoding", "gzip")
	req.Header.Set("Dokkit-Batch", batch)
	res, err := c.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	answer, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	return res.StatusCode, answer, nil
}

// trim drops the oldest batches when the spool is over its cap.
func (c *client) trim(files []string) []string {
	var total int64
	sizes := make([]int64, len(files))
	for i, f := range files {
		if s, err := os.Stat(f); err == nil {
			sizes[i] = s.Size()
			total += sizes[i]
		}
	}
	dropped := 0
	for total > spoolCap && dropped < len(files) {
		os.Remove(files[dropped])
		total -= sizes[dropped]
		dropped++
	}
	if dropped > 0 {
		fmt.Fprintf(os.Stderr, "dokkit: the spool was full, dropped the %d oldest report(s)\n", dropped)
	}
	return files[dropped:]
}

func (c *client) doctor() int {
	c.http.Timeout = 10 * time.Second
	req, _ := http.NewRequest("GET", c.url+"/api/v1/ping", nil)
	req.Header.Set("Authorization", "Bearer "+c.key)
	sent := time.Now()
	res, err := c.http.Do(req)
	if err != nil {
		fmt.Println("Cannot reach the server:", err)
		return 1
	}
	defer res.Body.Close()
	var a struct{ Time time.Time }
	json.NewDecoder(res.Body).Decode(&a)
	switch {
	case res.StatusCode == 401:
		fmt.Println("The server is there, but it does not know this key.")
		return 1
	case res.StatusCode != 200:
		fmt.Println("The server answered", res.StatusCode)
		return 1
	}
	fmt.Println("The server is reachable and knows this key.")
	if off := a.Time.Sub(sent).Round(time.Second); off > 30*time.Second || off < -30*time.Second {
		fmt.Printf("This machine's clock is %s away from the server's.\n", off)
	}
	if left, _ := c.flush(10 * time.Second); left > 0 {
		fmt.Println(left, "report(s) are still waiting in", c.spool)
		return 1
	}
	fmt.Println("Nothing is waiting in the spool.")
	return 0
}

// ring keeps the last max bytes written to it.
type ring struct {
	max int
	b   []byte
}

func (r *ring) Write(p []byte) (int, error) {
	r.b = append(r.b, p...)
	if len(r.b) > r.max {
		r.b = r.b[len(r.b)-r.max:]
	}
	return len(p), nil
}

func (r *ring) String() string { return strings.ToValidUTF8(string(r.b), "") }
