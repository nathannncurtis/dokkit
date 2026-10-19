package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeCF struct {
	mu   sync.Mutex
	recs map[string]cfRecord
	n    int
	ops  []string
}

func (f *fakeCF) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer cf-token" {
		w.WriteHeader(403)
		fmt.Fprint(w, `{"success":false,"errors":[{"message":"Authentication error"}]}`)
		return
	}
	ok := func(v any) { json.NewEncoder(w).Encode(map[string]any{"success": true, "result": v}) }
	path := strings.TrimPrefix(r.URL.Path, "/zones/zone1/dns_records")
	f.ops = append(f.ops, r.Method+" "+path)
	switch {
	case r.Method == "GET" && path == "":
		var out []cfRecord
		for _, rec := range f.recs {
			if rec.Name == r.URL.Query().Get("name") {
				out = append(out, rec)
			}
		}
		ok(out)
	case r.Method == "POST" && path == "":
		var rec cfRecord
		json.NewDecoder(r.Body).Decode(&rec)
		f.n++
		rec.ID = fmt.Sprintf("r%d", f.n)
		f.recs[rec.ID] = rec
		ok(rec)
	case r.Method == "PUT" || r.Method == "DELETE":
		id := strings.TrimPrefix(path, "/")
		if _, found := f.recs[id]; !found {
			w.WriteHeader(404)
			fmt.Fprint(w, `{"success":false,"errors":[{"message":"Record does not exist."}]}`)
			return
		}
		if r.Method == "DELETE" {
			delete(f.recs, id)
			ok(map[string]string{"id": id})
			return
		}
		var rec cfRecord
		json.NewDecoder(r.Body).Decode(&rec)
		rec.ID = id
		f.recs[id] = rec
		ok(rec)
	default:
		w.WriteHeader(400)
	}
}

func (f *fakeCF) records() map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string]string{}
	for _, r := range f.recs {
		out[r.Type+" "+r.Name] += r.Content + ";"
	}
	return out
}

func (f *fakeCF) take() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	ops := f.ops
	f.ops = nil
	return ops
}

type fakeGitHub struct{ id int64 }

func (g *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/login/oauth/access_token":
		r.ParseForm()
		if r.PostForm.Get("client_secret") != "gh-secret" || r.PostForm.Get("code") != "good" {
			json.NewEncoder(w).Encode(map[string]string{"error": "bad_verification_code"})
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"access_token": "tok-" + fmt.Sprint(g.id)})
	case "/user":
		var id int64
		fmt.Sscanf(r.Header.Get("Authorization"), "Bearer tok-%d", &id)
		json.NewEncoder(w).Encode(map[string]any{"id": id, "login": fmt.Sprintf("user%d", id)})
	}
}

type rig struct {
	t     *testing.T
	cf    *fakeCF
	gh    *fakeGitHub
	svc   *Service
	app   *App
	srv   *httptest.Server
	now   time.Time
	nowMu sync.Mutex
}

func newRig(t *testing.T) *rig {
	rg := &rig{t: t, cf: &fakeCF{recs: map[string]cfRecord{}}, gh: &fakeGitHub{id: 7}, now: time.Now()}
	cfSrv := httptest.NewServer(rg.cf)
	ghSrv := httptest.NewServer(rg.gh)
	t.Cleanup(cfSrv.Close)
	t.Cleanup(ghSrv.Close)
	rg.cf.recs["mine"] = cfRecord{ID: "mine", Type: "A", Name: "taken.dokkit.dev", Content: "192.0.2.1"}
	store, err := OpenStore(filepath.Join(t.TempDir(), "names.json"))
	if err != nil {
		t.Fatal(err)
	}
	rg.svc = &Service{Store: store, DNS: &Cloudflare{API: cfSrv.URL, Token: "cf-token", Zone: "zone1"},
		Zone: "dokkit.dev", Max: 40, Reserved: map[string]bool{"www": true, "mcp": true}, Now: rg.clock}
	rg.app = &App{Svc: rg.svc, GitHub: GitHub{ClientID: "gh-id", Secret: "gh-secret", Web: ghSrv.URL, API: ghSrv.URL},
		Abuse: "abuse@dokkit.dev", Secret: []byte(store.s.Secret), Limits: Limiter{Burst: 1e6, PerSecond: 1}}
	rg.srv = httptest.NewServer(rg.app.Routes())
	rg.app.Base = rg.srv.URL
	t.Cleanup(rg.srv.Close)
	return rg
}

