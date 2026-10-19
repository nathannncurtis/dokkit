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
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxBody     = 8 << 10
	sessionLife = 14 * 24 * time.Hour
)

type GitHub struct {
	ClientID, Secret string
	Web, API         string
	Client           *http.Client
}

type App struct {
	Svc     *Service
	Base    string
	GitHub  GitHub
	Abuse   string
	Secret  []byte
	replays Replays
	Limits  Limiter
}

type session struct {
	ID    int64  `json:"id"`
	Login string `json:"login"`
	Exp   int64  `json:"exp"`
}

func (a *App) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.home)
	mux.HandleFunc("GET /login", a.login)
	mux.HandleFunc("GET /callback", a.callback)
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
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		if !a.Limits.Allow(clientIP(r), time.Now()) {
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
	if err != nil || json.Unmarshal(raw, &s) != nil || time.Now().Unix() > s.Exp {
		return nil, ""
	}
	return &s, a.mac("csrf|" + c.Value)
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	state := randomHex(16)
	a.setCookie(w, "st", state, 10*time.Minute)
	q := url.Values{"client_id": {a.GitHub.ClientID}, "redirect_uri": {a.Base + "/callback"}, "state": {state}}
	http.Redirect(w, r, a.GitHub.Web+"/login/oauth/authorize?"+q.Encode(), http.StatusFound)
}

func (a *App) callback(w http.ResponseWriter, r *http.Request) {
	c, err := r.Cookie("st")
	if err != nil || r.URL.Query().Get("state") == "" || !hmac.Equal([]byte(c.Value), []byte(r.URL.Query().Get("state"))) {
		a.page(w, r, http.StatusBadRequest, view{Error: "The sign-in took too long or came from elsewhere. Sign in again."})
		return
	}
	a.setCookie(w, "st", "", -1)
	id, login, err := a.githubUser(r.URL.Query().Get("code"))
	if err != nil {
		log.Printf("github sign-in: %v", err)
		a.page(w, r, http.StatusBadGateway, view{Error: "GitHub did not confirm the sign-in. Try again."})
		return
	}
	raw, _ := json.Marshal(session{ID: id, Login: login, Exp: time.Now().Add(sessionLife).Unix()})
	body := b64.EncodeToString(raw)
	a.setCookie(w, "s", body+"."+a.mac("s|"+body), sessionLife)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) githubUser(code string) (int64, string, error) {
	client := a.GitHub.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	form := url.Values{"client_id": {a.GitHub.ClientID}, "client_secret": {a.GitHub.Secret},
		"code": {code}, "redirect_uri": {a.Base + "/callback"}}
	req, _ := http.NewRequest("POST", a.GitHub.Web+"/login/oauth/access_token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := getJSON(client, req, &tok); err != nil {
		return 0, "", err
	}
	if tok.AccessToken == "" {
		return 0, "", errors.New("no access token: " + tok.Error)
	}
	req, _ = http.NewRequest("GET", a.GitHub.API+"/user", nil)
	req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "dokkit-names")
	var user struct {
		ID    int64  `json:"id"`
		Login string `json:"login"`
	}
	if err := getJSON(client, req, &user); err != nil {
		return 0, "", err
	}
	if user.ID == 0 {
		return 0, "", errors.New("github returned no user id")
	}
	return user.ID, user.Login, nil
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

func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	a.setCookie(w, "s", "", -1)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// The page

type row struct {
	Name, Label, State, Note, A, AAAA, Report string
}

type view struct {
	Login, CSRF, Error, Done, Code, CodeFor string
	Rows                                    []row
	Zone                                    string
	Abuse                                   string
	Max                                     int
	Status                                  int
}

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
	code, err := a.Svc.Claim(s.ID, s.Login, label)
	return view{Code: code, CodeFor: a.Svc.fqdn(label)}, err
}

func (a *App) newCode(s *session, r *http.Request) (view, error) {
	label := r.PathValue("label")
	code, err := a.Svc.NewCode(s.ID, label)
	return view{Code: code, CodeFor: a.Svc.fqdn(label)}, err
}

func (a *App) release(s *session, r *http.Request) (view, error) {
	label := r.PathValue("label")
	err := a.Svc.Release(s.ID, label)
	return view{Done: a.Svc.fqdn(label) + " is released."}, err
}

func (a *App) home(w http.ResponseWriter, r *http.Request) {
	a.page(w, r, http.StatusOK, view{})
}

