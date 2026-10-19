package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"syscall"
	"time"
)

const (
	beatAfter  = 5 * time.Minute
	beatForget = 30 * 24 * time.Hour
)

// No account: only the key the creating server holds can change or remove a beat.
type Beat struct {
	Token   string    `json:"token"`
	KeyHash string    `json:"key_hash"`
	Label   string    `json:"label"`
	Kind    string    `json:"kind"` // ntfy or webhook
	Notify  string    `json:"notify"`
	Created time.Time `json:"created"`
	Seen    time.Time `json:"seen,omitempty"`
	Down    time.Time `json:"down,omitempty"`
}

type Message struct {
	Event, Label, Kind, Notify string
	Seen, At                   time.Time
}

type beatIn struct {
	Label  string `json:"label"`
	Kind   string `json:"kind"`
	Notify string `json:"notify"`
}

func (in beatIn) check() (beatIn, error) {
	in.Label = strings.TrimSpace(in.Label)
	in.Notify = strings.TrimSpace(in.Notify)
	if in.Label == "" || len(in.Label) > 80 {
		return in, refuse(400, "label is the server's name, 1 to 80 characters.")
	}
	if in.Kind != "ntfy" && in.Kind != "webhook" {
		return in, refuse(400, "kind is ntfy or webhook.")
	}
	u, err := url.Parse(in.Notify)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return in, refuse(400, "notify is an https address, such as https://ntfy.sh/your-topic.")
	}
	if in.Kind == "ntfy" && strings.Trim(u.Path, "/") == "" {
		return in, refuse(400, "An ntfy address ends in the topic, such as https://ntfy.sh/your-topic.")
	}
	return in, nil
}

func (s *Service) AddBeat(in beatIn) (token, key string, err error) {
	if in, err = in.check(); err != nil {
		return "", "", err
	}
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	if len(s.Store.s.Beats) >= s.Max {
		return "", "", refuse(503, "No more heartbeats can be handed out for now.")
	}
	token, key = randomHex(16), randomHex(24)
	s.Store.s.Beats[token] = &Beat{Token: token, KeyHash: hashCode(key), Label: in.Label, Kind: in.Kind, Notify: in.Notify, Created: s.Now()}
	return token, key, s.Store.save()
}

func (s *Service) beatFor(token, key string) (*Beat, error) {
	b := s.Store.s.Beats[token]
	if b == nil || !hmac.Equal([]byte(b.KeyHash), []byte(hashCode(key))) {
		return nil, refuse(404, "No such heartbeat, or not its key.")
	}
	return b, nil
}

func (s *Service) ChangeBeat(token, key string, in beatIn) error {
	in, err := in.check()
	if err != nil {
		return err
	}
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	b, err := s.beatFor(token, key)
	if err != nil {
		return err
	}
	b.Label, b.Kind, b.Notify = in.Label, in.Kind, in.Notify
	return s.Store.save()
}

func (s *Service) RemoveBeat(token, key string) error {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	if _, err := s.beatFor(token, key); err != nil {
		return err
	}
	delete(s.Store.s.Beats, token)
	return s.Store.save()
}

func (b *Beat) message(event string, at time.Time) Message {
	return Message{Event: event, Label: b.Label, Kind: b.Kind, Notify: b.Notify, Seen: b.Seen, At: at}
}

func (s *Service) Called(token string) (*Message, bool) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	b := s.Store.s.Beats[token]
	if b == nil {
		return nil, false
	}
	now := s.Now()
	b.Seen = now
	if b.Down.IsZero() {
		return nil, true
	}
	b.Down = time.Time{}
	m := b.message("up", now)
	if err := s.Store.save(); err != nil {
		log.Printf("beats: %v", err)
	}
	return &m, true
}

// Nothing goes down until this service has itself been up five minutes, so its restart never alerts.
func (s *Service) Watch(booted time.Time) []Message {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	now := s.Now()
	var out []Message
	for token, b := range s.Store.s.Beats {
		last := b.Seen
		if last.IsZero() {
			last = b.Created
		}
		if now.Sub(last) > beatForget {
			delete(s.Store.s.Beats, token)
			continue
		}
		if b.Seen.IsZero() || !b.Down.IsZero() || now.Sub(b.Seen) < beatAfter || now.Sub(booted) < beatAfter {
			continue
		}
		b.Down = now
		out = append(out, b.message("down", now))
	}
	if err := s.Store.save(); err != nil {
		log.Printf("beats: %v", err)
	}
	return out
}

