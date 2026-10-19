package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxBody     = 8 << 10
	sessionLife = 14 * 24 * time.Hour
)

type App struct {
	Svc     *Service
	Base    string
	Signins []*Provider
	Demo    bool
	Abuse   string
	Secret  []byte
	replays Replays
	checks  Limiter
	Limits  Limiter
}

type session struct {
	Account string `json:"acct"`
	Login   string `json:"login"`
	Via     string `json:"via"`
	Exp     int64  `json:"exp"`
}

func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.home)
	mux.HandleFunc("GET /login/{provider}", a.login)
	mux.HandleFunc("GET /callback/{provider}", a.callback)
	mux.HandleFunc("GET /part", a.part)
	mux.HandleFunc("GET /check", a.check)
	mux.HandleFunc("GET /app.js", serveJS)
	if a.Demo {
		mux.HandleFunc("GET /demo-signin", a.demoSignin)
	}
	mux.HandleFunc("POST /logout", a.logout)
	mux.HandleFunc("POST /claim", a.form(a.claim))
	mux.HandleFunc("POST /names/{label}/code", a.form(a.newCode))
	mux.HandleFunc("POST /names/{label}/release", a.form(a.release))
	mux.HandleFunc("POST /v1/register", a.register)
	mux.HandleFunc("POST /v1/address", a.signed(func(label string, p []byte) (*Name, error) {
		var in struct{ A, AAAA string }
		if err := json.Unmarshal(p, &in); err != nil {
			return nil, refuse(400, "The payload is {\"a\": ..., \"aaaa\": ...}.")
		}
		return a.Svc.Address(label, in.A, in.AAAA)
	}))
	mux.HandleFunc("POST /v1/txt", a.signed(func(label string, p []byte) (*Name, error) {
		var in struct{ Value string }
		if err := json.Unmarshal(p, &in); err != nil {
			return nil, refuse(400, "The payload is {\"value\": ...}.")
		}
		return a.Svc.AddTXT(label, in.Value)
	}))
	mux.HandleFunc("POST /v1/txt/clear", a.signed(func(label string, _ []byte) (*Name, error) {
		return a.Svc.ClearTXT(label)
	}))
	return a.guard(mux)
}

func (a *App) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		if r.URL.Path != "/check" && !a.Limits.Allow(clientIP(r), time.Now()) {
			http.Error(w, "Too many requests. Wait a minute.", http.StatusTooManyRequests)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		next.ServeHTTP(w, r)
	})
}

// Caddy on the same machine replaces any X-Forwarded-For it did not set, so its last entry is the client.
func clientIP(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	return host
}

type bucket struct {
	tokens float64
	at     time.Time
}

// Limiter is a token bucket per address; zero values mean 30 at once, then one every two seconds.
type Limiter struct {
	Burst, PerSecond float64
	mu               sync.Mutex
	b                map[string]*bucket
}

func (l *Limiter) Allow(ip string, now time.Time) bool {
	burst, perSecond := l.Burst, l.PerSecond
	if burst == 0 {
		burst, perSecond = 30, 0.5
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.b == nil || len(l.b) > 50_000 {
		l.b = map[string]*bucket{}
	}
	b := l.b[ip]
	if b == nil {
		b = &bucket{tokens: burst, at: now}
		l.b[ip] = b
	}
	b.tokens = math.Min(burst, b.tokens+now.Sub(b.at).Seconds()*perSecond)
	b.at = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// Sessions

func (a *App) mac(text string) string {
	m := hmac.New(sha256.New, a.Secret)
	m.Write([]byte(text))
	return b64.EncodeToString(m.Sum(nil))
}

func (a *App) secure() bool { return strings.HasPrefix(a.Base, "https://") }

func (a *App) setCookie(w http.ResponseWriter, name, value string, life time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", MaxAge: int(life.Seconds()),
		HttpOnly: true, Secure: a.secure(), SameSite: http.SameSiteLaxMode})
}

func (a *App) session(r *http.Request) (*session, string) {
	c, err := r.Cookie("s")
	if err != nil {
		return nil, ""
	}
	body, sig, ok := strings.Cut(c.Value, ".")
	if !ok || !hmac.Equal([]byte(sig), []byte(a.mac("s|"+body))) {
		return nil, ""
	}
	raw, err := b64.DecodeString(body)
	var s session
	if err != nil || json.Unmarshal(raw, &s) != nil || s.Account == "" || time.Now().Unix() > s.Exp {
		return nil, ""
	}
	return &s, a.mac("csrf|" + c.Value)
}

func (a *App) provider(key string) *Provider {
	for _, p := range a.Signins {
		if p.Key == key {
			return p
		}
	}
	return nil
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	p := a.provider(r.PathValue("provider"))
	if p == nil {
		http.NotFound(w, r)
		return
	}
	state := randomHex(16)
	a.setCookie(w, "st", p.Key+"."+state, 10*time.Minute)
	if r.URL.Query().Get("popup") == "1" {
		a.setCookie(w, "pop", "1", 10*time.Minute)
	}
	http.Redirect(w, r, p.authorizeURL(a.Base+"/callback/"+p.Key, state, a.mac("pkce|"+state), a.mac("nonce|"+state)), http.StatusFound)
}

