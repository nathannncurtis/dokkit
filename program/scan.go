package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const proposalFile = "dokkit-proposal.json"

type found = map[string]string

// What a scan looks at. Each part asks the machine's own tools and reads no file contents,
// except the crontabs that cron itself reads.
var scanParts = []struct {
	name string
	find func() []found
}{
	{"services", findServices},
	{"ports", findPorts},
	{"containers", findContainers},
	{"sites", findSites},
	{"disks", findDisks},
}

var scanNames = []string{"declarations", "services", "ports", "containers", "sites", "disks", "jobs"}

func skipped(args []string) map[string]bool {
	skip := map[string]bool{}
	for _, a := range args {
		skip[strings.TrimPrefix(a, "--no-")] = strings.HasPrefix(a, "--no-")
	}
	return skip
}

// look runs the scan and returns the proposal document and how many it found of each kind.
func look(skip map[string]bool, folders []string) ([]byte, map[string]int) {
	host, _ := os.Hostname()
	all := map[string][]found{}
	if !skip["declarations"] {
		for _, p := range declarations(folders) {
			all["declarations"] = append(all["declarations"], found{"file": p})
		}
	}
	for _, part := range scanParts {
		if !skip[part.name] {
			all[part.name] = part.find()
		}
	}
	doc := map[string]any{"machine": host, "os": runtime.GOOS, "at": now(), "found": all}
	if !skip["jobs"] {
		jobs, notes := findJobs()
		all["jobs"], doc["notes"] = jobs, notes
	}
	counts := map[string]int{}
	for name, list := range all {
		counts[name] = len(list)
	}
	b, _ := json.MarshalIndent(doc, "", "  ")
	return b, counts
}

// scan writes what it finds to a file for a person to read. It sends nothing.
func scan(args []string, folders []string) int {
	skip := skipped(args)
	b, counts := look(skip, folders)
	if err := os.WriteFile(proposalFile, b, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	for _, name := range scanNames {
		if !skip[name] {
			fmt.Printf("%-13s %d\n", name, counts[name])
		}
	}
	fmt.Printf("Wrote %s. Nothing was sent.\n", proposalFile)
	return 0
}

var (
	scanFirst = 2 * time.Minute
	scanEvery = 24 * time.Hour
)

const scanWork = "dokkit:scan"

// scanAndSend looks the machine over and sends the proposal, as dokkit scan then dokkit propose do.
func (c *client) scanAndSend() (string, error) {
	b, counts := look(map[string]bool{}, c.foldersNow())
	var a struct{ Waiting int }
	status, err := c.call("POST", "/api/v1/proposals", "application/json", b, &a)
	if err != nil || status != 200 {
		return "", fmt.Errorf("the server did not take the proposal (%d) %v", status, err)
	}
	said := ""
	for _, name := range scanNames {
		if n, ok := counts[name]; ok {
			said += fmt.Sprintf("%-13s %d\n", name, n)
		}
	}
	return said + fmt.Sprintf("Sent. %d thing(s) are waiting on the Found page.\n", a.Waiting), nil
}

// lookAgain is a built-in run: the same read-only scan, sent as a proposal. It takes no parameters.
func (c *client) lookAgain(run string) {
	said, code := "", 0
	out, err := c.scanAndSend()
	if err != nil {
		said, code = "Not sent: "+err.Error()+"\n", 1
	} else {
		said = out
	}
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said), nil)
	body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": 0})
	c.postResult("/api/v1/work/"+run+"/result", body)
}

// propose sends the file a scan wrote, to be decided about in the interface.
func (c *client) propose() int {
	b, err := os.ReadFile(proposalFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: run dokkit scan first:", err)
		return 1
	}
	var a struct{ Waiting int }
	status, err := c.call("POST", "/api/v1/proposals", "application/json", b, &a)
	if err != nil || status != 200 {
		fmt.Fprintf(os.Stderr, "dokkit: the server did not take it (%d). It needs a machine key. %v\n", status, err)
		return 1
	}
	fmt.Printf("Sent. %d thing(s) are waiting on the Found page.\n", a.Waiting)
	return 0
}