func (a *App) page(w http.ResponseWriter, r *http.Request, status int, v view) {
	v.Zone, v.Abuse, v.Max = a.Svc.Zone, a.Abuse, perAccount
	if s, csrf := a.session(r); s != nil {
		v.Login, v.CSRF = s.Login, csrf
		for _, n := range a.Svc.Mine(s.ID) {
			state, note := a.Svc.State(n)
			fq := a.Svc.fqdn(n.Label)
			v.Rows = append(v.Rows, row{Name: fq, Label: n.Label, State: state, Note: note, A: n.A, AAAA: n.AAAA,
				Report: "mailto:" + a.Abuse + "?subject=" + url.PathEscape("Report "+fq)})
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := pageTmpl.Execute(w, v); err != nil {
		log.Printf("page: %v", err)
	}
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
.code p{margin:0}.code .v{margin:14px 0;font:500 clamp(18px,2.2vw,24px) var(--mono);letter-spacing:.04em;color:var(--acc2);background:var(--well);border:1px solid var(--line);border-radius:10px;padding:14px 18px;user-select:all;overflow-wrap:anywhere}
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
.claim .m{margin:12px 0 0;color:var(--mute);font-size:14px}
.steps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;margin:48px 0 0;padding:0;list-style:none;counter-reset:s}
.steps li{counter-increment:s;padding:20px;border:1px solid var(--line);border-radius:14px;color:var(--mute);font-size:15px}
.steps li::before{content:counter(s);display:inline-grid;place-items:center;width:24px;height:24px;border-radius:50%;background:var(--chip);color:var(--ink);font:500 12px var(--mono);margin-bottom:10px}
.steps b{display:block;color:var(--ink);font-weight:600;margin-bottom:4px}
.start{margin:40px 0 0}.foot{margin:64px 0 0;color:var(--mute);font-size:14px}
@media (max-width:720px){.row{grid-template-columns:1fr}.acts{justify-content:flex-start}.steps{grid-template-columns:1fr}}
</style>
<header class="bar"><a class="brand" href="https://{{.Zone}}/"><span class="mk"><svg viewBox="0 0 100 100"><circle cx="27.5" cy="30.5" r="5.4"/><path d="M39 25H53A23 23 0 0 1 53 71H28A4 4 0 0 1 24 67V43A4 4 0 0 1 28 39H33A4 4 0 0 1 37 43V60H53A12 12 0 0 0 53 36H39A3.5 3.5 0 0 1 35.5 32.5V28.5A3.5 3.5 0 0 1 39 25Z"/></svg></span>Dokkit</a><span class="crumb">/ <b>Claim a name</b></span></header>
<main>
<h1>Claim a name</h1>
<p class="lede">A name such as <b>yours.{{.Zone}}</b> for your Dokkit server, with a real certificate, even on a private network. Your server proves it holds the name's key before the record goes live, and keeps it renewed. A name lapses when its server stops renewing it.</p>
{{if .Error}}<p class="msg bad" role="alert">{{.Error}}</p>{{end}}
{{if .Done}}<p class="msg ok" role="status">{{.Done}}</p>{{end}}
{{if .Login}}
<div class="who"><span>Signed in as <b>{{.Login}}</b> through GitHub.</span><form method="post" action="/logout"><button class="small">Sign out</button></form></div>
{{if .Code}}<div class="code" role="status">
<p>Claim code for <b>{{.CodeFor}}</b></p><p class="v">{{.Code}}</p>
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
<div class="f"><input name="name" aria-label="Name" placeholder="yours" required minlength="3" maxlength="40" pattern="[a-z0-9][a-z0-9\-]{1,38}[a-z0-9]" autocomplete="off" spellcheck="false"><span class="z">.{{.Zone}}</span><button class="pri">Claim</button></div>
<p class="m">3 to 40 lower-case letters, digits and hyphens. At most {{.Max}} names per account.</p>
</form>{{end}}
{{else}}
<ol class="steps">
<li><b>Sign in</b>with GitHub, so each name has an owner.</li>
<li><b>Pick a name</b>and get a claim code, shown once.</li>
<li><b>Paste it into your server</b>under Settings, Certificate. It points the name at itself and gets a certificate.</li>
</ol>
<p class="start"><a class="btn pri" href="/login">Sign in with GitHub</a></p>
{{end}}
<p class="foot">To report a name used for abuse, write to <a href="mailto:{{.Abuse}}">{{.Abuse}}</a>.</p>
</main>
</html>
`))
