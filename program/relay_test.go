package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type sealingCase struct {
	UploadKey string          `json:"upload_key"`
	Mailbox   string          `json:"mailbox"`
	Envelope  json.RawMessage `json:"envelope"`
	Phones    []struct {
		Slot       string         `json:"slot"`
		Token      string         `json:"token"`
		SlotAnswer map[string]any `json:"slot_answer"`
	} `json:"phones"`
}

func loadSealing(t *testing.T) sealingCase {
	b, err := os.ReadFile(filepath.Join("..", "spec", "phone-cases", "sealing.json"))
	if err != nil {
		t.Fatal(err)
	}
	var c sealingCase
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

func relayWith(t *testing.T, c sealingCase) (*relayServer, *httptest.Server) {
	dir := t.TempDir()
	s := newRelayServer(dir)
	s.logOut = io.Discard
	os.MkdirAll(filepath.Join(dir, c.Mailbox), 0o700)
	if err := s.writeMailbox(c.Mailbox, &relayMailbox{Name: "test", KeySha256: sha256Hex(c.UploadKey)}); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func relayDo(t *testing.T, method, url, token string, body []byte, hdr ...string) (int, []byte, http.Header) {
	req, _ := http.NewRequest(method, url, bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b, res.Header
}

func withCounter(t *testing.T, env json.RawMessage, counter int, drop string) []byte {
	var m map[string]any
	json.Unmarshal(env, &m)
	m["counter"] = counter
	if drop != "" {
		delete(m["slots"].(map[string]any), drop)
	}
	b, _ := json.Marshal(m)
	return b
}

func TestRelayKeys(t *testing.T) {
	c := loadSealing(t)
	if !validKey(c.UploadKey, "dkr_") {
		t.Fatal("the fixture upload key should pass")
	}
	for _, p := range c.Phones {
		if !validKey(p.Token, "dkf_") {
			t.Fatal("the fixture fetch token should pass")
		}
	}
	if validKey(c.UploadKey[:len(c.UploadKey)-1]+"x", "dkr_") || validKey(c.UploadKey, "dkf_") || validKey("dkr_short", "dkr_") {
		t.Fatal("a mistyped key should fail")
	}
	k := randomKey("dkr_")
	if !validKey(k, "dkr_") {
		t.Fatalf("a made key should pass: %s", k)
	}
}

func TestRelayUploadAndFetch(t *testing.T) {
	c := loadSealing(t)
	_, ts := relayWith(t, c)
	url := ts.URL + "/m/" + c.Mailbox
	code, body, _ := relayDo(t, "PUT", url, c.UploadKey, c.Envelope)
	if code != 200 {
		t.Fatalf("upload: %d %s", code, body)
	}
	var up struct {
		OK    bool           `json:"ok"`
		Slots map[string]any `json:"slots"`
	}
	json.Unmarshal(body, &up)
	if !up.OK || len(up.Slots) != 2 || up.Slots[c.Phones[0].Slot] != nil {
		t.Fatalf("upload answer: %s", body)
	}
	for _, p := range c.Phones {
		code, body, h := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil)
		if code != 200 {
			t.Fatalf("fetch: %d %s", code, body)
		}
		var got map[string]any
		json.Unmarshal(body, &got)
		if !reflect.DeepEqual(got, p.SlotAnswer) {
			t.Fatalf("slot answer differs:\n%v\n%v", got, p.SlotAnswer)
		}
		if h.Get("ETag") != `"184223"` {
			t.Fatalf("etag %q", h.Get("ETag"))
		}
		if code, _, _ := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil, "If-None-Match", `"184223"`); code != 304 {
			t.Fatalf("matching etag answered %d", code)
		}
		if code, _, _ := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil, "If-None-Match", `"1"`); code != 200 {
			t.Fatalf("other etag answered %d", code)
		}
	}
	code, body, _ = relayDo(t, "PUT", url, c.UploadKey, withCounter(t, c.Envelope, 184224, ""))
	json.Unmarshal(body, &up)
	if code != 200 || up.Slots[c.Phones[0].Slot] == nil {
		t.Fatalf("the fetch time should come back: %s", body)
	}
}

