package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/BurntSushi/toml"
)

// A dokkit.toml, as far as this program reads it. The whole file is sent to the server as it is.
type declaration struct {
	path    string
	raw     map[string]any
	Schema  int
	Service struct {
		ID, Name    string
		VersionFrom string `toml:"version_from"`
	}
	Logs  struct{ Path string }
	Stats struct {
		URL    string
		KeyEnv string `toml:"key_env"`
	}
	Check []check
	Job   []struct{ ID string }
}

type check struct {
	Type, Name, URL, Host string
	Port                  int
	Every, Timeout, Slow  string
	DateFrom              string `toml:"date_from" json:"date_from"`
	CommandHas            string `toml:"command_has" json:"command_has"`
	AtLeast               int    `toml:"at_least" json:"at_least"`
	Status                any
	name, dir             string
	next                  time.Time
	restart               bool
	refuseStart           bool
	refused               string
}

// Only variables with this prefix can be sent to a stats address.
const statsKeyPrefix = "DOKKIT_STATS_"

// within says whether path, once links are followed, is inside dir.
func within(dir, path string) bool {
	d, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return false
	}
	p, err := filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(d, p)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// parallel runs f for 0..n-1 at once and waits for all.
func parallel(n int, f func(i int)) {
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			f(i)
		}()
	}
	wg.Wait()
}

// startService starts a stopped Windows service. Only the installed service can. A systemd unit is restarted by restartUnit.
var startService func(name string) error

// restarted is when each service was last started here, so one that will not stay up is
// tried once in ten minutes and no more.
var (
	restarted   = map[string]time.Time{}
	restartedMu sync.Mutex
)

// unitKey is a name as the throttle and the restart list compare it: a unit with or without .service is one.
func (c *check) unitKey(name string) string {
	name = strings.ToLower(name)
	if c.Type == "systemd" {
		name = strings.TrimSuffix(name, ".service")
	}
	return name
}

func (c *check) tryRestart() bool {
	start := startService
	if c.Type == "systemd" {
		// Only the installed service restarts a unit, never a watch run from a login.
		start = nil
		if runningAsService() {
			start = restartUnit
		}
	}
	key := c.unitKey(c.Name)
	restartedMu.Lock()
	if !c.restart || start == nil || time.Since(restarted[key]) < 10*time.Minute {
		restartedMu.Unlock()
		return false
	}
	restarted[key] = time.Now()
	restartedMu.Unlock() // the restart itself can take a while, and holds nothing
	return start(c.Name) == nil
}

type result struct {
	ok    bool
	state string
	note  string
	value float64
	// blind is a check this account could not make. Nothing is sent for it.
	blind bool
}

// cannotTell is a check that could not be made, which is not the same as one that failed.
type cannotTell struct{ why string }

func (c cannotTell) Error() string { return c.why }

