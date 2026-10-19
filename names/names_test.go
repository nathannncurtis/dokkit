package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeDNS struct {
	mu   sync.Mutex
	sets map[string][]string
	ops  []string
}

func (f *fakeDNS) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.URL.Path == "/tenant1/oauth2/v2.0/token" {
		r.ParseForm()
		if r.PostForm.Get("client_secret") != "az-secret" {
			w.WriteHeader(401)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"access_token": "az-token", "expires_in": 3600})
		return
	}
	if r.Header.Get("Authorization") != "Bearer az-token" {
		w.WriteHeader(401)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Network/dnsZones/dokkit.dev/"), "/")
	if len(parts) != 2 {
		w.WriteHeader(400)
		return
	}
	key := parts[0] + " " + parts[1]
	f.ops = append(f.ops, r.Method+" "+key)
	switch r.Method {
	case "GET":
		vals, found := f.sets[key]
		if !found {
			w.WriteHeader(404)
			return
		}
		json.NewEncoder(w).Encode(setOf(parts[0], vals))
	case "PUT":
		var in azSet
		json.NewDecoder(r.Body).Decode(&in)
		f.sets[key] = in.values(parts[0])
		json.NewEncoder(w).Encode(in)
	case "DELETE":
		delete(f.sets, key)
	}
}

func (f *fakeDNS) records() map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string]string{}
	for key, vals := range f.sets {
		typ, rel, _ := strings.Cut(key, " ")
		name := rel + ".dokkit.dev"
		if rel == "@" {
			name = "dokkit.dev"
		}
		for _, v := range vals {
			out[typ+" "+name] += v + ";"
		}
	}
	return out
}

func (f *fakeDNS) take() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	ops := f.ops
	f.ops = nil
	return ops
}

// fakeIdP is one stubbed provider: a token endpoint that checks PKCE, a user endpoint, and,
// when it has a key, a key set and RS256 ID tokens like an OpenID Connect provider.
type fakeIdP struct {
	mu        sync.Mutex
	url       string
	key       *rsa.PrivateKey
	signWith  *rsa.PrivateKey
	user      map[string]any
	claims    map[string]any
	challenge string
	apple     *ecdsa.PublicKey // set: the client secret must be Apple's ES256 JWT and there is no PKCE
}

// appleSecretOK checks a client secret the way Apple's token endpoint does.
func (f *fakeIdP) appleSecretOK(raw string) bool {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return false
	}
	var h struct{ Alg, Kid string }
	var c struct {
		Iss, Sub, Aud string
		Iat, Exp      int64
	}
	hb, _ := b64.DecodeString(parts[0])
	cb, _ := b64.DecodeString(parts[1])
	sig, _ := b64.DecodeString(parts[2])
	if json.Unmarshal(hb, &h) != nil || json.Unmarshal(cb, &c) != nil || len(sig) != 64 {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	now := time.Now().Unix()
	return h.Alg == "ES256" && h.Kid == "KEY1234567" &&
		ecdsa.Verify(f.apple, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) &&
		c.Iss == "TEAM123456" && c.Sub == "apple-id" && c.Aud == "https://appleid.apple.com" &&
		c.Iat <= now+60 && c.Exp > now && c.Exp-c.Iat <= 15777000
}

func (f *fakeIdP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.URL.Path {
	case "/token":
		r.ParseForm()
		sum := sha256.Sum256([]byte(r.PostForm.Get("code_verifier")))
		ok := r.PostForm.Get("client_secret") == "secret" && b64.EncodeToString(sum[:]) == f.challenge
		if f.apple != nil {
			ok = r.PostForm.Get("code_verifier") == "" && f.appleSecretOK(r.PostForm.Get("client_secret"))
		}
		if !ok || r.PostForm.Get("code") != "good" {
			json.NewEncoder(w).Encode(map[string]string{"error": "invalid_grant"})
			return
		}
		out := map[string]string{"access_token": "at"}
		if f.key != nil {
			out["id_token"] = f.idToken()
		}
		json.NewEncoder(w).Encode(out)
	case "/user":
		if r.Header.Get("Authorization") != "Bearer at" {
			w.WriteHeader(401)
			return
		}
		json.NewEncoder(w).Encode(f.user)
	case "/jwks":
		pub := f.key.PublicKey
		json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "k1", "alg": "RS256",
			"n": b64.EncodeToString(pub.N.Bytes()), "e": b64.EncodeToString(big.NewInt(int64(pub.E)).Bytes())}}})
	}
}