func (rg *rig) clock() time.Time {
	rg.nowMu.Lock()
	defer rg.nowMu.Unlock()
	return rg.now
}

func (rg *rig) advance(d time.Duration) {
	rg.nowMu.Lock()
	rg.now = rg.now.Add(d)
	rg.nowMu.Unlock()
}

// browser signs in through the stubbed GitHub and returns a client holding the session.
func (rg *rig) browser(id int64) *http.Client {
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	rg.gh.id = id
	resp, err := c.Get(rg.srv.URL + "/login")
	if err != nil || resp.StatusCode != 302 {
		rg.t.Fatalf("login: %v %v", err, resp)
	}
	loc, _ := url.Parse(resp.Header.Get("Location"))
	if loc.Query().Get("client_id") != "gh-id" || loc.Query().Get("redirect_uri") != rg.srv.URL+"/callback" {
		rg.t.Fatalf("authorize address: %s", loc)
	}
	resp, _ = c.Get(rg.srv.URL + "/callback?code=good&state=" + loc.Query().Get("state"))
	if resp.StatusCode != 303 {
		rg.t.Fatalf("callback answered %d", resp.StatusCode)
	}
	return c
}

func body(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return string(b)
}

var csrfRe = regexp.MustCompile(`name="csrf" value="([^"]+)"`)
var codeRe = regexp.MustCompile(`<code>([a-z0-9]+)</code>`)

func (rg *rig) post(c *http.Client, path string, form url.Values) (int, string) {
	resp, _ := c.Get(rg.srv.URL + "/")
	m := csrfRe.FindStringSubmatch(body(rg.t, resp))
	if form == nil {
		form = url.Values{}
	}
	if m != nil && form.Get("csrf") == "" {
		form.Set("csrf", m[1])
	}
	resp, err := c.PostForm(rg.srv.URL+path, form)
	if err != nil {
		rg.t.Fatal(err)
	}
	return resp.StatusCode, body(rg.t, resp)
}

func (rg *rig) claim(c *http.Client, label string) string {
	status, html := rg.post(c, "/claim", url.Values{"name": {label}})
	m := codeRe.FindStringSubmatch(html)
	if status != 200 || m == nil {
		rg.t.Fatalf("claim %s: %d %s", label, status, html)
	}
	return m[1]
}

type server struct {
	key *ecdsa.PrivateKey
	kid string
}

func newServer() *server {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	return &server{key: k}
}

func (s *server) jwk() map[string]string {
	pub, _ := s.key.PublicKey.Bytes()
	return map[string]string{"kty": "EC", "crv": "P-256", "x": b64.EncodeToString(pub[1:33]), "y": b64.EncodeToString(pub[33:])}
}

func (s *server) sign(header map[string]any, payload any) []byte {
	p, _ := json.Marshal(header)
	protected := b64.EncodeToString(p)
	pl, _ := json.Marshal(payload)
	pay := b64.EncodeToString(pl)
	d := sha256.Sum256([]byte(protected + "." + pay))
	r, sg, _ := ecdsa.Sign(rand.Reader, s.key, d[:])
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	sg.FillBytes(sig[32:])
	out, _ := json.Marshal(jws{protected, pay, b64.EncodeToString(sig)})
	return out
}

func (rg *rig) api(path string, raw []byte) (int, map[string]string) {
	resp, err := http.Post(rg.srv.URL+path, "application/json", strings.NewReader(string(raw)))
	if err != nil {
		rg.t.Fatal(err)
	}
	var out map[string]string
	json.Unmarshal([]byte(body(rg.t, resp)), &out)
	return resp.StatusCode, out
}