// output runs one of the machine's own tools and returns its lines, or nothing when it is not there.
func output(name string, args ...string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return nil
	}
	return strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n")
}

func findServices() (all []found) {
	if runtime.GOOS != "windows" {
		var units []string
		for _, l := range output("systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain") {
			if f := strings.Fields(l); len(f) >= 4 {
				all = append(all, found{"name": strings.TrimSuffix(f[0], ".service"), "state": f[3]})
				units = append(units, f[0])
			}
		}
		origins := linuxOrigins(units)
		for _, s := range all {
			o := origins[s["name"]+".service"]
			mark(s, o[0], o[1])
		}
		return
	}
	var one found
	for _, l := range output("sc", "query", "type=", "service", "state=", "all") {
		key, value, _ := strings.Cut(strings.TrimSpace(l), ":")
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(key) {
		case "SERVICE_NAME":
			one = found{"name": value}
			all = append(all, one)
		case "DISPLAY_NAME":
			one["display"] = value
		case "STATE":
			if f := strings.Fields(value); len(f) > 1 {
				one["state"] = strings.ToLower(f[1])
			}
		}
	}
	for _, s := range all {
		o, w := serviceOrigin(s["name"])
		mark(s, o, w)
	}
	return
}

func findPorts() (all []found) {
	seen := map[string]bool{}
	add := func(port, program string, owner func() (string, string)) {
		if !seen[port+program] {
			seen[port+program] = true
			o, w := owner()
			all = append(all, mark(found{"port": port, "program": program}, o, w))
		}
	}
	if runtime.GOOS != "windows" {
		units := map[string][2]string{}
		for _, l := range output("ss", "-ltnpH") {
			f := strings.Fields(l)
			if len(f) < 4 {
				continue
			}
			_, program, _ := strings.Cut(l, `(("`)
			program, _, _ = strings.Cut(program, `"`)
			add(f[3][strings.LastIndex(f[3], ":")+1:], program, func() (string, string) { return linuxPortOwner(l, units) })
		}
		return
	}
	programs, services := parseTasklist(table(output("tasklist", "/svc", "/fo", "csv", "/nh")))
	parents := parentPids()
	for _, l := range output("netstat", "-ano", "-p", "TCP") {
		// A listening row is the one with nobody on the other end.
		if f := strings.Fields(l); len(f) == 5 && f[0] == "TCP" && strings.HasSuffix(f[2], ":0") {
			add(f[1][strings.LastIndex(f[1], ":")+1:], programs[f[4]], func() (string, string) { return windowsPortOwner(f[4], programs, services, parents) })
		}
	}
	return
}

// windowsPortOwner follows the process, then the processes that started it, to the first one that is a service.
func windowsPortOwner(pid string, programs map[string]string, services map[string][]string, parents map[uint32]uint32) (string, string) {
	n, _ := strconv.ParseUint(pid, 10, 32)
	service, origin, why := "", "", ""
	for cur, depth := uint32(n), 0; cur != 0 && depth < 6 && service == ""; cur, depth = parents[cur], depth+1 {
		for _, name := range services[strconv.FormatUint(uint64(cur), 10)] {
			o, w := serviceOrigin(name)
			if service == "" || rank(o) < rank(origin) {
				service, origin, why = name, o, w
			}
		}
	}
	_, system32 := os.Stat(filepath.Join(os.Getenv("windir"), "system32", programs[pid]))
	return winPortOrigin(programs[pid], processPath(uint32(n)), service, origin, why, system32 == nil)
}

// linuxPortOwner finds the unit a listening process belongs to from its cgroup, which only a process this account may see has in ss.
func linuxPortOwner(line string, units map[string][2]string) (string, string) {
	var cgroup []byte
	if _, rest, ok := strings.Cut(line, "pid="); ok {
		pid, _, _ := strings.Cut(rest, ",")
		cgroup, _ = os.ReadFile("/proc/" + pid + "/cgroup")
	}
	unit, session := cgroupUnit(string(cgroup))
	if _, ok := units[unit]; !ok && unit != "" {
		units[unit] = linuxOrigins([]string{unit})[unit]
	}
	return portUnitOrigin(unit, session, units[unit][0], units[unit][1])
}

