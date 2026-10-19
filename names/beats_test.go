package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type inbox struct {
	mu  sync.Mutex
	got []string
	srv *httptest.Server
}

func newInbox(t *testing.T) *inbox {
	in := &inbox{}
	in.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		in.mu.Lock()
		in.got = append(in.got, r.Header.Get("Title")+"|"+string(b))
		in.mu.Unlock()
	}))
	t.Cleanup(in.srv.Close)
	return in
}

func (in *inbox) all() []string {
	in.mu.Lock()
	defer in.mu.Unlock()
	return append([]string(nil), in.got...)
}

func (rg *rig) beatCall(method, path, key, body string) (int, map[string]string) {
	req, _ := http.NewRequest(method, rg.srv.URL+path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		rg.t.Fatal(err)
	}
	var out map[string]string
	json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	return resp.StatusCode, out
}

func TestHeartbeat(t *testing.T) {
	rg := newRig(t)
	in := newInbox(t)
	rg.app.Beat = rg.srv.URL + "/beat"
	rg.app.Sender = &Sender{Client: in.srv.Client()}
	rg.app.signups = Limiter{Burst: 2, PerSecond: 1e-9}

	if st, _ := rg.beatCall("POST", "/v1/beats", "", `{"label":"office","kind":"ntfy","notify":"http://ntfy.sh/x"}`); st != 400 {
		t.Fatalf("plain http answered %d", st)
	}
	st, made := rg.beatCall("POST", "/v1/beats", "", `{"label":"office","kind":"ntfy","notify":"https://ntfy.sh/x"}`)
	if st != 201 || !strings.HasPrefix(made["url"], rg.app.Beat+"/") || made["key"] == "" {
		t.Fatalf("make answered %d %v", st, made)
	}
	if st, _ := rg.beatCall("POST", "/v1/beats", "", `{"label":"third","kind":"ntfy","notify":"https://ntfy.sh/x"}`); st != 429 {
		t.Fatalf("past the hourly limit answered %d", st)
	}
	token := made["token"]
	if resp, _ := http.Get(rg.srv.URL + "/beat/nope"); resp.StatusCode != 404 {
		t.Fatal("an unknown heartbeat was accepted")
	}

	booted := rg.clock()
	rg.advance(10 * time.Minute)
	if len(rg.svc.Watch(booted)) != 0 {
		t.Fatal("a heartbeat that never called went down")
	}
	if resp, _ := http.Get(made["url"]); resp.StatusCode != 200 {
		t.Fatal("the call was refused")
	}
	rg.advance(4 * time.Minute)
	if len(rg.svc.Watch(booted)) != 0 {
		t.Fatal("down before five minutes")
	}
	rg.advance(2 * time.Minute)
	if len(rg.svc.Watch(rg.clock().Add(-2*time.Minute))) != 0 {
		t.Fatal("down while the service itself had just started")
	}
	down := rg.svc.Watch(booted)
	if len(down) != 1 || down[0].Event != "down" || len(rg.svc.Watch(booted)) != 0 {
		t.Fatalf("down alerts: %+v", down)
	}

	if st, _ := rg.beatCall("PUT", "/v1/beats/"+token, "wrong", `{"label":"office","kind":"webhook","notify":"https://example.com/h"}`); st != 404 {
		t.Fatalf("a wrong key changed it: %d", st)
	}
	if st, _ := rg.beatCall("PUT", "/v1/beats/"+token, made["key"], `{"label":"office 2","kind":"webhook","notify":"https://example.com/h"}`); st != 204 {
		t.Fatalf("change answered %d", st)
	}
	m, ok := rg.svc.Called(token)
	if !ok || m == nil || m.Event != "up" || m.Label != "office 2" || m.Kind != "webhook" {
		t.Fatalf("coming back: %+v", m)
	}

	m.Notify = in.srv.URL
	if err := rg.app.Sender.Send(t.Context(), *m); err != nil {
		t.Fatal(err)
	}
	ntfy := Message{Event: "down", Label: "office", Kind: "ntfy", Notify: in.srv.URL + "/topic", Seen: rg.clock(), At: rg.clock()}
	if err := rg.app.Sender.Send(t.Context(), ntfy); err != nil {
		t.Fatal(err)
	}
	got := in.all()
	var payload map[string]any
	json.Unmarshal([]byte(strings.SplitN(got[0], "|", 2)[1]), &payload)
	if payload["event"] != "up" || payload["server"] != "office 2" || payload["last_call"] == nil {
		t.Fatalf("webhook got %v", payload)
	}
	if !strings.HasPrefix(got[1], "office stopped calling|") {
		t.Fatalf("ntfy got %q", got[1])
	}

	if st, _ := rg.beatCall("DELETE", "/v1/beats/"+token, made["key"], ""); st != 204 || len(rg.svc.Store.s.Beats) != 0 {
		t.Fatalf("remove answered %d", st)
	}
}

func TestHeartbeatsForgotten(t *testing.T) {
	rg := newRig(t)
	token, _, err := rg.svc.AddBeat(beatIn{Label: "gone", Kind: "ntfy", Notify: "https://ntfy.sh/x"})
	if err != nil {
		t.Fatal(err)
	}
	again, _ := OpenStore(rg.svc.Store.path)
	if again.s.Beats[token] == nil {
		t.Fatal("the heartbeat was not saved")
	}
	rg.advance(31 * 24 * time.Hour)
	rg.svc.Watch(rg.clock().Add(-time.Hour))
	if len(rg.svc.Store.s.Beats) != 0 {
		t.Fatal("a heartbeat silent for 31 days was kept")
	}
}

func TestSenderRefusesPrivateAddresses(t *testing.T) {
	in := newInbox(t)
	m := Message{Event: "down", Label: "x", Kind: "webhook", Notify: in.srv.URL}
	if err := NewSender().Send(t.Context(), m); err == nil || !strings.Contains(err.Error(), "not a public address") {
		t.Fatalf("sent to loopback: %v", err)
	}
	for _, a := range []string{"169.254.169.254:80", "10.0.0.1:443", "[::1]:443", "192.168.1.1:443"} {
		if publicOnly("tcp", a, nil) == nil {
			t.Fatalf("%s was allowed", a)
		}
	}
	if publicOnly("tcp", "1.1.1.1:443", nil) != nil {
		t.Fatal("a public address was refused")
	}
}