func readDeclaration(path string) (*declaration, error) {
	d := &declaration{path: path}
	if _, err := toml.DecodeFile(path, d); err != nil {
		return nil, err
	}
	if _, err := toml.DecodeFile(path, &d.raw); err != nil {
		return nil, err
	}
	if d.Schema != 1 {
		return nil, errors.New("add schema = 1 as the first line.")
	}
	if d.Service.ID == "" {
		return nil, errors.New("[service] needs an id")
	}
	if err := d.validate(); err != nil {
		return nil, err
	}
	// The same names the server gives: the check's name, or its type, numbered when it repeats.
	seen := map[string]int{}
	for i := range d.Check {
		c := &d.Check[i]
		base := c.Type
		if c.Name != "" && c.Type != "process" && c.Type != "windows-service" && c.Type != "systemd" {
			base = c.Name
		}
		seen[base]++
		c.name, c.dir = base, filepath.Dir(path)
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
	for _, d := range []string{c.Every, c.Timeout, c.Slow} {
		if d != "" {
			if _, err := time.ParseDuration(d); err != nil {
				return false, fmt.Errorf("%q is not a time such as 30s or 5m", d)
			}
		}
	}
	if c.AtLeast != 0 && (c.Type != "process" || c.AtLeast < 1) {
		return false, errors.New("at_least is a number of processes, 1 or more, and only for a process check")
	}
	if c.Status != nil {
		if c.Type != "http" {
			return false, errors.New("status is only for an http check")
		}
		if _, err := statusRanges(c.Status); err != nil {
			return false, err
		}
	}
	if c.Slow != "" {
		slow, _ := time.ParseDuration(c.Slow)
		switch {
		case c.Type != "http":
			return false, errors.New("slow is only for an http check")
		case slow <= 0:
			return false, fmt.Errorf("slow must be more than zero, not %q", c.Slow)
		case slow >= c.timeout():
			return false, fmt.Errorf("slow (%s) must be less than timeout (%s), or it can never show. Raise timeout, which is 5s when not set", c.Slow, seconds(c.timeout()))
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
	case "process", "windows-service", "systemd":
		if c.CommandHas != "" && c.Type != "process" {
			return false, errors.New("command_has is only for a process check")
		}
		if c.Name == "" {
			return false, errors.New("needs a name")
		}
	case "expiry":
		// With nothing to read the date from, the app reports it.
		return c.DateFrom != "", nil
	case "beat", "stats", "threshold", "custom":
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
	if c.Type == "expiry" {
		return time.Hour
	}
	return 30 * time.Second
}

// certAddr is the host:port date_from names, or "" when it names a file.
func (c *check) certAddr() string {
	from := c.DateFrom
	if u, err := url.Parse(from); err == nil && u.Scheme == "https" {
		from = u.Host
		if u.Port() == "" {
			from += ":443"
		}
	}
	if _, port, err := net.SplitHostPort(from); err == nil {
		if _, err := strconv.Atoi(port); err == nil {
			return from
		}
	}
	return ""
}

// host is the machine a check reaches out to, or "" when it stays on this one.
func (c *check) host() string {
	switch c.Type {
	case "tcp":
		return c.Host
	case "http":
		if u, err := url.Parse(c.URL); err == nil && u.Hostname() != "" {
			return u.Hostname()
		}
		return "?"
	case "expiry":
		h, _, _ := net.SplitHostPort(c.certAddr())
		return h
	}
	return ""
}

// mayReach says whether a check pulled from the server may go to host: this machine always,
// anything else only when this machine's own configuration names it.
func (c *client) mayReach(host string) bool {
	if host == "" || strings.EqualFold(host, "localhost") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil && (ip.IsLoopback() || ownAddress(ip)) {
		return true
	}
	if me, _ := os.Hostname(); strings.EqualFold(me, host) {
		return true
	}
	return slices.ContainsFunc(c.hosts, func(h string) bool { return strings.EqualFold(h, host) })
}

func ownAddress(ip net.IP) bool {
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.Equal(ip) {
			return true
		}
	}
	return false
}

// expires reads a date from a certificate (an https address or host:port) or from a file's first line.
func (c *check) expires() (time.Time, error) {
	from := c.DateFrom
	if addr := c.certAddr(); addr != "" {
		from = addr
	}
	if _, _, err := net.SplitHostPort(from); err == nil {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: c.timeout()}, "tcp", from, &tls.Config{InsecureSkipVerify: true}) // only the date is read, so a self-signed certificate still counts
		if err != nil {
			return time.Time{}, err
		}
		defer conn.Close()
		return conn.ConnectionState().PeerCertificates[0].NotAfter, nil
	}
	if !filepath.IsAbs(from) {
		from = filepath.Join(c.dir, from)
	}
	if !within(c.dir, from) {
		return time.Time{}, errors.New("date_from must be a file in the same folder as dokkit.toml")
	}
	b, err := os.ReadFile(from)
	if err != nil {
		return time.Time{}, err
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(b)), "\n")
	line = strings.TrimSpace(line)
	if t, err := time.Parse(time.RFC3339, line); err == nil {
		return t, nil
	}
	t, err := time.Parse("2006-01-02", line)
	return t.Add(24 * time.Hour), err // a bare date lasts through that day
}

func (c *check) timeout() time.Duration {
	if d, err := time.ParseDuration(c.Timeout); err == nil && d > 0 {
		return d
	}
	return 5 * time.Second
}