func findContainers() (all []found) {
	for _, l := range output("docker", "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}") {
		if f := strings.Split(l, "\t"); len(f) >= 2 {
			one := mark(found{"name": f[0], "image": f[1]}, originYours, "Docker container")
			if len(f) > 2 {
				one["port"] = publishedPort(f[2])
			}
			all = append(all, one)
		}
	}
	return
}

var published = regexp.MustCompile(`:(\d+)->\d+/tcp`)

// publishedPort is the first TCP port a container offers on this machine, from docker's "0.0.0.0:8080->80/tcp".
func publishedPort(ports string) string {
	if m := published.FindStringSubmatch(ports); m != nil {
		return m[1]
	}
	return ""
}

func findSites() (all []found) {
	if runtime.GOOS == "windows" {
		for _, l := range output(filepath.Join(os.Getenv("windir"), "system32", "inetsrv", "appcmd.exe"), "list", "site") {
			if site, ok := parseIISSite(l); ok {
				all = append(all, site)
			}
		}
		return
	}
	for _, server := range []string{"nginx", "apache2"} {
		names, _ := filepath.Glob("/etc/" + server + "/sites-enabled/*")
		for _, n := range names {
			all = append(all, mark(found{"name": filepath.Base(n), "server": server}, originYours, "Site enabled in "+server))
		}
	}
	return
}

var iisSite = regexp.MustCompile(`^SITE "(.+)" \(id:\d+,bindings:([^,]*(?:,[^,]*)*),state:(\w+)\)`)

// parseIISSite reads a line of appcmd list site: SITE "name" (id:1,bindings:http/*:80:,state:Started).
// The address is the first http or https binding, on this machine.
func parseIISSite(l string) (found, bool) {
	m := iisSite.FindStringSubmatch(strings.TrimSpace(l))
	if m == nil {
		return nil, false
	}
	site := mark(found{"name": m[1], "server": "iis", "state": strings.ToLower(m[3])}, originYours, "Web site set up in IIS")
	for _, b := range strings.Split(m[2], ",") {
		scheme, rest, _ := strings.Cut(b, "/")
		parts := strings.Split(rest, ":")
		if (scheme != "http" && scheme != "https") || len(parts) != 3 {
			continue
		}
		host := "localhost"
		if parts[2] != "" {
			host = parts[2]
		}
		site["url"] = scheme + "://" + host
		if parts[1] != "" && !(scheme == "http" && parts[1] == "80") && !(scheme == "https" && parts[1] == "443") {
			site["url"] += ":" + parts[1]
		}
		site["url"] += "/"
		break
	}
	return site, true
}

func table(lines []string) [][]string {
	r := csv.NewReader(strings.NewReader(strings.Join(lines, "\n")))
	r.LazyQuotes, r.FieldsPerRecord = true, -1
	rows, _ := r.ReadAll()
	return rows
}

// declarations lists the dokkit.toml files in the folders and in the folders directly inside them.
func declarations(folders []string) (all []string) {
	for _, folder := range folders {
		here, _ := filepath.Glob(filepath.Join(folder, "dokkit.toml"))
		inside, _ := filepath.Glob(filepath.Join(folder, "*", "dokkit.toml"))
		all = append(append(all, here...), inside...)
	}
	return
}

var resultWait = 2 * time.Second

const updateWork = "dokkit:update"