func (m Message) text() (title, body string) {
	if m.Event == "down" {
		return m.Label + " stopped calling", fmt.Sprintf("Dokkit server %q has not called its outside heartbeat for %d minutes. Last call %s.", m.Label, int(beatAfter.Minutes()), m.Seen.UTC().Format("2 Jan 15:04 UTC"))
	}
	return m.Label + " is calling again", fmt.Sprintf("Dokkit server %q called its outside heartbeat again at %s.", m.Label, m.At.UTC().Format("2 Jan 15:04 UTC"))
}

// Sender posts alerts only to public addresses, so a heartbeat cannot be aimed at this machine
// or its cloud's metadata service.
type Sender struct {
	Client *http.Client
}

func publicOnly(_, address string, _ syscall.RawConn) error {
	ap, err := netip.ParseAddrPort(address)
	if err != nil {
		return err
	}
	a := ap.Addr().Unmap()
	if !a.IsGlobalUnicast() || a.IsPrivate() || a.IsLoopback() || a.IsLinkLocalUnicast() {
		return fmt.Errorf("%s is not a public address", a)
	}
	return nil
}

func NewSender() *Sender {
	d := &net.Dialer{Timeout: 10 * time.Second, Control: publicOnly}
	return &Sender{Client: &http.Client{Timeout: 20 * time.Second,
		Transport:     &http.Transport{DialContext: d.DialContext, Proxy: nil, TLSHandshakeTimeout: 10 * time.Second},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (sn *Sender) Send(ctx context.Context, m Message) error {
	title, body := m.text()
	var req *http.Request
	var err error
	if m.Kind == "ntfy" {
		req, err = http.NewRequestWithContext(ctx, "POST", m.Notify, strings.NewReader(body))
		if err == nil {
			req.Header.Set("Title", title)
			req.Header.Set("Tags", map[string]string{"down": "rotating_light", "up": "white_check_mark"}[m.Event])
			if m.Event == "down" {
				req.Header.Set("Priority", "high")
			}
		}
	} else {
		payload := map[string]any{"event": m.Event, "server": m.Label, "title": title, "text": body, "at": m.At.UTC()}
		if !m.Seen.IsZero() {
			payload["last_call"] = m.Seen.UTC()
		}
		raw, _ := json.Marshal(payload)
		req, err = http.NewRequestWithContext(ctx, "POST", m.Notify, bytes.NewReader(raw))
		if err == nil {
			req.Header.Set("Content-Type", "application/json")
		}
	}
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "dokkit.dev heartbeat")
	resp, err := sn.Client.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		return errors.New(resp.Status)
	}
	return nil
}

func (sn *Sender) Deliver(m Message) {
	for i, wait := range []time.Duration{0, 30 * time.Second, 2 * time.Minute, 8 * time.Minute} {
		time.Sleep(wait)
		err := sn.Send(context.Background(), m)
		if err == nil {
			return
		}
		log.Printf("beats: %s alert for %q, try %d: %v", m.Event, m.Label, i+1, err)
	}
}

func (a *App) called(w http.ResponseWriter, r *http.Request) {
	m, ok := a.Svc.Called(r.PathValue("token"))
	if !ok {
		http.Error(w, "No such heartbeat.", http.StatusNotFound)
		return
	}
	if m != nil {
		go a.Sender.Deliver(*m)
	}
	io.WriteString(w, "ok\n")
}

func readBeat(w http.ResponseWriter, r *http.Request) (beatIn, error) {
	var in beatIn
	body, err := readAll(w, r)
	if err == nil && json.Unmarshal(body, &in) != nil {
		err = refuse(400, "The body is JSON with label, kind and notify.")
	}
	return in, err
}

// newBeat makes a heartbeat for whoever asks, three an hour from one address, as the shared relay does.
func (a *App) newBeat(w http.ResponseWriter, r *http.Request) {
	if !a.signups.Allow(clientIP(r), time.Now()) {
		a.fail(w, refuse(429, "Three heartbeats an hour from one address. Try again later."))
		return
	}
	in, err := readBeat(w, r)
	if err != nil {
		a.fail(w, err)
		return
	}
	token, key, err := a.Svc.AddBeat(in)
	if err != nil {
		a.fail(w, err)
		return
	}
	a.reply(w, 201, map[string]string{"url": a.Beat + "/" + token, "token": token, "key": key})
}

func (a *App) changeBeat(w http.ResponseWriter, r *http.Request) {
	token, key := r.PathValue("token"), strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	var err error
	if r.Method == http.MethodDelete {
		err = a.Svc.RemoveBeat(token, key)
	} else {
		var in beatIn
		if in, err = readBeat(w, r); err == nil {
			err = a.Svc.ChangeBeat(token, key, in)
		}
	}
	if err != nil {
		a.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