func (c *check) run() result {
	if c.refused != "" {
		return result{state: "down", note: c.refused}
	}
	started := time.Now()
	var err error
	switch c.Type {
	case "http":
		var res *http.Response
		want, _ := statusRanges(c.Status)
		client := &http.Client{Timeout: c.timeout()}
		if slices.ContainsFunc(want, func(r [2]int) bool { return r[1] >= 300 && r[0] < 400 }) {
			client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
		}
		res, err = client.Get(c.URL)
		if err == nil {
			res.Body.Close()
			code := res.StatusCode
			if len(want) == 0 && code >= 400 || len(want) > 0 && !slices.ContainsFunc(want, func(r [2]int) bool { return code >= r[0] && code <= r[1] }) {
				err = fmt.Errorf("answered %d", code)
			}
		}
		if slow, perr := time.ParseDuration(c.Slow); err == nil && perr == nil && time.Since(started) > slow {
			took := time.Since(started)
			return result{state: "degraded", value: float64(took.Milliseconds()), note: "answered in " + tookText(took, slow) + ", slower than " + seconds(slow)}
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
	case "expiry":
		var until time.Time
		if until, err = c.expires(); err == nil {
			return expiryResult(until, time.Now())
		}
	case "process":
		var n int
		if n, err = processCount(c.Name, c.CommandHas); err == nil {
			return processResult(n, c.AtLeast)
		}
	case "windows-service", "systemd":
		if c.Type == "systemd" {
			err = systemdActive(c.Name)
		} else {
			err = serviceRunning(c.Name)
		}
		var busy unitBusy
		if errors.As(err, &busy) {
			return result{state: "degraded", note: c.Name + " " + err.Error()}
		}
		var stuck unitStuck
		if errors.As(err, &stuck) {
			return result{note: c.Name + " " + err.Error()}
		}
		if err != nil && !errors.As(err, new(cannotTell)) {
			if c.tryRestart() {
				return result{ok: true, note: "had stopped; started it again"}
			}
			if c.refuseStart {
				err = fmt.Errorf("%w; this machine does not allow starting it, list it under restart in its config.json", err)
			}
		}
	}
	var blind cannotTell
	if errors.As(err, &blind) {
		return result{blind: true, note: blind.why}
	}
	if err != nil {
		return result{note: short(err)}
	}
	return result{ok: true, value: float64(time.Since(started).Milliseconds())}
}

// tookText writes a time with as many decimals as it takes to show it is over the limit.
func tookText(took, limit time.Duration) string {
	for places := 1; ; places++ {
		s := strconv.FormatFloat(took.Seconds(), 'f', places, 64)
		if f, _ := strconv.ParseFloat(s, 64); f > limit.Seconds() || places >= 4 {
			return s + " s"
		}
	}
}

// seconds writes a duration as "2 s" or "0.5 s".
func seconds(d time.Duration) string { return strconv.FormatFloat(d.Seconds(), 'f', -1, 64) + " s" }

// expiryResult is down once the time has passed, and shows whole days left, rounded up while any remain.
func expiryResult(until, at time.Time) result {
	left := until.Sub(at).Hours() / 24
	days := math.Floor(left)
	if left > 0 {
		days = math.Ceil(left)
	}
	switch {
	case left < 0:
		return result{state: "down", value: days, note: "ran out on " + until.Format("Jan 2 2006")}
	case left <= 30:
		return result{state: "degraded", value: days, note: fmt.Sprintf("runs out in %.0f days, on %s", days, until.Format("Jan 2 2006"))}
	}
	return result{ok: true, value: days}
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

// processResult is ok with the count as its value, or degraded when fewer than at_least are running.
func processResult(n, atLeast int) result {
	if n < atLeast {
		return result{state: "degraded", value: float64(n), note: fmt.Sprintf("%d running, at least %d wanted", n, atLeast)}
	}
	return result{ok: true, value: float64(n)}
}

// processCount is how many processes match, and an error when none do.
func processCount(name, has string) (int, error) { return processWithText(name, has) }

func serviceRunning(name string) error {
	if runtime.GOOS != "windows" {
		return errors.New("only on Windows")
	}
	out, err := exec.Command("sc", "query", name).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return scProblem(exit.ExitCode())
		}
		return err
	}
	if !bytes.Contains(out, []byte("RUNNING")) {
		return errors.New("not running")
	}
	return nil
}