func (a *App) callback(w http.ResponseWriter, r *http.Request) {
	p := a.provider(r.PathValue("provider"))
	state := r.URL.Query().Get("state")
	c, err := r.Cookie("st")
	if p == nil || err != nil || state == "" || !hmac.Equal([]byte(c.Value), []byte(p.Key+"."+state)) {
		a.page(w, r, http.StatusBadRequest, view{Error: "The sign-in took too long or came from elsewhere. Sign in again."})
		return
	}
	a.setCookie(w, "st", "", -1)
	id, err := p.identify(r.URL.Query().Get("code"), a.Base+"/callback/"+p.Key, a.mac("pkce|"+state), a.mac("nonce|"+state), time.Now())
	if err != nil {
		log.Printf("%s sign-in: %v", p.Key, err)
		a.page(w, r, http.StatusBadGateway, view{Error: p.Title + " did not confirm the sign-in. Try again."})
		return
	}
	raw, _ := json.Marshal(session{Account: p.Key + ":" + id.ID, Login: id.Name, Via: p.Title, Exp: time.Now().Add(sessionLife).Unix()})
	body := b64.EncodeToString(raw)
	a.setCookie(w, "s", body+"."+a.mac("s|"+body), sessionLife)
	if c, err := r.Cookie("pop"); err == nil && c.Value == "1" {
		a.setCookie(w, "pop", "", -1)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, `<!doctype html><meta charset="utf-8"><title>Signed in</title><body data-signed-in><p>Signed in. You can close this window.</p><script src="/app.js"></script>`)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func getJSON(client *http.Client, req *http.Request, out any) error {
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return errors.New("answered " + resp.Status)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
}

// demoSignin signs in a made-up account, for trying the page on a local copy only.
func (a *App) demoSignin(w http.ResponseWriter, r *http.Request) {
	raw, _ := json.Marshal(session{Account: "demo:1", Login: "demo-user", Via: "a demo sign-in", Exp: time.Now().Add(sessionLife).Unix()})
	body := b64.EncodeToString(raw)
	a.setCookie(w, "s", body+"."+a.mac("s|"+body), sessionLife)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	a.setCookie(w, "s", "", -1)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// The page

type row struct {
	Name, Label, State, Note, A, AAAA, Report string
}

type view struct {
	Login, Via, CSRF, Error, Done, Code, CodeFor string
	Signins                                      []*Provider
	Rows                                         []row
	Zone                                         string
	Abuse                                        string
	Max                                          int
	Demo                                         bool
	Status                                       int
}

func (v view) Main() []*Provider {
	return slices.DeleteFunc(slices.Clone(v.Signins), func(p *Provider) bool { return !p.Big() })
}
func (v view) More() []*Provider { return slices.DeleteFunc(slices.Clone(v.Signins), (*Provider).Big) }

func (a *App) form(fn func(*session, *http.Request) (view, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s, csrf := a.session(r)
		if s == nil {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		if !hmac.Equal([]byte(r.PostFormValue("csrf")), []byte(csrf)) {
			a.page(w, r, http.StatusForbidden, view{Error: "The form was out of date. Try again."})
			return
		}
		v, err := fn(s, r)
		status := http.StatusOK
		if err != nil {
			var p *Problem
			if errors.As(err, &p) {
				status, v.Error = p.Status, p.Text
			} else {
				log.Printf("%s: %v", r.URL.Path, err)
				status, v.Error = 500, "That did not work. Try again later."
			}
		}
		a.page(w, r, status, v)
	}
}

func (a *App) claim(s *session, r *http.Request) (view, error) {
	label := strings.ToLower(strings.TrimSpace(r.PostFormValue("name")))
	code, err := a.Svc.Claim(s.Account, s.Login, label)
	return view{Code: code, CodeFor: a.Svc.fqdn(label)}, err
}

func (a *App) newCode(s *session, r *http.Request) (view, error) {
	label := r.PathValue("label")
	code, err := a.Svc.NewCode(s.Account, label)
	return view{Code: code, CodeFor: a.Svc.fqdn(label)}, err
}

func (a *App) release(s *session, r *http.Request) (view, error) {
	label := r.PathValue("label")
	err := a.Svc.Release(s.Account, label)
	return view{Done: a.Svc.fqdn(label) + " is released."}, err
}

func (a *App) home(w http.ResponseWriter, r *http.Request) {
	a.page(w, r, http.StatusOK, view{})
}

func (a *App) page(w http.ResponseWriter, r *http.Request, status int, v view) {
	v.Zone, v.Abuse, v.Max, v.Signins, v.Demo = a.Svc.Zone, a.Abuse, perAccount, a.Signins, a.Demo
	if s, csrf := a.session(r); s != nil {
		v.Login, v.Via, v.CSRF = s.Login, s.Via, csrf
		for _, n := range a.Svc.Mine(s.Account) {
			state, note := a.Svc.State(n)
			fq := a.Svc.fqdn(n.Label)
			v.Rows = append(v.Rows, row{Name: fq, Label: n.Label, State: state, Note: note, A: n.A, AAAA: n.AAAA,
				Report: "mailto:" + a.Abuse + "?subject=" + url.PathEscape("Report "+fq)})
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	name := "page"
	if r.URL.Path == "/part" {
		name = "acct"
	}
	if err := pageTmpl.ExecuteTemplate(w, name, v); err != nil {
		log.Printf("page: %v", err)
	}
}

// check answers the claim box as you type: whether the name can be claimed, and why not.
func (a *App) check(w http.ResponseWriter, r *http.Request) {
	s, _ := a.session(r)
	if s == nil {
		http.Error(w, "Sign in first.", http.StatusUnauthorized)
		return
	}
	if !a.checks.Allow(clientIP(r), time.Now()) {
		a.reply(w, http.StatusTooManyRequests, map[string]any{"ok": false, "reason": "Slow down a moment."})
		return
	}
	label := strings.TrimSpace(r.URL.Query().Get("name"))
	if err := a.Svc.Available(s.Account, label); err != nil {
		reason := "That name could not be checked."
		var p *Problem
		if errors.As(err, &p) {
			reason = p.Text
		}
		a.reply(w, http.StatusOK, map[string]any{"ok": false, "reason": reason})
		return
	}
	a.reply(w, http.StatusOK, map[string]any{"ok": true, "reason": a.Svc.fqdn(label) + " is free."})
}

// part is the signed-in or signed-out half of the page, swapped in without a reload.
func (a *App) part(w http.ResponseWriter, r *http.Request) {
	a.page(w, r, http.StatusOK, view{})
}

func serveJS(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	io.WriteString(w, appJS)
}

// The API for servers

func (a *App) reply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func (a *App) fail(w http.ResponseWriter, err error) {
	var p *Problem
	if errors.As(err, &p) {
		a.reply(w, p.Status, map[string]string{"error": p.Text})
		return
	}
	log.Printf("api: %v", err)
	a.reply(w, 500, map[string]string{"error": "The service could not do that just now."})
}

func readAll(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	b, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, refuse(http.StatusRequestEntityTooLarge, "The body is larger than %d bytes.", maxBody)
	}
	return b, nil
}

func (a *App) register(w http.ResponseWriter, r *http.Request) {
	body, err := readAll(w, r)
	if err != nil {
		a.fail(w, err)
		return
	}
	h, payload, err := Verify(body, r.URL.Path, time.Now(), &a.replays, func(string) *JWK { return nil })
	if err == nil && h.JWK == nil {
		err = errors.New("a registration carries its key as jwk")
	}
	if err != nil {
		a.fail(w, refuse(400, "%v", err))
		return
	}
	var in struct{ Code string }
	json.Unmarshal(payload, &in)
	key := *h.JWK
	name, err := a.Svc.Register(in.Code, JWK{Kty: key.Kty, Crv: key.Crv, X: key.X, Y: key.Y})
	if err != nil {
		a.fail(w, err)
		return
	}
	a.reply(w, 200, map[string]string{"name": name})
}

func (a *App) signed(fn func(label string, payload []byte) (*Name, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := readAll(w, r)
		if err != nil {
			a.fail(w, err)
			return
		}
		label := ""
		h, payload, err := Verify(body, r.URL.Path, time.Now(), &a.replays, func(kid string) *JWK {
			label = strings.TrimSuffix(kid, "."+a.Svc.Zone)
			return a.Svc.KeyFor(label)
		})
		if err == nil && h.JWK != nil {
			err = errors.New("a call is signed with kid, the name")
		}
		if err != nil {
			a.fail(w, refuse(401, "%v", err))
			return
		}
		n, err := fn(label, payload)
		if err != nil {
			a.fail(w, err)
			return
		}
		a.reply(w, 200, map[string]string{"name": a.Svc.fqdn(n.Label), "a": n.A, "aaaa": n.AAAA,
			"lapses": n.Seen.Add(lapseAfter).UTC().Format(time.RFC3339), "txt": strconv.Itoa(len(n.TXT))})
	}
}

var pageTmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claim a name on {{.Zone}}</title>
<meta name="theme-color" content="#1e1917">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Crect width='100' height='100' rx='24' fill='%23ff9a4d'/%3E%3Cg fill='%232a1203'%3E%3Ccircle cx='27.5' cy='30.5' r='5.4'/%3E%3Cpath d='M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z'/%3E%3C/g%3E%3C/svg%3E">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,700&family=Hanken+Grotesk:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root{--bg:#1e1917;--panel:#27201d;--line:#40342f;--chip:#3a2f2a;--well:#120f0d;--ink:#f7f1ec;--mute:#b9a99e;--acc:#ff9a4d;--acc2:#ffb074;--accink:#2a1203;--ok:#7bd88f;--warn:#f5c542;--bad:#ff7b72;--display:"Bricolage Grotesque","Hanken Grotesk",system-ui,sans-serif;--sans:"Hanken Grotesk",system-ui,sans-serif;--mono:"IBM Plex Mono",ui-monospace,monospace;color-scheme:dark}
*{box-sizing:border-box}html{background:var(--bg)}body{margin:0;color:var(--ink);font:16.5px/1.65 var(--sans);-webkit-font-smoothing:antialiased}
a{color:var(--acc2)}:focus-visible{outline:2px solid var(--acc);outline-offset:3px;border-radius:4px}
.bar{display:flex;align-items:center;gap:16px;padding:14px clamp(16px,6vw,112px);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:10px;font:700 19px var(--display);color:var(--ink);text-decoration:none}
.mk{display:inline-grid;place-items:center;width:30px;height:30px;border-radius:9px;background:linear-gradient(#ffb074,#ff9a4d)}.mk svg{width:86%;height:86%;fill:var(--accink)}
.crumb{font:13px var(--mono);color:var(--mute)}.crumb b{color:var(--ink);font-weight:500}
main{max-width:860px;margin:0 auto;padding:clamp(48px,8vw,112px) 16px clamp(64px,10vw,140px)}
h1{font:700 clamp(40px,6vw,84px)/0.95 var(--display);letter-spacing:-0.04em;margin:0}
.lede{max-width:52ch;font-size:clamp(17px,1.4vw,20px);color:var(--mute);margin:22px 0 0}.lede b{color:var(--ink);font-weight:500}
.msg{margin:28px 0 0;padding:14px 18px;border-radius:12px;border:1px solid var(--line);background:var(--panel)}.msg.bad{border-color:var(--bad);color:var(--bad)}.msg.ok{border-color:var(--ok);color:var(--ok)}
.who{display:flex;flex-wrap:wrap;align-items:center;gap:10px 16px;margin:40px 0 0;color:var(--mute)}.who b{color:var(--ink);font-weight:600}
form{display:inline;margin:0}
button,.btn{font:600 15px var(--sans);padding:10px 18px;border-radius:10px;border:1px solid var(--line);background:none;color:var(--ink);cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;gap:8px}
button:hover,.btn:hover{border-color:var(--mute)}
.pri{background:var(--acc);border-color:var(--acc);color:var(--accink)}.pri:hover{background:var(--acc2);border-color:var(--acc2)}
.small{font-size:13.5px;padding:6px 12px;border-radius:8px}.danger:hover{border-color:var(--bad);color:var(--bad)}
.code{margin:32px 0 0;padding:24px;border:1px solid var(--acc);border-radius:16px;background:color-mix(in srgb,var(--acc) 7%,var(--bg))}
.code p{margin:0}.cv{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:14px 0}.cv .v{flex:1 1 280px;min-width:0;display:block;margin:0;font:500 clamp(18px,2.2vw,24px) var(--mono);letter-spacing:.04em;color:var(--acc2);background:var(--well);border:1px solid var(--line);border-radius:10px;padding:14px 18px;user-select:all;overflow-wrap:anywhere}
.code .m{color:var(--mute);font-size:15px}
h2{font:500 12px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--mute);margin:56px 0 12px}
.names{border-top:1px solid var(--ink)}
.row{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1.2fr) minmax(0,0.8fr) auto;gap:8px 24px;align-items:start;padding:20px 0;border-bottom:1px solid var(--line)}
.row .n{font:500 16px var(--mono);overflow-wrap:anywhere}.row .st{display:flex;gap:10px;align-items:baseline}.row .st small{display:block;color:var(--mute);font-size:13.5px}
.row .ad{font:13.5px var(--mono);color:var(--mute);overflow-wrap:anywhere}
.acts{display:flex;flex-wrap:wrap;gap:8px;align-items:center;justify-content:flex-end}
.acts label{font-size:13px;color:var(--mute);display:inline-flex;gap:6px;align-items:center}.acts a{font-size:13px;color:var(--mute)}
.s{flex:none;display:inline-block;width:10px;height:10px;border-radius:2px;background:var(--ok);transform:translateY(1px)}
.s.warn{background:var(--warn);transform:rotate(45deg) scale(.9)}.s.bad{background:var(--bad);border-radius:50%}.s.none{background:none;border:1.5px dashed var(--mute)}
.claim{margin:40px 0 0;padding:26px;border:1px solid var(--line);border-radius:16px;background:color-mix(in srgb,var(--panel) 60%,transparent)}
.claim .f{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.claim input{font:500 17px var(--mono);padding:12px 14px;border-radius:10px;border:1px solid var(--line);background:var(--well);color:var(--ink);width:min(100%,280px)}
.claim input:focus{outline:2px solid var(--acc);outline-offset:2px}.claim .z{font:500 17px var(--mono);color:var(--mute)}
.claim{transition:border-color .2s}.claim .m{margin:12px 0 0;color:var(--mute);font-size:14px;transition:color .2s}.claim.bad{border-color:var(--bad)}.claim.bad .m{color:var(--bad)}.claim.good{border-color:var(--ok)}.claim.good .m{color:var(--ok)}.claim button:disabled{opacity:.45;cursor:not-allowed}
.steps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin:48px 0 0;padding:0;list-style:none;counter-reset:s}
.steps li{counter-increment:s;padding:20px;border:1px solid var(--line);border-radius:14px;color:var(--mute);font-size:15px}
.steps li::before{content:counter(s);transition:background .3s,color .3s;display:inline-grid;place-items:center;width:24px;height:24px;border-radius:50%;background:var(--chip);color:var(--ink);font:500 12px var(--mono);margin-bottom:10px}
.steps b{display:block;color:var(--ink);font-weight:600;margin-bottom:4px}
.start{margin:40px 0 0;display:flex;flex-direction:column;align-items:flex-start;gap:12px}
.sso{display:inline-flex;align-items:center;box-sizing:border-box;text-decoration:none;white-space:nowrap}.sso svg{flex:none}
.sso{gap:12px;padding:0 18px;height:46px;min-width:270px;border-radius:12px;border:1px solid var(--line);background:var(--panel);color:var(--ink);font:600 15px var(--sans);transition:border-color .15s,background .15s}.sso:hover{border-color:var(--mute);background:var(--chip)}.sso svg{width:20px;height:20px}
.more{display:flex;flex-wrap:wrap;align-items:center;gap:4px 12px;margin:8px 0 0;color:var(--mute);font-size:14px}
.steps.done1 li:first-child::before{content:"¹3";background:var(--acc);color:var(--accink)}.steps.done1 li:first-child b{color:var(--acc2)}
#acct{transition:opacity .22s ease,transform .22s ease}#acct.out{opacity:0;transform:translateX(-24px)}#acct.in{opacity:0;transform:translateX(24px);transition:none}
.why{margin:36px 0 0;max-width:60ch;padding:18px 20px;border-left:2px solid var(--acc);background:color-mix(in srgb,var(--panel) 60%,transparent);border-radius:0 12px 12px 0;color:var(--mute);font-size:15px}.why b{color:var(--ink);font-weight:600}.why p{margin:6px 0 0}
.alt{display:inline-flex;align-items:center;gap:7px;padding:6px 2px;color:var(--ink);text-decoration:none;font-weight:500}.alt svg{width:16px;height:16px;flex:none}.alt:hover{color:var(--acc2)}.foot{margin:64px 0 0;color:var(--mute);font-size:14px}
@media (max-width:720px){.row{grid-template-columns:1fr}.acts{justify-content:flex-start}.steps{grid-template-columns:1fr}}
</style>
<header class="bar"><a class="brand" href="https://{{.Zone}}/"><span class="mk"><svg viewBox="0 0 100 100"><circle cx="27.5" cy="30.5" r="5.4"/><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"/></svg></span>Dokkit</a><span class="crumb">/ <b>Claim a name</b></span></header>
<main>
<h1>Claim a name</h1>
<p class="lede">A name such as <b>yours.{{.Zone}}</b> for your Dokkit server, with a real certificate, even on a private network. Your server proves it holds the name's key before the record goes live, and keeps it renewed. A name lapses when its server stops renewing it.</p>
<ol class="steps{{if .Login}} done1{{end}}" id="steps">
<li><b>Sign in</b>so each name has an owner.</li>
<li><b>Pick a name</b>and get a claim code, shown once.</li>
<li><b>Paste it into your server</b>under Settings, Certificate. It points the name at itself and gets a certificate.</li>
</ol>
<div id="acct">{{template "acct" .}}</div>
<p class="foot">To report a name used for abuse, write to <a href="mailto:{{.Abuse}}">{{.Abuse}}</a>.</p>
</main>
<script src="/app.js"></script>
</html>
{{define "acct"}}{{if .Error}}<p class="msg bad" role="alert">{{.Error}}</p>{{end}}
{{if .Done}}<p class="msg ok" role="status">{{.Done}}</p>{{end}}
{{if .Login}}
<div class="who"><span>Signed in as <b>{{.Login}}</b> through {{.Via}}.</span><form method="post" action="/logout"><button class="small">Sign out</button></form></div>
{{if .Code}}<div class="code" role="status">
<p>Claim code for <b>{{.CodeFor}}</b></p><div class="cv"><code class="v" data-code="{{.Code}}" aria-label="Claim code, hidden">••••••••••••••••••••••••</code><button type="button" class="small" data-reveal>Show</button><button type="button" class="small pri" data-copy>Copy</button></div>
<p class="m">In your Dokkit server, open Settings, Certificate, "A name on {{.Zone}}", and paste it there. It works once, within seven days, and is not shown again.</p></div>{{end}}
<h2>Your names</h2>
{{if .Rows}}<div class="names">
{{range .Rows}}<div class="row">
<div class="n">{{.Name}}</div>
<div class="st"><i class="s {{if eq .State "live"}}ok{{else if eq .State "lapsing"}}warn{{else if eq .State "lapsed"}}bad{{else}}none{{end}}"></i><span>{{.State}}<small>{{.Note}}</small></span></div>
<div class="ad">{{.A}}{{if .AAAA}}<br>{{.AAAA}}{{end}}</div>
<div class="acts">
<form method="post" action="/names/{{.Label}}/code"><input type="hidden" name="csrf" value="{{$.CSRF}}"><button class="small">New claim code</button></form>
<form method="post" action="/names/{{.Label}}/release"><input type="hidden" name="csrf" value="{{$.CSRF}}"><label><input type="checkbox" name="sure" required> sure</label> <button class="small danger">Release</button></form>
<a href="{{.Report}}">Report abuse</a>
</div></div>{{end}}
</div>{{else}}<p class="lede" style="margin-top:0">No names yet.</p>{{end}}
{{if lt (len .Rows) .Max}}<form method="post" action="/claim" class="claim" style="display:block">
<input type="hidden" name="csrf" value="{{.CSRF}}">
<div class="f"><input name="name" aria-label="Name" placeholder="yours" autofocus required maxlength="40" autocomplete="off" autocapitalize="off" spellcheck="false" aria-describedby="claim-say"><span class="z">.{{.Zone}}</span><button class="pri">Claim</button></div>
<p class="m" id="claim-say" aria-live="polite" data-zone="{{.Zone}}" data-hint="3 to 40 lower-case letters, digits and hyphens. At most {{.Max}} names per account.">3 to 40 lower-case letters, digits and hyphens. At most {{.Max}} names per account.</p>
</form>{{end}}
{{else}}
<div class="start">{{if .Demo}}<a class="sso" href="/demo-signin" style="border-color:var(--acc)"><span>Demo: sign in as a made-up user</span></a>{{end}}{{range .Main}}<a class="sso {{.Key}}" href="/login/{{.Key}}">{{template "mark" .}}<span>Sign in with {{.Title}}</span></a>{{end}}
{{with .More}}<p class="more"><span>More:</span>{{range $i, $p := .}}{{if $i}}<span aria-hidden="true">·</span>{{end}}<a class="alt" href="/login/{{$p.Key}}" aria-label="Sign in with {{$p.Title}}">{{template "mark" $p}}{{$p.Title}}</a>{{end}}</p>{{end}}</div>
<div class="why"><b>Why sign in?</b><p>A name points at your server, so it needs an owner. Signing in is what lets only you release a name or move it to a new server, keeps one person to 3 names, and lets a name used for abuse be traced to one account.</p><p>Dokkit keeps only the id your sign-in gives it and a display name. No password, and no email address is asked for.</p></div>
{{end}}
{{end}}
{{define "mark"}}{{- if eq .Key "github"}}<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="#fff" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
{{- else if eq .Key "google"}}<svg viewBox="0 0 48 48" aria-hidden="true"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>
{{- else if eq .Key "microsoft"}}<svg viewBox="0 0 21 21" aria-hidden="true"><path fill="#f25022" d="M1 1h9v9H1z"/><path fill="#7fba00" d="M11 1h9v9h-9z"/><path fill="#00a4ef" d="M1 11h9v9H1z"/><path fill="#ffb900" d="M11 11h9v9h-9z"/></svg>
{{- else if eq .Key "chatgpt"}}<svg viewBox="0 0 21 21" aria-hidden="true"><path fill="#fff" d="M11.8102 19.1625C11.2327 19.1625 10.6841 19.0528 10.1643 18.8334C9.64459 18.6139 9.18259 18.3078 8.77834 17.9151C8.33944 18.0653 7.88322 18.1404 7.40967 18.1404C6.63582 18.1404 5.91972 17.9498 5.26137 17.5686C4.60302 17.1875 4.07172 16.6677 3.66747 16.0094C3.27477 15.351 3.07842 14.6176 3.07842 13.8091C3.07842 13.4742 3.12462 13.1103 3.21702 12.7176C2.75502 12.2903 2.39697 11.7994 2.14287 11.245C1.88877 10.679 1.76172 10.09 1.76172 9.47785C1.76172 8.85415 1.89454 8.25355 2.16019 7.67605C2.42584 7.09855 2.79544 6.6019 3.26899 6.1861C3.75409 5.75875 4.31427 5.46422 4.94952 5.30252C5.07657 4.64417 5.34222 4.05512 5.74647 3.53537C6.16227 3.00407 6.67047 2.58827 7.27107 2.28797C7.87167 1.98767 8.51269 1.83752 9.19414 1.83752C9.77164 1.83752 10.3203 1.94725 10.84 2.1667C11.3598 2.38615 11.8218 2.69222 12.226 3.08492C12.6649 2.93477 13.1211 2.8597 13.5947 2.8597C14.3685 2.8597 15.0846 3.05027 15.743 3.43142C16.4013 3.81257 16.9269 4.33232 17.3196 4.99067C17.7238 5.64902 17.9259 6.38245 17.9259 7.19095C17.9259 7.5259 17.8797 7.88973 17.7873 8.28242C18.2493 8.70977 18.6074 9.20643 18.8615 9.77238C19.1156 10.3268 19.2426 10.91 19.2426 11.5222C19.2426 12.1459 19.1098 12.7465 18.8442 13.324C18.5785 13.9015 18.2031 14.4039 17.718 14.8313C17.2445 15.2471 16.6901 15.5358 16.0548 15.6975C15.9278 16.3559 15.6564 16.9449 15.2406 17.4647C14.8363 17.996 14.3339 18.4118 13.7333 18.7121C13.1327 19.0124 12.4917 19.1625 11.8102 19.1625ZM7.53094 16.9969C8.10844 16.9969 8.61087 16.8756 9.03822 16.6331L12.2953 14.762C12.4108 14.6811 12.4686 14.5714 12.4686 14.4328V12.9429L8.27592 15.351C8.02182 15.5012 7.76772 15.5012 7.51362 15.351L4.23919 13.4626C4.23919 13.4973 4.23342 13.5377 4.22187 13.5839C4.22187 13.6301 4.22187 13.6994 4.22187 13.7918C4.22187 14.3808 4.36047 14.9237 4.63767 15.4203C4.92642 15.9054 5.32489 16.2866 5.83309 16.5638C6.34129 16.8525 6.90724 16.9969 7.53094 16.9969ZM7.70419 14.1729C7.77349 14.2076 7.83702 14.2249 7.89477 14.2249C7.95252 14.2249 8.01027 14.2076 8.06802 14.1729L9.36739 13.4279L5.19207 11.0024C4.93797 10.8523 4.81092 10.6271 4.81092 10.3268V6.56725C4.23342 6.82135 3.77142 7.21405 3.42492 7.74535C3.07842 8.2651 2.90517 8.8426 2.90517 9.47785C2.90517 10.0438 3.04954 10.5866 3.33829 11.1064C3.62704 11.6261 4.00242 12.0189 4.46442 12.2845L7.70419 14.1729ZM11.8102 18.0191C12.4224 18.0191 12.9768 17.8805 13.4734 17.6033C13.9701 17.3261 14.3628 16.9449 14.6515 16.4598C14.9403 15.9747 15.0846 15.4319 15.0846 14.8313V11.0891C15.0846 10.9505 15.0269 10.8465 14.9114 10.7772L13.5947 10.0149V14.8486C13.5947 15.1489 13.4676 15.3741 13.2135 15.5243L9.93912 17.4127C10.5051 17.817 11.1288 18.0191 11.8102 18.0191ZM12.4686 11.6781V9.32192L10.5108 8.21312L8.53579 9.32192V11.6781L10.5108 12.7869L12.4686 11.6781ZM7.40967 6.15145C7.40967 5.85115 7.53672 5.62592 7.79082 5.47577L11.0652 3.58735C10.4993 3.1831 9.87559 2.98097 9.19414 2.98097C8.58199 2.98097 8.02759 3.11957 7.53094 3.39677C7.03429 3.67397 6.64159 4.05512 6.35284 4.54022C6.07564 5.02532 5.93704 5.56817 5.93704 6.16878V9.89365C5.93704 10.0323 5.99479 10.142 6.11029 10.2228L7.40967 10.9851V6.15145ZM16.2108 14.4328C16.7883 14.1787 17.2445 13.786 17.5794 13.2547C17.9259 12.7234 18.0992 12.1459 18.0992 11.5222C18.0992 10.9562 17.9548 10.4134 17.6661 9.89365C17.3773 9.3739 17.0019 8.9812 16.5399 8.71555L13.3002 6.84445C13.2309 6.79825 13.1673 6.78092 13.1096 6.79248C13.0518 6.79248 12.9941 6.8098 12.9363 6.84445L11.637 7.5721L15.8296 10.0149C15.9567 10.0842 16.0491 10.1766 16.1068 10.2921C16.1761 10.3961 16.2108 10.5231 16.2108 10.6733V14.4328ZM12.7284 5.6317C12.9825 5.47 13.2366 5.47 13.4907 5.6317L16.7825 7.55477C16.7825 7.47393 16.7825 7.36997 16.7825 7.24292C16.7825 6.68852 16.6439 6.163 16.3667 5.66635C16.101 5.15815 15.7141 4.7539 15.2059 4.4536C14.7093 4.1533 14.1318 4.00315 13.4734 4.00315C12.8959 4.00315 12.3935 4.12442 11.9661 4.36697L8.70904 6.23808C8.59354 6.31892 8.53579 6.42865 8.53579 6.56725V8.0572L12.7284 5.6317Z"/></svg>
{{- else if eq .Key "apple"}}<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>
{{- else if eq .Key "gitlab"}}<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#FC6D26" d="m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"/></svg>
{{- else if eq .Key "discord"}}<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#5865F2" d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z"/></svg>
{{- else if eq .Key "codeberg"}}<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#2185D0" d="M11.955.49A12 12 0 0 0 0 12.49a12 12 0 0 0 1.832 6.373L11.838 5.928a.187.14 0 0 1 .324 0l10.006 12.935A12 12 0 0 0 24 12.49a12 12 0 0 0-12-12 12 12 0 0 0-.045 0zm.375 6.467l4.416 16.553a12 12 0 0 0 5.137-4.213z"/></svg>
{{- end}}{{end}}`))

const appJS = `(() => {
  if (document.body.hasAttribute("data-signed-in")) {
    if (window.opener) { window.opener.postMessage("dokkit-signed-in", location.origin); window.close(); }
    else location.replace("/");
    return;
  }
  const acct = document.getElementById("acct");
  async function swap() {
    const res = await fetch("/part", { credentials: "same-origin" });
    if (!res.ok) return location.reload();
    const html = await res.text();
    acct.classList.add("out");
    await new Promise(r => setTimeout(r, 220));
    acct.innerHTML = html;
    document.getElementById("steps").classList.toggle("done1", !!acct.querySelector(".who"));
    acct.classList.replace("out", "in");
    requestAnimationFrame(() => requestAnimationFrame(() => acct.classList.remove("in")));
    armed();
    acct.querySelector("input[name=name]")?.focus({ preventScroll: true });
  }
  const rules = [
    [v => /[^a-z0-9-]/.test(v), "Only lower-case letters, digits and hyphens."],
    [v => v.startsWith("-"), "It can't start with a hyphen."],
    [v => v.length < 3, "At least 3 characters."],
    [v => v.length > 40, "At most 40 characters."],
    [v => v.endsWith("-"), "It can't end with a hyphen."],
    [v => v.length >= 4 && v.slice(2, 4) === "--", "It can't have two hyphens in the third and fourth places."],
  ];
  let timer, asked = 0;
  function mark(form, state, text) {
    const say = form.querySelector("#claim-say");
    form.classList.toggle("bad", state === "bad");
    form.classList.toggle("good", state === "good");
    say.textContent = text ?? say.dataset.hint;
    form.querySelector("button").disabled = state !== "good";
  }
  function armed() {
    const box = document.querySelector("form.claim input[name=name]");
    if (box && !box.value) box.form.querySelector("button").disabled = true;
  }
  armed();
  document.addEventListener("input", e => {
    const box = e.target.closest("form.claim input[name=name]");
    if (!box) return;
    const form = box.form, at = box.selectionStart;
    box.value = box.value.toLowerCase().replace(/\s/g, "");
    box.setSelectionRange(at, at);
    const v = box.value, say = form.querySelector("#claim-say");
    clearTimeout(timer);
    asked++;
    if (!v) return mark(form, "", null);
    const broken = rules.find(([test]) => test(v));
    if (broken) return mark(form, "bad", broken[1]);
    mark(form, "", "Checking " + v + "." + say.dataset.zone + "…");
    const mine = asked;
    timer = setTimeout(async () => {
      const res = await fetch("/check?name=" + encodeURIComponent(v), { credentials: "same-origin" });
      const out = await res.json().catch(() => ({ ok: false, reason: "That name could not be checked." }));
      if (mine === asked) mark(form, out.ok ? "good" : "bad", out.reason);
    }, 250);
  });
  document.addEventListener("click", async e => {
    const reveal = e.target.closest("[data-reveal]"), copy = e.target.closest("[data-copy]");
    if (!reveal && !copy) return;
    const code = e.target.closest(".cv").querySelector("[data-code]");
    if (reveal) {
      const shown = reveal.textContent === "Hide";
      code.textContent = shown ? "•".repeat(24) : code.dataset.code;
      code.setAttribute("aria-label", shown ? "Claim code, hidden" : "Claim code");
      reveal.textContent = shown ? "Show" : "Hide";
      return;
    }
    try { await navigator.clipboard.writeText(code.dataset.code); copy.textContent = "Copied"; }
    catch { copy.textContent = "Press Show, then copy it"; }
    setTimeout(() => (copy.textContent = "Copy"), 1800);
  });
  addEventListener("message", e => { if (e.origin === location.origin && e.data === "dokkit-signed-in") swap(); });
  document.addEventListener("click", async e => {
    const a = e.target.closest("a[href^='/login/'], a[href='/demo-signin']");
    if (!a || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    if (a.getAttribute("href") === "/demo-signin") { await fetch("/demo-signin", { credentials: "same-origin" }); return swap(); }
    const w = 520, h = 680, x = screenX + (outerWidth - w) / 2, y = screenY + (outerHeight - h) / 3;
    const pop = open(a.href + "?popup=1", "dokkit-signin", "popup,width=" + w + ",height=" + h + ",left=" + x + ",top=" + y);
    if (!pop) location.href = a.href;
  });
  document.addEventListener("submit", async e => {
    if (e.target.getAttribute("action") !== "/logout") return;
    e.preventDefault();
    await fetch("/logout", { method: "POST", credentials: "same-origin" });
    swap();
  });
})();
`
