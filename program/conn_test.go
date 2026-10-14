package main

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// parkFirst finishes the TLS handshake on the first connection and then never reads from it again.
type parkFirst struct {
	net.Listener
	srv    *httptest.Server
	first  atomic.Bool
	mu     sync.Mutex
	parked []net.Conn
}

func (p *parkFirst) Accept() (net.Conn, error) {
	for {
		c, err := p.Listener.Accept()
		if err != nil || p.first.Swap(true) {
			return c, err
		}
		tls.Server(c, p.srv.TLS.Clone()).Handshake()
		p.mu.Lock()
		p.parked = append(p.parked, c)
		p.mu.Unlock()
	}
}

func stuckServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	}))
	srv.EnableHTTP2 = true
	p := &parkFirst{Listener: srv.Listener, srv: srv}
	srv.Listener = p
	srv.StartTLS()
	t.Cleanup(func() {
		p.mu.Lock()
		for _, c := range p.parked {
			c.Close()
		}
		p.mu.Unlock()
		srv.Close()
	})
	sum := sha256.Sum256(srv.Certificate().Raw)
	return srv, hex.EncodeToString(sum[:])
}

func testLimits() linkLimits {
	return linkLimits{header: time.Second, work: 2 * time.Second, write: time.Second, ping: time.Second, pingWait: time.Second}
}

func get(c *http.Client, url string) error {
	res, err := c.Get(url)
	if err == nil {
		res.Body.Close()
	}
	return err
}

func TestPlainTransportKeepsUsingTheStuckConnection(t *testing.T) {
	srv, _ := stuckServer(t)
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	c := &http.Client{Transport: tr, Timeout: 500 * time.Millisecond}
	for i := 0; i < 3; i++ {
		if err := get(c, srv.URL+"/api/v1/report"); err == nil {
			t.Fatalf("attempt %d succeeded; the stuck connection was not reused", i+1)
		}
	}
}

func TestLinkRecoversFromAStuckConnection(t *testing.T) {
	srv, pin := stuckServer(t)
	c := &http.Client{Transport: newLink(pinConfig(pin), testLimits()), Timeout: 500 * time.Millisecond}
	start := time.Now()
	attempts := 0
	var err error
	for attempts < 3 {
		attempts++
		time.Sleep(50 * time.Millisecond)
		if err = get(c, srv.URL+"/api/v1/report"); err == nil {
			break
		}
	}
	if err != nil {
		t.Fatalf("still failing after %d attempts: %v", attempts, err)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("took %s to recover", took)
	}
}

func TestPinStillRefusesAnotherCertificate(t *testing.T) {
	srv, _ := stuckServer(t)
	c := &http.Client{Transport: newLink(pinConfig("sha256:"+hex.EncodeToString(make([]byte, 32))), testLimits()), Timeout: 2 * time.Second}
	if err := get(c, srv.URL+"/api/v1/report"); err == nil {
		t.Fatal("a certificate with another fingerprint was accepted")
	}
}

func TestWorkPollAndReportsDoNotBlockEachOther(t *testing.T) {
	srv, pin := stuckServer(t)
	l := newLink(pinConfig(pin), testLimits())
	work := make(chan error, 1)
	go func() { work <- get(&http.Client{Transport: l, Timeout: 3 * time.Second}, srv.URL+workPath+"?wait=50") }()
	time.Sleep(300 * time.Millisecond)
	if err := get(&http.Client{Transport: l, Timeout: time.Second}, srv.URL+"/api/v1/report"); err != nil {
		t.Fatalf("report blocked behind the stuck work poll: %v", err)
	}
	select {
	case err := <-work:
		if err == nil {
			t.Fatal("the work poll on the stuck connection should have timed out")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the work poll never returned")
	}
}