func TestRelayNotFoundIsAlwaysTheSame(t *testing.T) {
	c := loadSealing(t)
	_, ts := relayWith(t, c)
	url := ts.URL + "/m/" + c.Mailbox
	relayDo(t, "PUT", url, c.UploadKey, c.Envelope)
	p := c.Phones[0]
	other := strings.Repeat("a", 32)
	var bodies []string
	for _, u := range [][2]string{
		{url + "/" + p.Slot, c.Phones[1].Token},
		{url + "/" + p.Slot, ""},
		{url + "/" + other, p.Token},
		{ts.URL + "/m/" + other + "/" + p.Slot, p.Token},
		{ts.URL + "/elsewhere", p.Token},
	} {
		code, body, _ := relayDo(t, "GET", u[0], u[1], nil)
		if code != 404 {
			t.Fatalf("%s answered %d", u[0], code)
		}
		bodies = append(bodies, string(body))
	}
	for _, b := range bodies {
		if b != bodies[0] {
			t.Fatalf("404 bodies differ: %q %q", b, bodies[0])
		}
	}
}

func TestRelayUploadRefusals(t *testing.T) {
	c := loadSealing(t)
	s, ts := relayWith(t, c)
	clock := time.Date(2026, 10, 14, 3, 0, 0, 0, time.UTC)
	s.now = func() time.Time { clock = clock.Add(61 * time.Second); return clock }
	url := ts.URL + "/m/" + c.Mailbox
	if code, _, _ := relayDo(t, "PUT", url, "dkr_wrong", c.Envelope); code != 401 {
		t.Fatalf("wrong key answered %d", code)
	}
	if code, _, _ := relayDo(t, "PUT", url, "", c.Envelope); code != 401 {
		t.Fatalf("no key answered %d", code)
	}
	if code, _, _ := relayDo(t, "PUT", url, c.UploadKey, c.Envelope); code != 200 {
		t.Fatal("first upload should work")
	}
	for _, n := range []int{184223, 5} {
		if code, _, _ := relayDo(t, "PUT", url, c.UploadKey, withCounter(t, c.Envelope, n, "")); code != 409 {
			t.Fatalf("counter %d answered %d", n, code)
		}
	}
	for _, b := range []string{`not json`, `{}`, `{"schema":2,"counter":9,"slots":{},"nonce":"a","body":"b"}`, `{"schema":1,"counter":"9","slots":{},"nonce":"a","body":"b"}`,
		`{"schema":1,"counter":9,"nonce":"a","body":"b"}`, `{"schema":1,"counter":9,"slots":{"x":{}},"nonce":"a","body":"b"}`, `{"schema":1,"counter":9,"slots":{},"body":"b"}`} {
		if code, _, _ := relayDo(t, "PUT", url, c.UploadKey, []byte(b)); code != 422 {
			t.Fatalf("%s answered %d", b, code)
		}
	}
	big := []byte(`{"schema":1,"counter":9,"slots":{},"nonce":"a","body":"` + strings.Repeat("x", relayMaxBody) + `"}`)
	if code, _, _ := relayDo(t, "PUT", url, c.UploadKey, big); code != 413 {
		t.Fatalf("oversize answered %d", code)
	}
}

func TestRelayDroppedSlotStopsAnswering(t *testing.T) {
	c := loadSealing(t)
	_, ts := relayWith(t, c)
	url := ts.URL + "/m/" + c.Mailbox
	relayDo(t, "PUT", url, c.UploadKey, c.Envelope)
	p := c.Phones[0]
	relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil)
	relayDo(t, "PUT", url, c.UploadKey, withCounter(t, c.Envelope, 184224, p.Slot))
	if code, _, _ := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil); code != 404 {
		t.Fatalf("dropped slot answered %d", code)
	}
	if code, _, _ := relayDo(t, "GET", url+"/"+c.Phones[1].Slot, c.Phones[1].Token, nil); code != 200 {
		t.Fatalf("kept slot answered %d", code)
	}
}