// scProblem reads sc's exit code, which is the Windows error it met.
func scProblem(code int) error {
	switch code {
	case 1060:
		return errors.New("no such service")
	case 5:
		return cannotTell{"this account may not ask Windows about the service"}
	}
	return fmt.Errorf("sc query failed with %d", code)
}

func (c *check) target() string {
	switch c.Type {
	case "http":
		return c.URL
	case "tcp":
		return "port " + strconv.Itoa(c.Port)
	case "expiry":
		return c.DateFrom
	}
	return c.Name
}

func stateLine(d *declaration, c *check, r result) map[string]any {
	l := map[string]any{"type": "state", "at": now(), "service": d.Service.ID, "check": c.name, "state": "ok"}
	if r.ok {
		l["value"] = r.value
		if r.note != "" {
			l["note"] = r.note
		}
	} else {
		l["state"], l["note"] = "down", r.note
		if r.state != "" {
			l["state"], l["value"] = r.state, r.value
		}
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
	if err := d.misplaced(); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		return 1
	}
	bad := 0
	for i := range d.Check {
		c := &d.Check[i]
		if runs, _ := c.problem(); !runs {
			fmt.Printf("  %-18s reported by the app, not run here\n", c.name)
			continue
		}
		r := c.run()
		if r.blind {
			fmt.Printf("  ?    %-14s %s\n       cannot tell: %s. Nothing would be sent.\n", c.name, c.target(), r.note)
			continue
		}
		line, _ := json.Marshal(stateLine(d, c, r))
		mark := "ok  "
		switch {
		case r.ok:
		case r.state == "degraded" && c.Type == "http":
			mark = "slow"
		case r.state == "degraded":
			mark = "warn"
		default:
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
	res, err := (&http.Client{Timeout: 15 * time.Second, Transport: toServer}).Do(req)
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
	added    []*declaration
	modified map[string]time.Time
	logs     map[string]int64
	sent     time.Time
	mu       sync.Mutex // guards files, which the log reader looks at from its own goroutine
	logc     *client    // the log reader's own client, so its timeout is its own
	unsaved  bool
	blocked  []string        // folders this account cannot list, with why
	told     map[string]bool // blocked folders already written to the log

	statsBusy, statsReady atomic.Bool
	procsBusy             atomic.Bool
	statsNoted            map[string]time.Time
}

// checkFolders notes each folder in the configuration that this account cannot list.
func (w *watcher) checkFolders() {
	w.blocked = nil
	for _, f := range w.folders {
		why := unreadable(f)
		if why == "" {
			continue
		}
		w.blocked = append(w.blocked, f+": "+why)
		if w.told == nil {
			w.told = map[string]bool{}
		}
		if !w.told[f] {
			w.told[f] = true
			fmt.Fprintf(os.Stderr, "%s  cannot read the folder %s: %s\n", time.Now().Format("15:04:05"), f, why)
		}
	}
}

// reload picks up a folder list changed since the last look.
func (w *watcher) reload() {
	w.c.reloadFolders()
	w.folders = w.c.foldersNow()
}

// refresh re-reads files that are new or changed, declares them, and forgets files that are gone.
func (w *watcher) refresh() {
	w.checkFolders()
	found := map[string]bool{}
	{
		for _, p := range declarations(w.folders) {
			found[p] = true
			info, err := os.Stat(p)
			if err != nil {
				continue
			}
			if info.ModTime().Equal(w.modified[p]) {
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
			w.mu.Lock()
			w.files[p] = d
			w.mu.Unlock()
		}
	}
	w.mu.Lock()
	for p := range w.files {
		if !found[p] {
			delete(w.files, p)
			delete(w.modified, p)
		}
	}
	w.mu.Unlock()
	w.pull()
}

// pull asks the server for the checks added in the interface for this machine.
// When the server is away, the ones it gave last time keep running.
func (w *watcher) pull() {
	var a struct {
		Items []struct {
			Service, Name string
			Type          string
			Config        map[string]any
			Restart       bool
		}
	}
	if status, err := w.c.call("GET", "/api/v1/checks", "", nil, &a); err != nil || status != 200 {
		return
	}
	old := map[[2]string]time.Time{}
	for _, d := range w.added {
		old[[2]string{d.Service.ID, d.Check[0].name}] = d.Check[0].next
	}
	w.added = nil
	for _, item := range a.Items {
		var c check
		b, _ := json.Marshal(item.Config)
		json.Unmarshal(b, &c)
		c.Type, c.name = item.Type, item.Name
		c.next = old[[2]string{item.Service, item.Name}]
		// Only a service this machine's own configuration names is ever started, and only
		// addresses on this machine, or named there, are reached.
		listed := slices.ContainsFunc(w.c.restartable, func(n string) bool { return c.unitKey(n) == c.unitKey(c.Name) })
		c.restart, c.refuseStart = item.Restart && listed, item.Restart && !listed
		if runs, _ := c.problem(); runs {
			if h := c.host(); !w.c.mayReach(h) {
				c.refused = "this machine does not allow reaching " + h + "; list it under hosts in its config.json"
			}
			d := &declaration{Check: []check{c}}
			d.Service.ID = item.Service
			w.added = append(w.added, d)
		}
	}
}

// versions reads the version of each service whose file names a file to read it from.
func (w *watcher) versions() (all []map[string]string) {
	for _, d := range w.files {
		from := d.Service.VersionFrom
		if from == "" || from == "stats" {
			continue
		}
		dir := filepath.Dir(d.path)
		if !filepath.IsAbs(from) {
			from = filepath.Join(dir, from)
		}
		if !within(dir, from) {
			continue
		}
		b, err := os.ReadFile(from)
		line, _, _ := strings.Cut(strings.TrimSpace(string(b)), "\n")
		if line = strings.TrimSpace(line); err == nil && line != "" && len(line) <= 100 {
			all = append(all, map[string]string{"id": d.Service.ID, "version": line})
		}
	}
	return
}

// tick runs the checks that are due and returns how many it ran.
func (w *watcher) tick(at time.Time) int {
	type due struct {
		d *declaration
		c *check
	}
	var todo []due
	all := w.added
	for _, d := range w.files {
		all = append(all, d)
	}
	for _, d := range all {
		for i := range d.Check {
			c := &d.Check[i]
			if runs, _ := c.problem(); !runs || at.Before(c.next) {
				continue
			}
			c.next = at.Add(c.every())
			todo = append(todo, due{d, c})
		}
	}
	// At once, so one check that times out does not hold the rest back.
	out := make([][]any, len(todo))
	parallel(len(todo), func(i int) {
		d, c := todo[i].d, todo[i].c
		r := c.run()
		if r.blind {
			return
		}
		out[i] = []any{stateLine(d, c, r)}
		// A note on a good answer is a restart; the state alone would not keep it.
		if r.ok && r.note != "" {
			out[i] = append(out[i], map[string]any{"type": "log", "t": now(), "level": "warn", "service": d.Service.ID, "msg": c.name + ": " + r.note})
		}
	})
	var lines []any
	for _, o := range out {
		lines = append(lines, o...)
	}
	if len(lines) > 0 {
		w.c.report(lines...)
	}
	return len(todo)
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
	go c.work()
	lc := *c
	lc.http = &http.Client{Transport: c.http.Transport}
	w.logc = &lc
	// Logs go on their own clock: a slow check or stats address never holds them back.
	go func() {
		for {
			w.tail()
			time.Sleep(5 * time.Second)
		}
	}()
	var beat time.Time
	for {
		at := time.Now()
		ran := 0
		if at.Sub(beat) >= beatEvery {
			beat = at
			w.reload()
			w.refresh()
			c.beat(w.versions())
			w.statsSoon()
			w.processesSoon()
			ran++
		}
		if w.statsReady.Swap(false) {
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
		if beat.Equal(at) {
			w.saveStatus(at)
		}
		time.Sleep(time.Second)
	}
}
