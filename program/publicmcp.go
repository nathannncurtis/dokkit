package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	publicMCPMaxBody   = 64 << 10
	publicMCPPerMinute = 60
	publicMCPNote      = `Dokkit's public MCP: help for writing and checking dokkit.toml files and wiring the client libraries.
No account, nothing stored, nothing sent anywhere.

Connect with Claude Code:
  claude mcp add --transport http dokkit-help https://mcp.dokkit.dev/

Any other MCP client: streamable HTTP, JSON-RPC 2.0 by POST to this address.
Tools: check_file, example_file, library_calls, explain_error.
`
)

type publicMCPTool struct {
	name, description string
	properties        map[string]any
	run               func(arg string) (any, error)
	arg               string
}

var publicMCPTools = []publicMCPTool{
	{"check_file", "Checks the text of a dokkit.toml the way `dokkit check` does, without running any check. Answers accepted or refused with the program's own words, what will be watched, and the JSON `dokkit apply` would send.",
		map[string]any{"text": map[string]any{"type": "string", "description": "The whole dokkit.toml."}}, func(s string) (any, error) { return checkResult(s), nil }, "text"},
	{"example_file", "A correct starting dokkit.toml for a kind of service: " + strings.Join(exampleKinds(), ", ") + ". Change the ids, names, addresses and paths to the app's own.",
		map[string]any{"kind": map[string]any{"type": "string", "enum": exampleKinds()}}, exampleFile, "kind"},
	{"library_calls", "How to install a Dokkit client library for a language, and its calls for start, beat, job, capturing an error and logging.",
		map[string]any{"language": map[string]any{"type": "string", "description": "One of " + strings.Join(libraryLanguages(), ", ") + "."}}, libraryCalls, "language"},
	{"explain_error", "Explains a refusal from `dokkit check` (or check_file) in plain words, with the fix.",
		map[string]any{"error": map[string]any{"type": "string", "description": "The refusal text, as printed."}}, func(s string) (any, error) { return explainError(s), nil }, "error"},
}

// checkResult is `dokkit check` without running the checks: it reads no files and makes no requests.
func checkResult(text string) map[string]any {
	d, err := parseDeclaration("dokkit.toml", text)
	if err == nil {
		err = d.misplaced()
	}
	if err != nil {
		e := explainError(err.Error())
		return map[string]any{"ok": false, "verdict": "refused", "error": err.Error(), "explanation": e.Explanation, "fix": e.Fix}
	}
	checks := []map[string]any{}
	for i := range d.Check {
		c := &d.Check[i]
		runs, _ := c.problem()
		one := map[string]any{"name": c.name, "type": c.Type, "target": c.target(), "runs": runs}
		if runs {
			one["every"] = c.every().String()
		}
		checks = append(checks, one)
	}
	jobs := []string{}
	for _, j := range d.Job {
		jobs = append(jobs, j.ID)
	}
	return map[string]any{"ok": true, "verdict": "accepted", "service": d.Service.ID, "checks": checks, "jobs": jobs, "logs": d.Logs.Path, "sends": d.raw,
		"note": "runs true: dokkit watch makes the check on the machine. runs false: the app reports it, through a client library or the stats address. An app key's dokkit apply keeps only beat and custom checks."}
}

var examples = map[string]string{
	"web": `schema = 1

[service]
id = "billing-api"
name = "Billing API"
kind = "service"
environment = "production"

[[check]]
type = "http"
url = "http://localhost:8080/healthz"
every = "30s"
timeout = "5s"
slow = "2s"

[logs]
path = "logs/*.jsonl"
`,
	"worker": `schema = 1

[service]
id = "image-resizer"
name = "Image resizer"
kind = "service"
environment = "production"

[[check]]
type = "process"
name = "python"
command_has = "image-resizer"
at_least = 4

[[check]]
type = "beat"
name = "queue-loop"
every = "1m"
`,
	"windows": `schema = 1

[service]
id = "print-spooler-bridge"
name = "Print spooler bridge"
kind = "service"
environment = "production"

[[check]]
type = "windows-service"
name = "PrintBridge"

[[check]]
type = "tcp"
port = 9100
`,
	"linux": `schema = 1

[service]
id = "order-sync"
name = "Order sync"
kind = "service"
environment = "production"

[[check]]
type = "systemd"
name = "order-sync.service"

[logs]
path = "logs/*.log"
`,
	"job": `schema = 1

[service]
id = "nightly-reports"
name = "Nightly reports"
kind = "job"
environment = "production"

[[job]]
id = "nightly-purge"
schedule = "0 1 * * *"
grace = "30m"
max_runtime = "1h"
`,
	"dependency": `schema = 1

[service]
id = "orders-db"
name = "Orders database"
kind = "dependency"
environment = "production"

[[check]]
type = "tcp"
host = "db.example.internal"
port = 5432
`,
	"certificate": `schema = 1

[service]
id = "shop-site"
name = "Shop site"
kind = "service"
environment = "production"

[[check]]
type = "http"
url = "https://shop.example.com/"
status = "200-299"

[[check]]
type = "expiry"
date_from = "https://shop.example.com"
`,
}