func (f *fakeIdP) idToken() string {
	h, _ := json.Marshal(map[string]string{"alg": "RS256", "kid": "k1", "typ": "JWT"})
	p, _ := json.Marshal(f.claims)
	in := b64.EncodeToString(h) + "." + b64.EncodeToString(p)
	sum := sha256.Sum256([]byte(in))
	key := f.key
	if f.signWith != nil {
		key = f.signWith
	}
	sig, _ := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	return in + "." + b64.EncodeToString(sig)
}

var appleKey = sync.OnceValue(func() *ecdsa.PrivateKey {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	return k
})

var titles = map[string]string{"github": "GitHub", "google": "Google", "microsoft": "Microsoft", "apple": "Apple",
	"chatgpt": "ChatGPT", "gitlab": "GitLab", "discord": "Discord", "codeberg": "Codeberg"}

var rsaKey = sync.OnceValue(func() *rsa.PrivateKey {
	k, _ := rsa.GenerateKey(rand.Reader, 2048)
	return k
})

type rig struct {
	t     *testing.T
	cf    *fakeDNS
	idp   map[string]*fakeIdP
	svc   *Service
	app   *App
	srv   *httptest.Server
	now   time.Time
	nowMu sync.Mutex
}

func newRig(t *testing.T) *rig {
	rg := &rig{t: t, cf: &fakeDNS{sets: map[string][]string{}}, idp: map[string]*fakeIdP{}, now: time.Now()}
	cfSrv := httptest.NewServer(rg.cf)
	t.Cleanup(cfSrv.Close)
	var signins []*Provider
	for _, key := range []string{"github", "google", "microsoft", "apple", "chatgpt", "gitlab", "discord", "codeberg"} {
		f := &fakeIdP{}
		srv := httptest.NewServer(f)
		t.Cleanup(srv.Close)
		f.url = srv.URL
		p := &Provider{Key: key, Title: titles[key],
			ClientID: key + "-id", Secret: "secret", AuthURL: srv.URL + "/authorize", TokenURL: srv.URL + "/token", UserURL: srv.URL + "/user"}
		if key != "github" && key != "discord" {
			f.key = rsaKey()
			p.JWKSURL, p.Issuers, p.Scope = srv.URL+"/jwks", []string{srv.URL}, "openid profile"
		}
		switch key {
		case "microsoft":
			p.Issuers = []string{srv.URL + "/{tenantid}/v2.0"}
		case "apple":
			f.apple = &appleKey().PublicKey
			p.Secret, p.Scope, p.NoPKCE, p.Anon = "", "", true, "an Apple account"
			p.Mint = appleSecret("TEAM123456", "KEY1234567", "apple-id", appleKey())
		case "gitlab":
			p.Scope = "openid"
		case "discord":
			p.Scope = "identify"
		}
		rg.idp[key] = f
		signins = append(signins, p)
	}
	rg.cf.sets["A taken"] = []string{"192.0.2.1"}
	store, err := OpenStore(filepath.Join(t.TempDir(), "names.json"))
	if err != nil {
		t.Fatal(err)
	}
	rg.svc = &Service{Store: store, DNS: &Azure{API: cfSrv.URL, Login: cfSrv.URL, Tenant: "tenant1", ClientID: "c1", Secret: "az-secret", Subscription: "sub1", Group: "rg1", Zone: "dokkit.dev"},
		Zone: "dokkit.dev", Max: 40, Reserved: map[string]bool{"www": true, "mcp": true}, Now: rg.clock}
	rg.app = &App{Svc: rg.svc, Signins: signins,
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

func jarClient() *http.Client {
	jar, _ := cookiejar.New(nil)
	return &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

// signIn walks one provider's sign-in and returns what the callback answered. For OpenID
// providers the ID token carries good claims, with claims laid over them.
func (rg *rig) signIn(c *http.Client, key string, claims map[string]any) int {
	resp, err := c.Get(rg.srv.URL + "/login/" + key)
	if err != nil || resp.StatusCode != 302 {
		rg.t.Fatalf("login %s: %v %v", key, err, resp)
	}
	loc, _ := url.Parse(resp.Header.Get("Location"))
	q := loc.Query()
	f := rg.idp[key]
	if q.Get("client_id") != key+"-id" || q.Get("redirect_uri") != rg.srv.URL+"/callback/"+key || (q.Get("code_challenge_method") == "S256") == (f.apple != nil) ||
		q.Get("response_type") != "code" || (q.Get("nonce") != "") != (f.key != nil) || strings.Contains(q.Get("scope"), "email") {
		rg.t.Fatalf("authorize address: %s", loc)
	}
	f.mu.Lock()
	f.challenge = q.Get("code_challenge")
	if f.key != nil {
		iss := f.url
		if key == "microsoft" {
			iss = f.url + "/t1/v2.0"
		}
		f.claims = map[string]any{"iss": iss, "aud": key + "-id", "sub": key + "-sub", "nonce": q.Get("nonce"), "tid": "t1",
			"exp": time.Now().Add(time.Hour).Unix(), "iat": time.Now().Unix(), "email": "someone@" + key + ".example", "name": "Someone at " + key}
		switch key {
		case "apple":
			delete(f.claims, "name")
		case "gitlab":
			f.claims["name"], f.claims["nickname"] = "", "gl-someone"
		}
		for k, v := range claims {
			f.claims[k] = v
		}
	}
	f.mu.Unlock()
	resp, _ = c.Get(rg.srv.URL + "/callback/" + key + "?code=good&state=" + q.Get("state"))
	return resp.StatusCode
}

// browser signs in through the stubbed GitHub as the given user id.
func (rg *rig) browser(id int64) *http.Client {
	c := jarClient()
	rg.idp["github"].user = map[string]any{"id": id, "login": fmt.Sprintf("user%d", id)}
	if st := rg.signIn(c, "github", nil); st != 303 {
		rg.t.Fatalf("callback answered %d", st)
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
var codeRe = regexp.MustCompile(`<p class="v">([a-z0-9]+)</p>`)

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
	html := body(t, resp)
	for _, want := range []string{"Sign in with GitHub", "Sign in with Google", "Sign in with Microsoft", "Sign in with Apple", `href="/login/google"`} {
		if !strings.Contains(html, want) {
			t.Fatalf("signed-out page lacks %q", want)
		}
	}
	var big, more []string
	for _, m := range regexp.MustCompile(`class="sso (\w+)"`).FindAllStringSubmatch(html, -1) {
		big = append(big, m[1])
	}
	for _, m := range regexp.MustCompile(`class="alt" href="/login/(\w+)"`).FindAllStringSubmatch(html, -1) {
		more = append(more, m[1])
	}
	if strings.Join(big, " ") != "github google microsoft apple" || strings.Join(more, " ") != "chatgpt gitlab discord codeberg" {
		t.Fatalf("buttons %v, more %v", big, more)
	}
	c := jarClient()
	c.Get(rg.srv.URL + "/login/github")
	if resp, _ := c.Get(rg.srv.URL + "/callback/github?code=good&state=forged"); resp.StatusCode != 400 {
		t.Fatalf("a forged state answered %d", resp.StatusCode)
	}
	resp, _ = c.Get(rg.srv.URL + "/login/google")
	loc, _ := url.Parse(resp.Header.Get("Location"))
	if resp, _ := c.Get(rg.srv.URL + "/callback/github?code=good&state=" + loc.Query().Get("state")); resp.StatusCode != 400 {
		t.Fatalf("a state from another provider answered %d", resp.StatusCode)
	}
	resp, _ = c.Get(rg.srv.URL + "/login/github")
	loc, _ = url.Parse(resp.Header.Get("Location"))
	if resp, _ := c.Get(rg.srv.URL + "/callback/github?code=bad&state=" + loc.Query().Get("state")); resp.StatusCode != 502 {
		t.Fatalf("a refused code answered %d", resp.StatusCode)
	}
	if resp, _ := c.Get(rg.srv.URL + "/login/nope"); resp.StatusCode != 404 {
		t.Fatalf("an unknown provider answered %d", resp.StatusCode)
	}
	b := rg.browser(9)
	resp, _ = b.Get(rg.srv.URL + "/")
	if html := body(t, resp); !strings.Contains(html, "Signed in as <b>user9</b> through GitHub.") {
		t.Fatal("not signed in")
	}
	rg.post(b, "/logout", nil)
	resp, _ = b.Get(rg.srv.URL + "/")
	if html := body(t, resp); !strings.Contains(html, "Sign in with GitHub") {
		t.Fatal("still signed in after signing out")
	}
	rg.app.Signins = rg.app.Signins[1:2]
	resp, _ = http.Get(rg.srv.URL + "/")
	if html := body(t, resp); strings.Contains(html, "Sign in with GitHub") || !strings.Contains(html, "Sign in with Google") || strings.Contains(html, "More:") {
		t.Fatal("the page offers a sign-in that is not set up")
	}
}

func TestSignInEachProvider(t *testing.T) {
	rg := newRig(t)
	rg.idp["github"].user = map[string]any{"id": 42, "login": "octo", "email": "octo@github.example"}
	rg.idp["discord"].user = map[string]any{"id": "80351110224678912", "username": "nelly", "global_name": "Nelly", "email": "nelly@discord.example"}
	for key, want := range map[string]string{"github": "octo</b> through GitHub", "google": "Someone at google</b> through Google",
		"microsoft": "Someone at microsoft</b> through Microsoft", "chatgpt": "Someone at chatgpt</b> through ChatGPT",
		"apple": "an Apple account</b> through Apple", "gitlab": "gl-someone</b> through GitLab", "discord": "Nelly</b> through Discord",
		"codeberg": "Someone at codeberg</b> through Codeberg"} {
		c := jarClient()
		if st := rg.signIn(c, key, nil); st != 303 {
			t.Fatalf("%s: callback answered %d", key, st)
		}
		resp, _ := c.Get(rg.srv.URL + "/")
		if html := body(t, resp); !strings.Contains(html, want) {
			t.Fatalf("%s: page lacks %q", key, want)
		}
		u, _ := url.Parse(rg.srv.URL)
		for _, ck := range c.Jar.Cookies(u) {
			if raw, _ := b64.DecodeString(strings.Split(ck.Value, ".")[0]); strings.Contains(string(raw), "@") {
				t.Fatalf("%s: the session holds an email: %s", key, raw)
			}
		}
		rg.claim(c, key+"-box")
	}
	if b, _ := os.ReadFile(rg.svc.Store.path); strings.Contains(string(b), "@") {
		t.Fatalf("the state holds an email: %s", b)
	}
	for account, label := range map[string]string{"github:42": "github-box", "google:google-sub": "google-box",
		"microsoft:microsoft-sub": "microsoft-box", "chatgpt:chatgpt-sub": "chatgpt-box", "apple:apple-sub": "apple-box",
		"gitlab:gitlab-sub": "gitlab-box", "discord:80351110224678912": "discord-box", "codeberg:codeberg-sub": "codeberg-box"} {
		if mine := rg.svc.Mine(account); len(mine) != 1 || mine[0].Label != label {
			t.Errorf("%s holds %v", account, mine)
		}
	}
}

func TestIDTokenChecks(t *testing.T) {
	rg := newRig(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	cases := []struct {
		name, key string
		claims    map[string]any
		signWith  *rsa.PrivateKey
	}{
		{"bad nonce", "google", map[string]any{"nonce": "other"}, nil},
		{"no nonce", "chatgpt", map[string]any{"nonce": ""}, nil},
		{"wrong audience", "google", map[string]any{"aud": "someone-else"}, nil},
		{"audience list without azp", "google", map[string]any{"aud": []string{"google-id", "x"}}, nil},
		{"wrong issuer", "google", map[string]any{"iss": "https://elsewhere.example"}, nil},
		{"issuer of another tenant", "microsoft", map[string]any{"tid": "t2"}, nil},
		{"no tenant", "microsoft", map[string]any{"tid": ""}, nil},
		{"expired", "microsoft", map[string]any{"exp": time.Now().Add(-time.Hour).Unix()}, nil},
		{"no sub", "chatgpt", map[string]any{"sub": ""}, nil},
		{"signed by another key", "google", nil, other},
		{"apple: wrong audience", "apple", map[string]any{"aud": "google-id"}, nil},
		{"apple: wrong issuer", "apple", map[string]any{"iss": "https://appleid.example"}, nil},
		{"apple: bad nonce", "apple", map[string]any{"nonce": "other"}, nil},
		{"gitlab: wrong audience", "gitlab", map[string]any{"aud": "codeberg-id"}, nil},
		{"gitlab: wrong issuer", "gitlab", map[string]any{"iss": "https://gitlab.example"}, nil},
		{"codeberg: wrong audience", "codeberg", map[string]any{"aud": "gitlab-id"}, nil},
		{"codeberg: wrong issuer", "codeberg", map[string]any{"iss": "https://codeberg.example"}, nil},
		{"codeberg: signed by another key", "codeberg", nil, other},
	}
	for _, tc := range cases {
		rg.idp[tc.key].signWith = tc.signWith
		if st := rg.signIn(jarClient(), tc.key, tc.claims); st != 502 {
			t.Errorf("%s: answered %d", tc.name, st)
		}
		rg.idp[tc.key].signWith = nil
	}
	c := jarClient()
	resp, _ := c.Get(rg.srv.URL + "/login/google")
	loc, _ := url.Parse(resp.Header.Get("Location"))
	rg.idp["google"].challenge = "not-this-one"
	if resp, _ := c.Get(rg.srv.URL + "/callback/google?code=good&state=" + loc.Query().Get("state")); resp.StatusCode != 502 {
		t.Fatalf("a PKCE mismatch answered %d", resp.StatusCode)
	}
	if st := rg.signIn(jarClient(), "google", map[string]any{"aud": []string{"google-id", "x"}, "azp": "google-id"}); st != 303 {
		t.Fatalf("an audience list with azp answered %d", st)
	}
}

func TestNewProvidersRefuseForgedState(t *testing.T) {
	rg := newRig(t)
	for _, key := range []string{"apple", "gitlab", "discord", "codeberg"} {
		c := jarClient()
		resp, _ := c.Get(rg.srv.URL + "/login/" + key)
		loc, _ := url.Parse(resp.Header.Get("Location"))
		if resp, _ := c.Get(rg.srv.URL + "/callback/" + key + "?code=good&state=forged"); resp.StatusCode != 400 {
			t.Errorf("%s: a forged state answered %d", key, resp.StatusCode)
		}
		if resp, _ := jarClient().Get(rg.srv.URL + "/callback/" + key + "?code=good&state=" + loc.Query().Get("state")); resp.StatusCode != 400 {
			t.Errorf("%s: a callback without its state cookie answered %d", key, resp.StatusCode)
		}
	}
	rg.idp["discord"].user = map[string]any{"id": "0", "username": "nobody"}
	if st := rg.signIn(jarClient(), "discord", nil); st != 502 {
		t.Errorf("a discord user without an id answered %d", st)
	}
}

func TestAppleClientSecret(t *testing.T) {
	rg := newRig(t)
	resp, _ := jarClient().Get(rg.srv.URL + "/login/apple")
	loc, _ := url.Parse(resp.Header.Get("Location"))
	if q := loc.Query(); q.Has("scope") || q.Has("code_challenge") || q.Get("nonce") == "" || q.Has("response_mode") {
		t.Fatalf("apple authorize: %v", q)
	}
	apple := rg.app.provider("apple")
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	for name, mint := range map[string]func(time.Time) (string, error){
		"another key":    appleSecret("TEAM123456", "KEY1234567", "apple-id", other),
		"another team":   appleSecret("TEAM000000", "KEY1234567", "apple-id", appleKey()),
		"another key id": appleSecret("TEAM123456", "KEY0000000", "apple-id", appleKey()),
		"another client": appleSecret("TEAM123456", "KEY1234567", "other-id", appleKey()),
		"an expired one": func(time.Time) (string, error) {
			return appleSecret("TEAM123456", "KEY1234567", "apple-id", appleKey())(time.Now().Add(-2 * time.Hour))
		},
	} {
		apple.Mint = mint
		if st := rg.signIn(jarClient(), "apple", nil); st != 502 {
			t.Errorf("a client secret from %s answered %d", name, st)
		}
	}
	apple.Mint = appleSecret("TEAM123456", "KEY1234567", "apple-id", appleKey())
	if st := rg.signIn(jarClient(), "apple", nil); st != 303 {
		t.Fatalf("apple answered %d", st)
	}
}

func TestConfiguredProviders(t *testing.T) {
	for _, k := range []string{"GITHUB", "GOOGLE", "MICROSOFT", "CHATGPT", "GITLAB", "DISCORD", "CODEBERG"} {
		t.Setenv(k+"_CLIENT_ID", "")
		t.Setenv(k+"_CLIENT_SECRET", "")
	}
	for _, k := range appleEnv {
		t.Setenv(k, "")
	}
	if _, err := configuredProviders(); err == nil {
		t.Fatal("started with no sign-in")
	}
	t.Setenv("GOOGLE_CLIENT_ID", "g")
	if _, err := configuredProviders(); err == nil {
		t.Fatal("started with a client id and no secret")
	}
	t.Setenv("GOOGLE_CLIENT_SECRET", "gs")
	t.Setenv("CHATGPT_CLIENT_ID", "c")
	t.Setenv("CHATGPT_CLIENT_SECRET", "cs")
	ps, err := configuredProviders()
	if err != nil || len(ps) != 2 || ps[0].Key != "google" || ps[1].Key != "chatgpt" || ps[1].Issuers[0] != "https://auth.openai.com" {
		t.Fatalf("providers: %v %+v", err, ps)
	}
	t.Setenv("APPLE_TEAM_ID", "TEAM123456")
	if _, err := configuredProviders(); err == nil {
		t.Fatal("started with part of Apple's settings")
	}
	keyFile := filepath.Join(t.TempDir(), "AuthKey.p8")
	t.Setenv("APPLE_KEY_ID", "KEY1234567")
	t.Setenv("APPLE_CLIENT_ID", "apple-id")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", keyFile)
	os.WriteFile(keyFile, []byte("not a key"), 0o600)
	if _, err := configuredProviders(); err == nil {
		t.Fatal("started with a broken Apple key")
	}
	der, _ := x509.MarshalPKCS8PrivateKey(appleKey())
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	for _, k := range []string{"GITLAB", "DISCORD", "CODEBERG"} {
		t.Setenv(k+"_CLIENT_ID", "x")
		t.Setenv(k+"_CLIENT_SECRET", "y")
	}
	ps, err = configuredProviders()
	var keys []string
	for _, p := range ps {
		keys = append(keys, p.Key)
	}
	if err != nil || strings.Join(keys, " ") != "google apple chatgpt gitlab discord codeberg" {
		t.Fatalf("providers: %v %v", err, keys)
	}
	secret, _ := ps[1].Mint(time.Now())
	if ps[1].ClientID != "apple-id" || ps[1].Scope != "" || !ps[1].NoPKCE || !(&fakeIdP{apple: &appleKey().PublicKey}).appleSecretOK(secret) {
		t.Fatalf("apple: %+v", ps[1])
	}
	if ps[3].Scope != "openid" || ps[4].Scope != "identify" || ps[4].oidc() || ps[5].Issuers[0] != "https://codeberg.org" {
		t.Fatalf("scopes: %+v %+v %+v", ps[3], ps[4], ps[5])
	}
}

func TestGitHubOwnersMigrate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "names.json")
	old := `{"secret":"s","names":{"kept":{"label":"kept","owner":7,"login":"user7","created":"2026-01-01T00:00:00Z"}}}`
	if err := os.WriteFile(path, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	st, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if mine := (&Service{Store: st}).Mine("github:7"); len(mine) != 1 || mine[0].Label != "kept" || mine[0].GitHubID != 0 {
		t.Fatalf("migrated: %+v", mine)
	}
	if b, _ := os.ReadFile(path); !strings.Contains(string(b), `"account": "github:7"`) || strings.Contains(string(b), `"owner"`) {
		t.Fatalf("saved state: %s", b)
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
	if state, _ := rg.svc.State(rg.svc.Mine("github:7")[0]); state != "lapsing" {
		t.Fatalf("state after eight quiet days: %s", state)
	}

	rg.advance(83 * 24 * time.Hour)
	rg.svc.Sweep()
	if _, ok := rg.cf.records()["A quiet.dokkit.dev"]; ok {
		t.Fatal("a lapsed name kept its record")
	}
	if state, _ := rg.svc.State(rg.svc.Mine("github:7")[0]); state != "lapsed" {
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
	if len(rg.svc.Mine("github:7")) != 0 || len(rg.cf.records()) != 1 {
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