func (rg *rig) register(s *server, code string) (int, map[string]string) {
	status, out := rg.api("/v1/register", s.sign(map[string]any{"alg": "ES256", "jwk": s.jwk(),
		"url": "https://names.dokkit.dev/v1/register", "iat": time.Now().Unix()}, map[string]string{"code": code}))
	if status == 200 {
		s.kid = out["name"]
	}
	return status, out
}

func (rg *rig) call(s *server, path string, payload any) (int, map[string]string) {
	return rg.api(path, s.sign(map[string]any{"alg": "ES256", "kid": s.kid,
		"url": "https://names.dokkit.dev" + path, "iat": time.Now().Unix()}, payload))
}

func TestClaimRegisterAndRecords(t *testing.T) {
	rg := newRig(t)
	c := rg.browser(7)
	code := rg.claim(c, "home-lab")

	resp, _ := c.Get(rg.srv.URL + "/")
	html := body(t, resp)
	for _, want := range []string{"home-lab.dokkit.dev", "waiting for the server", "mailto:abuse@dokkit.dev?subject=Report%20home-lab.dokkit.dev"} {
		if !strings.Contains(html, want) {
			t.Fatalf("page lacks %q", want)
		}
	}
	if strings.Contains(html, code) {
		t.Fatal("the claim code is shown again")
	}

	srv := newServer()
	if st, out := rg.register(srv, "wrong"); st != 403 {
		t.Fatalf("wrong code: %d %v", st, out)
	}
	if st, out := rg.register(srv, code); st != 200 || out["name"] != "home-lab.dokkit.dev" {
		t.Fatalf("register: %d %v", st, out)
	}
	if st, _ := rg.register(newServer(), code); st != 403 {
		t.Fatal("a claim code worked twice")
	}

	if st, out := rg.call(srv, "/v1/address", map[string]string{"a": "10.1.2.3"}); st != 200 || out["a"] != "10.1.2.3" {
		t.Fatalf("address: %d %v", st, out)
	}
	if got := rg.cf.records()["A home-lab.dokkit.dev"]; got != "10.1.2.3;" {
		t.Fatalf("A record: %q", got)
	}
	rg.cf.take()
	rg.call(srv, "/v1/address", map[string]string{"a": "10.1.2.3"})
	if ops := rg.cf.take(); len(ops) != 0 {
		t.Fatalf("an unchanged address wrote to DNS: %v", ops)
	}
	rg.call(srv, "/v1/address", map[string]string{"a": "10.1.2.4", "aaaa": "fd00::5"})
	recs := rg.cf.records()
	if recs["A home-lab.dokkit.dev"] != "10.1.2.4;" || recs["AAAA home-lab.dokkit.dev"] != "fd00::5;" {
		t.Fatalf("records: %v", recs)
	}
	for _, bad := range []map[string]string{{"a": "127.0.0.1"}, {"a": "fd00::1"}, {"aaaa": "10.0.0.1"}, {"a": "169.254.1.1"}, {"a": "0.0.0.0"}, {"a": "not an address"}} {
		if st, _ := rg.call(srv, "/v1/address", bad); st != 400 {
			t.Fatalf("%v was accepted", bad)
		}
	}

	v := func(c byte) string { return strings.Repeat(string(c), 43) }
	for _, val := range []string{v('a'), v('b'), v('c')} {
		if st, out := rg.call(srv, "/v1/txt", map[string]string{"value": val}); st != 200 {
			t.Fatalf("txt: %d %v", st, out)
		}
	}
	if got := rg.cf.records()["TXT _acme-challenge.home-lab.dokkit.dev"]; strings.Count(got, ";") != 2 || strings.Contains(got, v('a')) {
		t.Fatalf("TXT records: %q", got)
	}
	if st, _ := rg.call(srv, "/v1/txt", map[string]string{"value": "not a challenge value"}); st != 400 {
		t.Fatal("arbitrary TXT text was accepted")
	}
	rg.call(srv, "/v1/txt/clear", map[string]string{})
	if _, ok := rg.cf.records()["TXT _acme-challenge.home-lab.dokkit.dev"]; ok {
		t.Fatal("clear left a TXT record")
	}

	other := newServer()
	other.kid = "home-lab.dokkit.dev"
	if st, _ := rg.call(other, "/v1/address", map[string]string{"a": "10.9.9.9"}); st != 401 {
		t.Fatal("a call signed by another key was accepted")
	}

	status, html := rg.post(c, "/names/home-lab/release", url.Values{"sure": {"on"}})
	if status != 200 || !strings.Contains(html, "is released") {
		t.Fatalf("release: %d", status)
	}
	if recs := rg.cf.records(); len(recs) != 1 {
		t.Fatalf("release left records: %v", recs)
	}
}

