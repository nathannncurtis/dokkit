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
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
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
<title>Names on {{.Zone}}</title>
<style>
:root{color-scheme:light dark;--bg:#fbfaf8;--fg:#1d1b19;--mute:#6b6560;--line:#e4e0da;--bad:#b3261e;--ok:#1f7a43}
@media (prefers-color-scheme:dark){:root{--bg:#161514;--fg:#ece8e3;--mute:#a19a93;--line:#34312e;--bad:#f2b8b5;--ok:#7fd3a0}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:32px 16px}
h1{font-size:1.5rem;margin:0 0 4px}p{margin:8px 0}.mute{color:var(--mute)}.bad{color:var(--bad)}.ok{color:var(--ok)}
table{width:100%;border-collapse:collapse;margin:16px 0}td,th{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line);vertical-align:top}
input{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:transparent;color:inherit}
button,.btn{font:inherit;padding:6px 12px;border:1px solid var(--line);border-radius:6px;background:transparent;color:inherit;cursor:pointer;text-decoration:none;display:inline-block}
form{display:inline}code{font-size:1.1rem;padding:2px 6px;border:1px solid var(--line);border-radius:6px;user-select:all}
.box{border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:16px 0}
</style>
<main>
<h1>Names on {{.Zone}}</h1>
<p class="mute">A name such as <b>yours.{{.Zone}}</b> for your Dokkit server, with a real certificate, even on a private network. Your server proves it holds the name's key before the record goes live, and keeps it renewed. A name lapses when its server stops renewing it.</p>
{{if .Error}}<p class="bad" role="alert">{{.Error}}</p>{{end}}
{{if .Done}}<p class="ok" role="status">{{.Done}}</p>{{end}}
{{if .Login}}
<p>Signed in as {{.Login}} through GitHub. <form method="post" action="/logout"><button>Sign out</button></form></p>
{{if .Code}}<div class="box" role="status">
<p>Claim code for <b>{{.CodeFor}}</b>:</p><p><code>{{.Code}}</code></p>
<p class="mute">Paste it into your Dokkit server under Settings, Certificate, "A name on {{.Zone}}". It works once, within seven days, and is not shown again.</p></div>{{end}}
{{if .Rows}}<table>
<tr><th>Name</th><th>State</th><th>Address</th><th></th></tr>
{{range .Rows}}<tr>
<td><b>{{.Name}}</b></td>
<td>{{.State}}<br><span class="mute">{{.Note}}</span></td>
<td>{{.A}}{{if .AAAA}}<br>{{.AAAA}}{{end}}</td>
<td>
<form method="post" action="/names/{{.Label}}/code"><input type="hidden" name="csrf" value="{{$.CSRF}}"><button>New claim code</button></form>
<form method="post" action="/names/{{.Label}}/release"><input type="hidden" name="csrf" value="{{$.CSRF}}"><label><input type="checkbox" name="sure" required> sure</label> <button>Release</button></form>
<a href="{{.Report}}">Report abuse</a>
</td></tr>{{end}}
</table>{{else}}<p class="mute">No names yet.</p>{{end}}
{{if lt (len .Rows) .Max}}<form method="post" action="/claim" class="box" style="display:block">
<input type="hidden" name="csrf" value="{{.CSRF}}">
<label>Name <input name="name" required minlength="3" maxlength="40" pattern="[a-z0-9][a-z0-9\-]{1,38}[a-z0-9]" autocomplete="off" spellcheck="false"></label>.{{.Zone}}
<button>Claim</button>
<p class="mute">3 to 40 lower-case letters, digits and hyphens. At most {{.Max}} names per account.</p>
</form>{{end}}
{{else}}
<p><a class="btn" href="/login">Sign in with GitHub</a></p>
{{end}}
<p class="mute">To report a name used for abuse, write to <a href="mailto:{{.Abuse}}">{{.Abuse}}</a>.</p>
</main>
</html>
`))
