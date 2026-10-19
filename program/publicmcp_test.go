package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func publicCall(t *testing.T, h http.Handler, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest("POST", "/", strings.NewReader(body))
	req.RemoteAddr = "203.0.113.5:4000"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func publicTool(t *testing.T, name string, args map[string]any) (string, bool) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": map[string]any{"name": name, "arguments": args}})
	_, out := publicCall(t, newPublicMCP(), string(b))
	res := out["result"].(map[string]any)
	return res["content"].([]any)[0].(map[string]any)["text"].(string), res["isError"] == true
}

func TestPublicMCPHandshake(t *testing.T) {
	h := newPublicMCP()
	_, out := publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`)
	res := out["result"].(map[string]any)
	if res["protocolVersion"] != "2025-03-26" || res["serverInfo"].(map[string]any)["name"] != "dokkit-help" {
		t.Fatalf("initialize: %v", out)
	}
	if _, out = publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`); out["result"].(map[string]any)["protocolVersion"] != "2025-06-18" {
		t.Fatalf("default version: %v", out)
	}
	if code, _ := publicCall(t, h, `{"jsonrpc":"2.0","method":"notifications/initialized"}`); code != 202 {
		t.Fatalf("notification answered %d", code)
	}
	if _, out = publicCall(t, h, `{"jsonrpc":"2.0","id":"a","method":"ping"}`); out["id"] != "a" || out["result"] == nil {
		t.Fatalf("ping: %v", out)
	}
	_, out = publicCall(t, h, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	var names []string
	for _, x := range out["result"].(map[string]any)["tools"].([]any) {
		names = append(names, x.(map[string]any)["name"].(string))
	}
	if strings.Join(names, ",") != "check_file,example_file,library_calls,explain_error" {
		t.Fatalf("tools: %v", names)
	}
	if _, out = publicCall(t, h, `{"jsonrpc":"2.0","id":3,"method":"nope"}`); out["error"].(map[string]any)["code"] != float64(-32601) {
		t.Fatalf("unknown method: %v", out)
	}
	if _, out = publicCall(t, h, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}`); out["error"].(map[string]any)["code"] != float64(-32602) {
		t.Fatalf("unknown tool: %v", out)
	}
	if code, _ := publicCall(t, h, `[1,2]`); code != 400 {
		t.Fatalf("not a request answered %d", code)
	}
}

func TestPublicMCPHTTP(t *testing.T) {
	h := newPublicMCP()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "claude mcp add --transport http dokkit-help https://mcp.dokkit.dev/") {
		t.Fatalf("GET /: %d %s", rec.Code, rec.Body)
	}
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Accept", "text/event-stream")
	rec = httptest.NewRecorder()
	if h.ServeHTTP(rec, req); rec.Code != 405 {
		t.Fatalf("stream asked: %d", rec.Code)
	}
	if code, out := publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"`+strings.Repeat("a", publicMCPMaxBody)+`"}}`); code != 413 || out["error"] == nil {
		t.Fatalf("big body: %d", code)
	}
}