func TestSignedCallChecks(t *testing.T) {
	rg := newRig(t)
	srv := newServer()
	rg.register(srv, rg.claim(rg.browser(7), "box"))
	path := "/v1/address"
	sign := func(h map[string]any) []byte {
		base := map[string]any{"alg": "ES256", "kid": "box.dokkit.dev", "url": "https://names.dokkit.dev" + path, "iat": time.Now().Unix()}
		for k, v := range h {
			base[k] = v
		}
		return srv.sign(base, map[string]string{"a": "10.0.0.2"})
	}
	cases := map[string][]byte{
		"old iat":   sign(map[string]any{"iat": time.Now().Add(-6 * time.Minute).Unix()}),
		"other url": sign(map[string]any{"url": "https://names.dokkit.dev/v1/txt"}),
		"other alg": sign(map[string]any{"alg": "HS256"}),
		"no kid":    sign(map[string]any{"kid": "nope.dokkit.dev"}),
		"not jws":   []byte(`{"a":"10.0.0.2"}`),
	}
	for name, raw := range cases {
		if st, _ := rg.api(path, raw); st != 401 {
			t.Errorf("%s: answered %d", name, st)
		}
	}
	good := sign(nil)
	if st, _ := rg.api(path, good); st != 200 {
		t.Fatalf("good call answered %d", st)
	}
	if st, out := rg.api(path, good); st != 401 || !strings.Contains(out["error"], "already used") {
		t.Fatalf("a replay answered %d %v", st, out)
	}
	if st, _ := rg.api(path, []byte(strings.Repeat("x", maxBody+1))); st != 413 {
		t.Fatalf("an oversized body answered %d", st)
	}
}

func TestNameRules(t *testing.T) {
	rg := newRig(t)
	c := rg.browser(7)
	for label, want := range map[string]string{
		"ab":                    "3 to 40",
		"-abc":                  "3 to 40",
		"abc-":                  "3 to 40",
		"a.bc":                  "3 to 40",
		strings.Repeat("a", 41): "3 to 40",
		"xn--abc":               "two hyphens",
		"www":                   "reserved",
		"taken":                 "taken",
	} {
		status, html := rg.post(c, "/claim", url.Values{"name": {label}})
		if status == 200 || !strings.Contains(html, want) {
			t.Errorf("%q: %d, want %q", label, status, want)
		}
	}
	rg.claim(c, "one")
	rg.claim(c, "Two")
	rg.claim(c, "three")
	if status, html := rg.post(c, "/claim", url.Values{"name": {"four"}}); status != 409 || !strings.Contains(html, "at most 3") {
		t.Fatalf("fourth name: %d", status)
	}
	if status, html := rg.post(rg.browser(8), "/claim", url.Values{"name": {"one"}}); status != 409 || !strings.Contains(html, "taken") {
		t.Fatalf("a held name was handed out again: %d", status)
	}
	if status, _ := rg.post(c, "/claim", url.Values{"name": {"five"}, "csrf": {"forged"}}); status != 403 {
		t.Fatalf("a forged form answered %d", status)
	}
	if status, _ := rg.post(rg.browser(8), "/names/one/release", url.Values{"sure": {"on"}}); status != 404 {
		t.Fatalf("another account released a name: %d", status)
	}
}

