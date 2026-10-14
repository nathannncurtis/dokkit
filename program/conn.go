package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync"
	"time"
)

type linkLimits struct {
	header, work, write, ping, pingWait time.Duration
}

var defaultLinkLimits = linkLimits{header: 45 * time.Second, work: 65 * time.Second, write: 30 * time.Second, ping: 20 * time.Second, pingWait: 15 * time.Second}

const workPath = "/api/v1/work"

// The work long-poll has its own transport so a stuck connection under one never holds up the other.
type link struct {
	mu    sync.Mutex
	tls   *tls.Config
	lim   linkLimits
	lanes [2]*lane
}

type lane struct {
	t     *http.Transport
	fails int
}

func newLink(cfg *tls.Config, lim linkLimits) *link {
	l := &link{tls: cfg, lim: lim}
	l.lanes = [2]*lane{{t: l.transport(false)}, {t: l.transport(true)}}
	return l
}

func (l *link) transport(long bool) *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	if l.tls != nil {
		t.TLSClientConfig = l.tls.Clone()
	}
	d := &net.Dialer{Timeout: 10 * time.Second, KeepAliveConfig: net.KeepAliveConfig{Enable: true, Idle: 15 * time.Second, Interval: 10 * time.Second, Count: 3}}
	t.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := d.DialContext(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		return progressConn{c, l.lim.write}, nil
	}
	t.ResponseHeaderTimeout = l.lim.header
	if long {
		t.ResponseHeaderTimeout = l.lim.work
	}
	t.HTTP2 = &http.HTTP2Config{SendPingTimeout: l.lim.ping, PingTimeout: l.lim.pingWait, WriteByteTimeout: l.lim.write}
	return t
}

// progressConn fails a write that makes no progress, so a peer that stops reading cannot hold a request forever.
type progressConn struct {
	net.Conn
	d time.Duration
}

func (c progressConn) Write(b []byte) (int, error) {
	c.Conn.SetWriteDeadline(time.Now().Add(c.d))
	return c.Conn.Write(b)
}

func (l *link) RoundTrip(req *http.Request) (*http.Response, error) {
	i := 0
	if req.URL.Path == workPath {
		i = 1
	}
	l.mu.Lock()
	t := l.lanes[i].t
	l.mu.Unlock()
	// A client timeout returns to the caller before the transport does, so the cancel is watched itself.
	stop := context.AfterFunc(req.Context(), func() { l.timedOut(i, t, req.Context().Err()) })
	res, err := t.RoundTrip(req)
	if stop() {
		var op *net.OpError
		switch {
		case err == nil:
			l.mu.Lock()
			if l.lanes[i].t == t {
				l.lanes[i].fails = 0
			}
			l.mu.Unlock()
		case errors.Is(err, errPinMismatch), errors.As(err, &op) && op.Op == "dial":
		default:
			l.timedOut(i, t, err)
		}
	}
	return res, err
}

func (l *link) timedOut(i int, t *http.Transport, why error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	ln := l.lanes[i]
	if ln.t != t {
		return
	}
	t.CloseIdleConnections()
	if ln.fails++; ln.fails < 2 {
		fmt.Fprintln(os.Stderr, "dokkit: a request to the server got no answer, closed its idle connections:", why)
		return
	}
	l.lanes[i] = &lane{t: l.transport(i == 1)}
	fmt.Fprintln(os.Stderr, "dokkit: two requests to the server got no answer in a row, dropped its connections and started a new set:", why)
}