func TestPublicMCPRateLimit(t *testing.T) {
	h := newPublicMCP()
	at := time.Unix(1_800_000_000, 0)
	h.now = func() time.Time { return at }
	for range publicMCPPerMinute {
		if code, _ := publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 200 {
			t.Fatalf("under the limit: %d", code)
		}
	}
	if code, _ := publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 429 {
		t.Fatalf("over the limit: %d", code)
	}
	// Behind a proxy on this host, each forwarded address has its own minute.
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`))
	req.RemoteAddr = "127.0.0.1:5000"
	req.Header.Set("X-Forwarded-For", "198.51.100.7")
	rec := httptest.NewRecorder()
	if h.ServeHTTP(rec, req); rec.Code != 200 {
		t.Fatalf("other address: %d", rec.Code)
	}
	at = at.Add(time.Minute)
	if code, _ := publicCall(t, h, `{"jsonrpc":"2.0","id":1,"method":"ping"}`); code != 200 {
		t.Fatalf("a minute later: %d", code)
	}
}

func TestPublicMCPCheckFile(t *testing.T) {
	text, isErr := publicTool(t, "check_file", map[string]any{"text": examples["web"]})
	var out map[string]any
	json.Unmarshal([]byte(text), &out)
	if isErr || out["verdict"] != "accepted" || out["service"] != "billing-api" || out["sends"].(map[string]any)["schema"] != float64(1) {
		t.Fatalf("web example: %s", text)
	}
	text, _ = publicTool(t, "check_file", map[string]any{"text": "schema = 1\n[service]\nid = \"Bad Id\"\n"})
	json.Unmarshal([]byte(text), &out)
	if out["verdict"] != "refused" || !strings.Contains(out["error"].(string), "service.id may hold") || out["fix"] == "" {
		t.Fatalf("bad id: %s", text)
	}
	if _, isErr = publicTool(t, "check_file", map[string]any{}); !isErr {
		t.Fatal("missing text is not an error")
	}
}

func TestPublicMCPExamplesPassCheck(t *testing.T) {
	for _, kind := range exampleKinds() {
		if r := checkResult(examples[kind]); r["ok"] != true {
			t.Fatalf("example %s is refused: %v", kind, r["error"])
		}
		if exampleNotes[kind] == "" {
			t.Fatalf("example %s has no note", kind)
		}
		if text, isErr := publicTool(t, "example_file", map[string]any{"kind": kind}); isErr || !strings.Contains(text, "schema = 1") {
			t.Fatalf("example_file %s: %s", kind, text)
		}
	}
	if _, isErr := publicTool(t, "example_file", map[string]any{"kind": "spaceship"}); !isErr {
		t.Fatal("unknown kind is not an error")
	}
}

func TestPublicMCPLibraryCalls(t *testing.T) {
	for _, l := range libraries {
		if l.Install == "" || l.Start == "" || l.Beat == "" || l.Job == "" || l.Capture == "" || l.Logging == "" {
			t.Fatalf("%s is missing a call", l.Language)
		}
	}
	for alias, lang := range languageAliases {
		if _, err := libraryCalls(alias); err != nil {
			t.Fatalf("%s -> %s: %v", alias, lang, err)
		}
	}
	text, isErr := publicTool(t, "library_calls", map[string]any{"language": "Python"})
	if isErr || !strings.Contains(text, "dokkit.beat(") {
		t.Fatalf("python: %s", text)
	}
	if _, isErr = publicTool(t, "library_calls", map[string]any{"language": "cobol"}); !isErr {
		t.Fatal("unknown language is not an error")
	}
}

// Every refusal the checker can write has its own explanation, not the general one.
func TestPublicMCPExplainsEveryRefusal(t *testing.T) {
	head := "schema = 1\n[service]\nid = \"a\"\n"
	files := []string{
		"[service]\nid = \"a\"\n",
		"schema = 1\n",
		"schema = 1\n[service]\nid = \"A\"\n",
		head + "kind = \"robot\"\n",
		head + "[[job]]\nschedule = \"@daily\"\n",
		head + "[[job]]\nid = \"j\"\nschedule = \"@reboot\"\n",
		head + "[[check]]\ntype = \"tcp\"\nport = 1\nfail_after = 0\n",
		head + "[[check]]\ntype = \"tcp\"\nport = 1\nevery = \"soon\"\n",
		head + "[[check]]\ntype = \"tcp\"\nport = 1\nat_least = 2\n",
		head + "[[check]]\ntype = \"tcp\"\nport = 1\nstatus = 200\n",
		head + "[[check]]\ntype = \"http\"\nurl = \"http://x\"\nstatus = 99\n",
		head + "[[check]]\ntype = \"tcp\"\nport = 1\nslow = \"1s\"\n",
		head + "[[check]]\ntype = \"http\"\nurl = \"http://x\"\nslow = \"-1s\"\n",
		head + "[[check]]\ntype = \"http\"\nurl = \"http://x\"\nslow = \"9s\"\n",
		head + "[[check]]\ntype = \"http\"\n",
		head + "[[check]]\ntype = \"tcp\"\n",
		head + "[[check]]\ntype = \"systemd\"\nname = \"x\"\ncommand_has = \"y\"\n",
		head + "[[check]]\ntype = \"process\"\n",
		head + "[[check]]\ntype = \"ping\"\n",
		head + "[stats]\nkey_env = \"SECRET\"\n",
		head + "[stats]\nurl = \"ftp://x\"\n",
		head + "[logs]\npath = \"../other/*.log\"\n",
		"schema = 1\n[service\n",
	}
	general := explainError("")
	seen := map[string]bool{}
	for _, f := range files {
		r := checkResult(f)
		if r["ok"] != false {
			t.Fatalf("accepted:\n%s", f)
		}
		msg := r["error"].(string)
		if e := explainError(msg); e == general {
			t.Fatalf("no explanation for %q", msg)
		}
		seen[explainError(msg).Explanation] = true
	}
	if len(seen) != len(refusals)-1 {
		t.Fatalf("%d of %d refusals produced", len(seen), len(refusals)-1)
	}
	text, _ := publicTool(t, "explain_error", map[string]any{"error": "dokkit.toml: check http: needs a url"})
	if !strings.Contains(text, "url =") {
		t.Fatalf("explain_error: %s", text)
	}
	if text, _ = publicTool(t, "explain_error", map[string]any{"error": "something else"}); !strings.Contains(text, "dokkit doctor") {
		t.Fatalf("general answer: %s", text)
	}
}
