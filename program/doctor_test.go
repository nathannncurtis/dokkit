package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"syscall"
	"testing"
	"time"
)

func reach(t *testing.T, address string) error {
	t.Helper()
	req, _ := http.NewRequest("GET", address+"/api/v1/ping", nil)
	_, err := (&http.Client{Transport: toServer, Timeout: 5 * time.Second}).Do(req)
	if err == nil {
		t.Fatal("expected the request to fail")
	}
	return err
}

func TestDoctorNamesAPinMismatchAndAnUntrustedCertificate(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	was := toServer
	defer func() { toServer = was }()

	toServer = http.DefaultTransport
	what, todo := explainReach(reach(t, srv.URL), srv.URL)
	if !strings.Contains(what, "not signed by an authority") || !strings.Contains(todo, "fingerprint") {
		t.Fatalf("untrusted: %q %q", what, todo)
	}

	pinTo(strings.Repeat("0", 64))
	what, todo = explainReach(reach(t, srv.URL), srv.URL)
	if !strings.Contains(what, "not the one this machine enrolled with") || !strings.Contains(todo, "enrol again") {
		t.Fatalf("pin: %q %q", what, todo)
	}

	sum := sha256.Sum256(srv.Certificate().Raw)
	pinTo(hex.EncodeToString(sum[:]))
	req, _ := http.NewRequest("GET", srv.URL, nil)
	if res, err := (&http.Client{Transport: toServer}).Do(req); err != nil {
		t.Fatalf("the right pin is trusted: %v", err)
	} else {
		res.Body.Close()
	}
}

func TestDoctorNamesARefusedConnectionAndPlainHTTP(t *testing.T) {
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	what, _ := explainReach(reach(t, "http://"+addr), "http://"+addr)
	if !strings.Contains(what, "nothing is listening on port") {
		t.Fatalf("refused: %q", what)
	}

	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer plain.Close()
	https := "https://" + strings.TrimPrefix(plain.URL, "http://")
	what, _ = explainReach(reach(t, https), https)
	if !strings.Contains(what, "not with TLS") {
		t.Fatalf("plain http: %q", what)
	}
}

func TestDoctorNamesDNSTimeoutAndNoRoute(t *testing.T) {
	what, _ := explainReach(&net.DNSError{Err: "no such host", Name: "dokkit.example", IsNotFound: true}, "https://dokkit.example")
	if !strings.Contains(what, "dokkit.example does not resolve") {
		t.Fatalf("dns: %q", what)
	}
	what, _ = explainReach(fmt.Errorf("Get x: %w", &net.OpError{Op: "dial", Err: syscall.ETIMEDOUT}), "https://dokkit.example")
	if !strings.Contains(what, "did not answer in time") {
		t.Fatalf("dial timeout: %q", what)
	}
	what, _ = explainReach(&net.OpError{Op: "dial", Err: syscall.EHOSTUNREACH}, "https://dokkit.example")
	if !strings.Contains(what, "no route to dokkit.example") {
		t.Fatalf("no route: %q", what)
	}
	what, _ = explainReach(timeoutErr{}, "https://dokkit.example")
	if !strings.Contains(what, "did not answer in time") {
		t.Fatalf("timeout: %q", what)
	}
	what, _ = explainReach(fmt.Errorf("something odd"), "https://dokkit.example")
	if !strings.HasPrefix(what, "Cannot reach the server: something odd") {
		t.Fatalf("unknown: %q", what)
	}
}

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestDoctorReadsTheKeyAndTheClock(t *testing.T) {
	var behind time.Duration
	var code = 200
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(code)
		fmt.Fprintf(w, `{"time":%q}`, time.Now().Add(behind).Format(time.RFC3339))
	}))
	defer srv.Close()
	t.Setenv("DOKKIT_URL", srv.URL)
	t.Setenv("DOKKIT_KEY", "dkm_x")
	t.Setenv("DOKKIT_CONFIG", t.TempDir()+"/c.json")
	t.Setenv("DOKKIT_SPOOL", t.TempDir())
	run := func() int {
		c, err := load()
		if err != nil {
			t.Fatal(err)
		}
		return c.doctor()
	}
	if run() != 0 {
		t.Fatal("a good server and clock pass")
	}
	behind = 5 * time.Minute
	if run() != 1 {
		t.Fatal("a clock five minutes off fails")
	}
	code = 401
	if run() != 1 {
		t.Fatal("a key the server does not know fails")
	}
	what, todo := explainStatus(401)
	if !strings.Contains(what, "does not know this key") || !strings.Contains(todo, "enrol") {
		t.Fatalf("401: %q %q", what, todo)
	}
	if what, _ := explainStatus(502); !strings.Contains(what, "failing") {
		t.Fatalf("5xx: %q", what)
	}
}

func TestLocalNetworkAddressesAndAStuckWatch(t *testing.T) {
	for addr, want := range map[string]bool{
		"https://192.168.1.20:8443": true, "http://10.0.0.5": true, "http://169.254.1.1": true,
		"https://mini.local": true, "https://server": true, "https://8.8.8.8": false,
	} {
		if got := onLocalNetwork(addr); got != want {
			t.Errorf("%s: want %v", addr, want)
		}
	}
	was := lookupHost
	defer func() { lookupHost = was }()
	lookupHost = func(string) []net.IP { return []net.IP{net.ParseIP("192.168.0.9")} }
	if !onLocalNetwork("https://dokkit.example.com") {
		t.Error("a name that resolves to a private address is on the local network")
	}
	now := time.Now()
	if !runningButCannotSend(status{At: now.Add(-time.Minute), Sent: now.Add(-time.Hour)}, 3, now) {
		t.Error("a watch that runs, sent nothing for an hour and has reports waiting is stuck")
	}
	for name, c := range map[string]struct {
		s status
		n int
	}{
		"not running":  {status{At: now.Add(-time.Hour), Sent: now.Add(-time.Hour)}, 3},
		"sent lately":  {status{At: now, Sent: now.Add(-time.Minute)}, 3},
		"nothing held": {status{At: now, Sent: now.Add(-time.Hour)}, 0},
	} {
		if runningButCannotSend(c.s, c.n, now) {
			t.Errorf("%s is not a blocked watch", name)
		}
	}
}