var exampleNotes = map[string]string{
	"web":         "An HTTP service: up when /healthz answers under 400, degraded when slower than 2 s. Its JSON log lines are sent.",
	"worker":      "A program that runs as several processes: down with none, degraded with fewer than 4. The beat is sent by the app's loop through a client library (library_calls).",
	"windows":     "A Windows service and the port it listens on.",
	"linux":       "A systemd unit.",
	"job":         "A scheduled job, five-field cron in UTC. Run it as dokkit run --job nightly-purge -- <command>, or report it from a client library.",
	"dependency":  "Something outside the app that it depends on, checked by its port.",
	"certificate": "A site and its certificate: degraded 30 days before the certificate runs out, down once it has.",
}

func exampleKinds() []string {
	kinds := make([]string, 0, len(examples))
	for k := range examples {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	return kinds
}

func exampleFile(kind string) (any, error) {
	kind = strings.ToLower(strings.TrimSpace(kind))
	if kind == "service" || kind == "http" || kind == "api" || kind == "website" {
		kind = "web"
	}
	text, ok := examples[kind]
	if !ok {
		return nil, fmt.Errorf("no example for %q. There are: %s.", kind, strings.Join(exampleKinds(), ", "))
	}
	return map[string]any{"kind": kind, "about": exampleNotes[kind], "dokkit.toml": text}, nil
}

func libraryLanguages() []string {
	var out []string
	for _, l := range libraries {
		out = append(out, l.Language)
	}
	return out
}

func libraryCalls(language string) (any, error) {
	language = strings.ToLower(strings.TrimSpace(language))
	if a, ok := languageAliases[language]; ok {
		language = a
	}
	for _, l := range libraries {
		if l.Language == language {
			return l, nil
		}
	}
	return nil, fmt.Errorf("no library for %q. There are: %s.", language, strings.Join(libraryLanguages(), ", "))
}

type explained struct {
	Explanation string `json:"explanation"`
	Fix         string `json:"fix"`
}

// refusals pairs a piece of each refusal the checker can produce with what it means. Order matters: the first match wins.
var refusals = []struct {
	has string
	explained
}{
	{"add schema = 1", explained{"The file has no schema line, or a schema other than 1.", "Make the first line `schema = 1`."}},
	{"[service] needs an id", explained{"Every file describes one service and needs its id.", "Add a [service] table with `id = \"my-app\"`."}},
	{"service.id may hold", explained{"The service id has a character that is not allowed. It must start with a lower-case letter or digit and hold only lower-case letters, digits, dots, dashes and underscores.", "Use an id such as `billing-api`. Pick it once: the id never changes after it is in use."}},
	{"service.kind is one of", explained{"`kind` in [service] is not one Dokkit knows.", "Use service, job, dependency or app, or leave kind out."}},
	{"Every job needs an id", explained{"A [[job]] table has no `id`, or its id is not text.", "Give every [[job]] an `id = \"nightly-purge\"`; it is the name `dokkit run --job` uses."}},
	{"A job's schedule is not a cron line", explained{"A job's `schedule` cannot be read. It is five cron fields read as UTC (minute hour day month weekday), or @hourly, @daily, @weekly, @monthly or @yearly. @reboot has no time and is refused.", "Write it like `schedule = \"0 1 * * *\"` (01:00 UTC every day), or leave schedule out."}},
	{"fail_after is a whole number", explained{"`fail_after` on a check is the number of bad results in a row before an issue opens.", "Use a whole number from 1 to 100, such as `fail_after = 3`, or leave it out for 3."}},
	{"is not a time such as 30s or 5m", explained{"`every`, `timeout` or `slow` is not a length of time.", "Write a number with a unit: \"500ms\", \"30s\", \"5m\", \"1h\"."}},
	{"at_least is a number of processes", explained{"`at_least` is the fewest matching processes that count as healthy; it is for a process check only, and 1 or more.", "Move it to a `type = \"process\"` check, or make it 1 or more."}},
	{"status is only for an http check", explained{"`status` sets which HTTP answers are healthy, so only an http check takes it.", "Remove `status`, or make the check `type = \"http\"`."}},
	{"status is a code such as", explained{"`status` is not a code, a range or a list of those between 100 and 599.", "Use `status = 200`, `status = \"200-299\"` or `status = [200, \"400-403\"]`."}},
	{"slow is only for an http check", explained{"`slow` marks a slow answer as degraded, which only an http check has.", "Remove `slow`, or make the check `type = \"http\"`."}},
	{"slow must be more than zero", explained{"`slow` is zero or less.", "Give a length above zero, such as `slow = \"2s\"`."}},
	{"must be less than timeout", explained{"`slow` is as long as `timeout` or longer, so no answer could ever show as slow. timeout is 5s when not set.", "Lower `slow`, or raise `timeout` above it."}},
	{"needs a url", explained{"An http check has no `url`.", "Add `url = \"http://localhost:8080/healthz\"` (the address that answers when the app is healthy)."}},
	{"needs a port", explained{"A tcp check has no `port`.", "Add `port = 5432`, and `host` when it is not localhost."}},
	{"command_has is only for a process check", explained{"`command_has` matches a piece of a process's path or command line, so only a process check takes it.", "Remove it, or make the check `type = \"process\"`."}},
	{"needs a name", explained{"A process, windows-service or systemd check has no `name`: the program's file name, the Windows service name, or the unit.", "Add `name = \"...\"`, for example `name = \"python\"`, `name = \"PrintBridge\"` or `name = \"order-sync.service\"`."}},
	{"unknown type", explained{"A check's `type` is not one this program knows.", "Use http, tcp, process, windows-service, systemd, expiry, beat, stats, threshold or custom."}},
	{"key_env must name a variable", explained{"`key_env` in [stats] names the environment variable that holds the stats key, and only variables starting with DOKKIT_STATS_ may be sent. The key itself never goes in the file.", "Rename the variable, such as `key_env = \"DOKKIT_STATS_KEY\"`."}},
	{"is not an http or https address", explained{"`url` in [stats] is not a full http or https address.", "Write it in full, such as `url = \"http://localhost:8080/internal/stats\"`."}},
	{"must stay inside the folder of its dokkit.toml", explained{"`path` in [logs] leaves the folder the dokkit.toml is in, by `..` or an absolute path elsewhere.", "Put the logs under the app's folder and use a relative path such as `path = \"logs/*.jsonl\"`."}},
	{"toml:", explained{"The file is not valid TOML, or a field has the wrong type (for example a number in quotes where a number is expected). The line number is in the message.", "Fix the line it names: strings in double quotes, numbers without quotes, [[check]] and [[job]] for each item of a list."}},
	{"the server refused", explained{"`dokkit apply` reached the server and it refused the file or the key. The status code and the server's words follow.", "401 or 403: the key is wrong or may not declare this service (an app key declares only its own service, with beat and custom checks). 422: fix what the server's words name."}},
}

func explainError(text string) explained {
	for _, r := range refusals {
		if strings.Contains(text, r.has) {
			return r.explained
		}
	}
	return explained{"That is not a refusal this checker writes. It may come from the server, the network or the operating system.",
		"Run check_file on the file. If it is accepted, the problem is in reaching the server: run `dokkit doctor` on the machine."}
}

type publicMCP struct {
	mu   sync.Mutex
	hits map[string][]time.Time
	now  func() time.Time
}

func newPublicMCP() *publicMCP {
	return &publicMCP{hits: map[string][]time.Time{}, now: time.Now}
}

// allow keeps a sliding minute per address.
func (p *publicMCP) allow(ip string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	if len(p.hits) > 50000 {
		p.hits = map[string][]time.Time{}
	}
	recent := slices.DeleteFunc(p.hits[ip], func(t time.Time) bool { return now.Sub(t) >= time.Minute })
	if len(recent) >= publicMCPPerMinute {
		p.hits[ip] = recent
		return false
	}
	p.hits[ip] = append(recent, now)
	return true
}

func (p *publicMCP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" && r.URL.Path != "/mcp" {
		http.NotFound(w, r)
		return
	}
	if !p.allow(clientIP(r)) {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "At most 60 requests a minute.", http.StatusTooManyRequests)
		return
	}
	switch r.Method {
	case http.MethodGet:
		// No server-sent stream: a client asking for one is told so, a person gets the note.
		if strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, publicMCPNote)
	case http.MethodPost:
		p.rpc(w, r)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (p *publicMCP) rpc(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, publicMCPMaxBody))
	reply := func(status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(v)
	}
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			reply(http.StatusRequestEntityTooLarge, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32600, "message": "The request is over 64 KB."}})
			return
		}
		reply(http.StatusBadRequest, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32700, "message": "Could not read the request."}})
		return
	}
	var req struct {
		Method string          `json:"method"`
		ID     json.RawMessage `json:"id"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(body, &req) != nil || req.Method == "" {
		reply(http.StatusBadRequest, map[string]any{"jsonrpc": "2.0", "id": nil, "error": map[string]any{"code": -32600, "message": "Not a request."}})
		return
	}
	result, code, message := p.answer(req.Method, req.Params)
	if len(req.ID) == 0 || string(req.ID) == "null" {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	if code != 0 {
		reply(http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": req.ID, "error": map[string]any{"code": code, "message": message}})
		return
	}
	reply(http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
}

func (p *publicMCP) answer(method string, raw json.RawMessage) (any, int, string) {
	var params struct {
		ProtocolVersion string         `json:"protocolVersion"`
		Name            string         `json:"name"`
		Arguments       map[string]any `json:"arguments"`
	}
	json.Unmarshal(raw, &params)
	switch method {
	case "initialize":
		v := params.ProtocolVersion
		if v == "" {
			v = "2025-06-18"
		}
		return map[string]any{"protocolVersion": v, "capabilities": map[string]any{"tools": map[string]any{}},
			"serverInfo":   map[string]any{"name": "dokkit-help", "version": version},
			"instructions": "Help for Dokkit: check a dokkit.toml, start one from an example, find a client library's calls, explain a refusal. Nothing is stored or sent anywhere. The file format is at https://dokkit.dev."}, 0, ""
	case "ping":
		return map[string]any{}, 0, ""
	case "tools/list":
		tools := []map[string]any{}
		for _, t := range publicMCPTools {
			tools = append(tools, map[string]any{"name": t.name, "description": t.description,
				"inputSchema": map[string]any{"type": "object", "properties": t.properties, "required": []string{t.arg}},
				"annotations": map[string]any{"readOnlyHint": true, "openWorldHint": false}})
		}
		return map[string]any{"tools": tools}, 0, ""
	case "tools/call":
		i := slices.IndexFunc(publicMCPTools, func(t publicMCPTool) bool { return t.name == params.Name })
		if i < 0 {
			return nil, -32602, "No tool called " + params.Name + "."
		}
		t := publicMCPTools[i]
		arg, ok := params.Arguments[t.arg].(string)
		if !ok {
			return toolText(t.arg+" is required, as text.", true), 0, ""
		}
		out, err := t.run(arg)
		if err != nil {
			return toolText(err.Error(), true), 0, ""
		}
		b, _ := json.MarshalIndent(out, "", "  ")
		return toolText(string(b), false), 0, ""
	}
	return nil, -32601, "No method called " + method + "."
}

func toolText(text string, isError bool) map[string]any {
	out := map[string]any{"content": []map[string]any{{"type": "text", "text": text}}}
	if isError {
		out["isError"] = true
	}
	return out
}

func publicMCPCommand(args []string) int {
	if len(args) != 2 || args[0] != "--http" {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	srv := &http.Server{Addr: args[1], Handler: newPublicMCP(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 15 * time.Second, IdleTimeout: time.Minute, MaxHeaderBytes: 16 << 10}
	fmt.Println("dokkit public MCP on http://" + args[1])
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	return 0
}