func TestRelayLimits(t *testing.T) {
	c := loadSealing(t)
	s, ts := relayWith(t, c)
	clock := time.Date(2026, 10, 14, 3, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return clock }
	url := ts.URL + "/m/" + c.Mailbox
	for i := 0; i < 12; i++ {
		if code, _, _ := relayDo(t, "PUT", url, c.UploadKey, withCounter(t, c.Envelope, 10+i, "")); code != 200 {
			t.Fatalf("upload %d answered %d", i, code)
		}
	}
	code, _, h := relayDo(t, "PUT", url, c.UploadKey, withCounter(t, c.Envelope, 30, ""))
	if code != 429 || h.Get("Retry-After") == "" {
		t.Fatalf("thirteenth upload answered %d", code)
	}
	p := c.Phones[0]
	for i := 0; i < 30; i++ {
		if code, _, _ := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil); code != 200 {
			t.Fatalf("fetch %d answered %d", i, code)
		}
	}
	code, _, h = relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil)
	if code != 429 || h.Get("Retry-After") == "" {
		t.Fatalf("31st fetch answered %d", code)
	}
	if code, _, _ := relayDo(t, "GET", url+"/"+c.Phones[1].Slot, c.Phones[1].Token, nil); code != 200 {
		t.Fatalf("another slot answered %d", code)
	}
	clock = clock.Add(61 * time.Second)
	if code, _, _ := relayDo(t, "GET", url+"/"+p.Slot, p.Token, nil); code != 200 {
		t.Fatalf("after a minute answered %d", code)
	}
}

func TestRelayAtomicWrite(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.json")
	for _, v := range []string{"one", "two"} {
		if err := writeFile(p, []byte(v)); err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(p); string(b) != v {
			t.Fatalf("read %q", b)
		}
	}
	if es, _ := os.ReadDir(filepath.Dir(p)); len(es) != 1 {
		t.Fatalf("a temporary file was left: %v", es)
	}
}

func TestRelayCommands(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DOKKIT_RELAY_DIR", filepath.Join(dir, "r"))
	out, _ := capture(t, func() {
		if cli([]string{"relay", "add", "home"}) != 0 {
			t.Error("add failed")
		}
	})
	if !strings.Contains(out, "Address: /m/") || !strings.Contains(out, "dkr_") {
		t.Fatalf("add printed %q", out)
	}
	if _, e := capture(t, func() {
		if cli([]string{"relay", "add", "home"}) != 1 {
			t.Error("a second add of the name should fail")
		}
	}); !strings.Contains(e, "already") {
		t.Fatalf("stderr %q", e)
	}
	out, _ = capture(t, func() { cli([]string{"relay", "list"}) })
	if !strings.Contains(out, "home") || !strings.Contains(out, "last upload never") {
		t.Fatalf("list printed %q", out)
	}
	capture(t, func() {
		if cli([]string{"relay", "remove", "home"}) != 0 || cli([]string{"relay", "remove", "home"}) != 1 {
			t.Error("remove should work once")
		}
	})
	for _, a := range [][]string{{"relay"}, {"relay", "serve"}, {"relay", "serve", "--http"}, {"relay", "add"},
		{"relay", "serve", "--open-signup"}, {"relay", "serve", "--http", "127.0.0.1:0", "--max-mailboxes", "0"}, {"relay", "serve", "--http", "127.0.0.1:0", "extra"}} {
		capture(t, func() {
			if cli(a) != 2 {
				t.Errorf("%v should exit 2", a)
			}
		})
	}
}

func signupRelay(t *testing.T) (*relayServer, *httptest.Server) {
	s := newRelayServer(t.TempDir())
	s.logOut = io.Discard
	s.openSignup = true
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	return s, ts
}