// update is a built-in run. It fetches the newer copy the server holds and leaves
// it beside the spool. It replaces nothing: a person finishes the update on the machine.
func (c *client) update(run string) {
	said, code := "", 0
	path, sum, err := c.fetchUpdate()
	if err != nil {
		said, code = "Not fetched: "+err.Error(), 1
	} else {
		said = "The newer copy is at " + path + ".\nIts SHA-256 is " + sum + ".\n"
		if c.updateSha == "" {
			said += "Compare it with the hash published for that release before running it.\n"
		}
		said += finishUpdate(path)
	}
	fmt.Println(time.Now().Format("15:04:05"), "", said)
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said+"\n"), nil)
	body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": 0})
	c.postResult("/api/v1/work/"+run+"/result", body)
}

// postResult sends a run's result, trying again while the server cannot be reached or fails.
// A refusal by the server is final.
func (c *client) postResult(path string, body []byte) {
	for i := 0; i < 8; i++ {
		if status, err := c.call("POST", path, "application/json", body, nil); err == nil && status < 500 {
			return
		}
		if i < 7 {
			time.Sleep(resultWait << i)
		}
	}
}

// fetchUpdate leaves the newer copy in place and returns its SHA-256. A copy that does not
// match the hash in this machine's config is removed.
func (c *client) fetchUpdate() (string, string, error) {
	if runningAsService() && runtime.GOOS == "windows" {
		return "", "", errors.New("this machine runs dokkit as a service under Local Service, which does not fetch its own update: a file it could write is not one an administrator should run. Put the newer dokkit.exe on the machine, then from an administrator prompt run it with: service update")
	}
	if runningAsService() {
		return "", "", errors.New("this machine runs dokkit as a Linux service, which cannot fetch its own update. As root, install the newer program (run get.sh again), then run: dokkit service update")
	}
	name := "dokkit"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	dir := filepath.Join(filepath.Dir(c.spool), "update")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	path := filepath.Join(dir, name)
	file, err := os.OpenFile(path+".part", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o700)
	if err != nil {
		return "", "", err
	}
	hash := sha256.New()
	status, err := c.call("GET", "/api/v1/program/"+runtime.GOOS+"-"+runtime.GOARCH, "", nil, io.MultiWriter(file, hash))
	file.Close()
	if err != nil || status != 200 {
		return "", "", fmt.Errorf("the server has no newer copy for this kind of machine (%d)", status)
	}
	sum := hex.EncodeToString(hash.Sum(nil))
	if c.updateSha != "" && c.updateSha != sum {
		os.Remove(path + ".part")
		os.Remove(path)
		return "", "", fmt.Errorf("the fetched copy has SHA-256 %s, not the %s this machine expects", sum, c.updateSha)
	}
	return path, sum, os.Rename(path+".part", path)
}

// work asks the server for runs, holding each request open, and does them one at a time.
func (c *client) work() {
	go c.autoScan()
	go c.records()
	for {
		var job struct {
			Run  string
			Name string `json:"task"`
			To   []string
			Text string
		}
		status, err := c.call("GET", "/api/v1/work?wait=50", "", nil, &job)
		if status == 204 {
			continue
		}
		if err != nil || status != 200 {
			time.Sleep(15 * time.Second)
			continue
		}
		switch job.Name {
		case updateWork:
			c.update(job.Run)
		case imessageWork:
			c.imessage(job.Run, job.To, job.Text)
		case scanWork:
			c.lookAgain(job.Run)
		default:
			c.postResult("/api/v1/work/"+job.Run+"/result", []byte(`{"refused":"This program does not run that."}`))
		}
	}
}

// call makes one request with this machine's key and reads a JSON answer into `into`.
func (c *client) call(method, path, kind string, body []byte, into any) (int, error) {
	req, err := http.NewRequest(method, c.url+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	if kind != "" {
		req.Header.Set("Content-Type", kind)
	}
	res, err := (&http.Client{Timeout: 70 * time.Second, Transport: toServer}).Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if file, ok := into.(io.Writer); ok && res.StatusCode == 200 {
		// A file, not an answer to read.
		_, err = io.Copy(file, res.Body)
		return res.StatusCode, err
	}
	if into != nil && res.StatusCode == 200 {
		json.NewDecoder(res.Body).Decode(into)
	}
	return res.StatusCode, nil
}