func TestSignIn(t *testing.T) {
	rg := newRig(t)
	resp, _ := http.Get(rg.srv.URL + "/")
	if html := body(t, resp); !strings.Contains(html, "Sign in with GitHub") {
		t.Fatal("signed-out page has no sign-in")
	}
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	c.Get(rg.srv.URL + "/login")
	if resp, _ := c.Get(rg.srv.URL + "/callback?code=good&state=forged"); resp.StatusCode != 400 {
		t.Fatalf("a forged state answered %d", resp.StatusCode)
	}
	resp, _ = c.Get(rg.srv.URL + "/login")
	loc, _ := url.Parse(resp.Header.Get("Location"))
	if resp, _ := c.Get(rg.srv.URL + "/callback?code=bad&state=" + loc.Query().Get("state")); resp.StatusCode != 502 {
		t.Fatalf("a refused code answered %d", resp.StatusCode)
	}
	b := rg.browser(9)
	resp, _ = b.Get(rg.srv.URL + "/")
	if html := body(t, resp); !strings.Contains(html, "Signed in as user9") {
		t.Fatal("not signed in")
	}
	rg.post(b, "/logout", nil)
	resp, _ = b.Get(rg.srv.URL + "/")
	if html := body(t, resp); !strings.Contains(html, "Sign in with GitHub") {
		t.Fatal("still signed in after signing out")
	}
}

func TestLapseAndFree(t *testing.T) {
	rg := newRig(t)
	c := rg.browser(7)
	srv := newServer()
	rg.register(srv, rg.claim(c, "quiet"))
	rg.call(srv, "/v1/address", map[string]string{"a": "192.168.1.10"})
	rg.claim(c, "never")

	rg.advance(8 * 24 * time.Hour)
	rg.svc.Sweep()
	if _, ok := rg.svc.Store.s.Names["never"]; ok {
		t.Fatal("a name never registered was kept past its code")
	}
	if state, _ := rg.svc.State(rg.svc.Mine(7)[0]); state != "lapsing" {
		t.Fatalf("state after eight quiet days: %s", state)
	}

	rg.advance(83 * 24 * time.Hour)
	rg.svc.Sweep()
	if _, ok := rg.cf.records()["A quiet.dokkit.dev"]; ok {
		t.Fatal("a lapsed name kept its record")
	}
	if state, _ := rg.svc.State(rg.svc.Mine(7)[0]); state != "lapsed" {
		t.Fatalf("state after 91 days: %s", state)
	}

	if st, _ := rg.call(srv, "/v1/address", map[string]string{"a": "192.168.1.11"}); st != 200 {
		t.Fatal("the server could not bring its lapsed name back")
	}
	if rg.cf.records()["A quiet.dokkit.dev"] != "192.168.1.11;" {
		t.Fatal("the record did not come back")
	}

	rg.advance(91 * 24 * time.Hour)
	rg.svc.Sweep()
	rg.advance(31 * 24 * time.Hour)
	rg.svc.Sweep()
	if len(rg.svc.Mine(7)) != 0 || len(rg.cf.records()) != 1 {
		t.Fatalf("a lapsed name was not freed: %v", rg.cf.records())
	}
}

func TestStateSurvivesRestart(t *testing.T) {
	rg := newRig(t)
	rg.claim(rg.browser(7), "kept")
	again, err := OpenStore(rg.svc.Store.path)
	if err != nil || again.s.Names["kept"] == nil || again.s.Secret != rg.svc.Store.s.Secret {
		t.Fatalf("reopened state: %v %+v", err, again)
	}
}

func TestLimiter(t *testing.T) {
	var l Limiter
	now := time.Now()
	for i := 0; i < 30; i++ {
		if !l.Allow("a", now) {
			t.Fatalf("refused call %d", i)
		}
	}
	if l.Allow("a", now) || !l.Allow("b", now) {
		t.Fatal("the bucket is not per address")
	}
	if !l.Allow("a", now.Add(2*time.Second)) {
		t.Fatal("the bucket did not refill")
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:5000"
	r.Header.Set("X-Forwarded-For", "203.0.113.9, 198.51.100.4")
	if clientIP(r) != "198.51.100.4" {
		t.Fatalf("client address behind Caddy: %s", clientIP(r))
	}
	r.RemoteAddr = "198.51.100.7:5000"
	if clientIP(r) != "198.51.100.7" {
		t.Fatal("a forwarded header was believed from a far address")
	}
}