func TestRelaySignup(t *testing.T) {
	c := loadSealing(t)
	_, ts := signupRelay(t)
	code, body, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil)
	if code != 201 {
		t.Fatalf("signup: %d %s", code, body)
	}
	var got struct{ Address, Mailbox, Key string }
	json.Unmarshal(body, &got)
	if !validID(got.Mailbox) || got.Address != "/m/"+got.Mailbox || !validKey(got.Key, "dkr_") {
		t.Fatalf("signup answer: %s", body)
	}
	if code, body, _ := relayDo(t, "PUT", ts.URL+got.Address, got.Key, c.Envelope); code != 200 {
		t.Fatalf("upload to a signed-up mailbox: %d %s", code, body)
	}

	closed := newRelayServer(t.TempDir())
	closed.logOut = io.Discard
	cs := httptest.NewServer(closed.handler())
	defer cs.Close()
	if code, _, _ := relayDo(t, "POST", cs.URL+"/mailboxes", "", nil); code != 404 {
		t.Fatalf("signup on a closed relay answered %d", code)
	}
}

func TestRelaySignupLimits(t *testing.T) {
	s, ts := signupRelay(t)
	clock := time.Date(2026, 10, 14, 3, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return clock }
	for i := 0; i < 3; i++ {
		if code, _, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil, "X-Forwarded-For", "198.51.100.7"); code != 201 {
			t.Fatalf("signup %d answered %d", i, code)
		}
	}
	code, _, h := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil, "X-Forwarded-For", "203.0.113.9, 198.51.100.7")
	if code != 429 || h.Get("Retry-After") == "" {
		t.Fatalf("fourth signup from one address answered %d", code)
	}
	if code, _, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil, "X-Forwarded-For", "198.51.100.8"); code != 201 {
		t.Fatalf("another address answered %d", code)
	}
	clock = clock.Add(61 * time.Minute)
	if code, _, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil, "X-Forwarded-For", "198.51.100.7"); code != 201 {
		t.Fatalf("after an hour answered %d", code)
	}
	s.maxMailboxes = 5
	if code, _, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil, "X-Forwarded-For", "198.51.100.9"); code != 503 {
		t.Fatalf("a full relay answered %d", code)
	}
}

func TestRelayClientIP(t *testing.T) {
	for _, c := range [][3]string{
		{"127.0.0.1:5000", "198.51.100.7", "198.51.100.7"},
		{"127.0.0.1:5000", "", "127.0.0.1"},
		{"192.0.2.1:5000", "198.51.100.7", "192.0.2.1"},
		{"[2001:db8:1:2:3:4:5:6]:5000", "", "2001:db8:1:2::"},
	} {
		r := httptest.NewRequest("POST", "/mailboxes", nil)
		r.RemoteAddr = c[0]
		if c[1] != "" {
			r.Header.Set("X-Forwarded-For", c[1])
		}
		if got := clientIP(r); got != c[2] {
			t.Fatalf("%v gave %q", c, got)
		}
	}
}

func TestRelaySweep(t *testing.T) {
	c := loadSealing(t)
	s, ts := signupRelay(t)
	clock := time.Date(2026, 10, 14, 3, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return clock }
	var ids [2]struct{ Address, Mailbox, Key string }
	for i := range ids {
		_, body, _ := relayDo(t, "POST", ts.URL+"/mailboxes", "", nil)
		json.Unmarshal(body, &ids[i])
	}
	clock = clock.Add(20 * 24 * time.Hour)
	relayDo(t, "PUT", ts.URL+ids[1].Address, ids[1].Key, c.Envelope)
	clock = clock.Add(11 * 24 * time.Hour)
	if n := s.sweep(relayIdleDays * 24 * time.Hour); n != 1 {
		t.Fatalf("swept %d", n)
	}
	if _, err := os.Stat(filepath.Join(s.dir, ids[0].Mailbox)); !os.IsNotExist(err) {
		t.Fatal("the idle mailbox should be gone")
	}
	if code, _, _ := relayDo(t, "GET", ts.URL+ids[1].Address+"/"+c.Phones[0].Slot, c.Phones[0].Token, nil); code != 200 {
		t.Fatalf("the used mailbox answered %d", code)
	}
	if len(s.hits) != 1 {
		t.Fatalf("old hits should be forgotten: %v", s.hits)
	}
}
