package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

var errPinMismatch = errors.New("the server's certificate is not the one this machine enrolled with")

const clockAdvice = "Turn on setting the time automatically (macOS: System Settings > General > Date & Time; Windows: Settings > Time & language; Linux: timedatectl set-ntp true), then run dokkit doctor again."

// explainReach says what a failed request to the server means and the one thing to do about it.
func explainReach(err error, address string) (what, todo string) {
	host, port := address, ""
	if u, perr := url.Parse(address); perr == nil {
		host, port = u.Hostname(), u.Port()
	}
	var dns *net.DNSError
	var hostErr x509.HostnameError
	var unknown x509.UnknownAuthorityError
	var invalid x509.CertificateInvalidError
	var verify *tls.CertificateVerificationError
	var record tls.RecordHeaderError
	text := err.Error()
	switch {
	case errors.Is(err, errPinMismatch):
		return "The server's certificate is not the one this machine enrolled with (its fingerprint does not match the one saved).",
			"If the certificate was renewed or replaced on purpose, enrol again with the new fingerprint: dokkit enrol <address> <token> sha256:<fingerprint>. If it was not, something other than the server is answering at " + address + "; do not enrol until you know what."
	case errors.As(err, &dns):
		return "The name " + host + " does not resolve to an address.",
			"Check the address for a typo, and that this machine's DNS (or its VPN) can look the name up. Using the server's IP address in the saved address avoids DNS."
	case errors.As(err, &invalid) && invalid.Reason == x509.Expired:
		return "The server's certificate has expired, or this machine's clock is ahead of the certificate's dates.",
			"Check the clock first (" + clockAdvice + "). If the clock is right, renew the server's certificate."
	case errors.As(err, &hostErr):
		return "The server's certificate is for another name than " + host + ".",
			"Use the name the certificate is for as the address, or enrol with the certificate's fingerprint so it is trusted by that and not by name."
	case errors.As(err, &unknown) || (errors.As(err, &verify) && !errors.As(err, &invalid)):
		return "The server's certificate is not signed by an authority this machine trusts.",
			"Enrol with the certificate's fingerprint: dokkit enrol <address> <token> sha256:<fingerprint>. That trusts that certificate and no other."
	case errors.As(err, &record) || strings.Contains(text, "server gave HTTP response to HTTPS client"):
		return "Something answered at " + address + " but not with TLS: the address says https and the server speaks plain http.",
			"Change the saved address to http:// if that is intended, or turn TLS on at the server."
	case strings.Contains(text, "tls:") || strings.Contains(text, "x509:"):
		return "The TLS handshake with the server failed: " + short(err) + ".",
			"Check the server's certificate and that nothing between this machine and the server (a proxy, a security tool) is changing it."
	case errors.Is(err, syscall.ECONNREFUSED) || strings.Contains(text, "refused"):
		return "The machine at " + host + " is there, but nothing is listening on port " + portOf(address, port) + ".",
			"Start the Dokkit server, or correct the port in the saved address."
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return "The server did not answer in time.",
			"Check that " + host + " is switched on and reachable from this machine, and that no firewall or VPN is dropping the traffic to port " + portOf(address, port) + "."
	case errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ENETUNREACH) || strings.Contains(text, "no route to host") || strings.Contains(text, "network is unreachable"):
		if runtime.GOOS == "darwin" && onLocalNetwork(address) {
			return "This machine has no route to " + host + ". If the same address answers from Terminal, this is macOS's local network privacy refusing a background program, not the network.",
				localNetworkAdvice
		}
		return "This machine has no route to " + host + ".",
			"Check this machine's network connection, and that " + host + " is on a network it can reach."
	}
	return "Cannot reach the server: " + text, "Check the address and the network."
}

func isTimeout(err error) bool {
	var n net.Error
	return errors.As(err, &n) && n.Timeout()
}

func portOf(address, port string) string {
	if port != "" {
		return port
	}
	if strings.HasPrefix(address, "https") {
		return "443"
	}
	return "80"
}

// explainStatus says what an answer other than 200 from the ping address means.
func explainStatus(code int) (what, todo string) {
	switch {
	case code == http.StatusUnauthorized:
		return "The server is there, but it does not know this key.",
			"Enrol this machine again with a new token (dokkit enrol <address> <token>), or ask for the key to be turned back on if it was revoked."
	case code == http.StatusNotFound || code == http.StatusMethodNotAllowed:
		return fmt.Sprintf("Something answered %d at the ping address, so it is not a Dokkit server, or an older one.", code),
			"Check that the saved address is the Dokkit server's and not another site or a proxy's."
	case code >= 500:
		return fmt.Sprintf("The server is there but failing: it answered %d.", code),
			"Look at the server's log; the problem is on its side."
	}
	return fmt.Sprintf("The server answered %d, which is not what a Dokkit server answers.", code),
		"Check that the saved address is the Dokkit server's and not a proxy's or a login page."
}

// lookupHost is net.LookupIP, replaced by tests.
var lookupHost = func(host string) []net.IP {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	addrs, _ := net.DefaultResolver.LookupIPAddr(ctx, host)
	var ips []net.IP
	for _, a := range addrs {
		ips = append(ips, a.IP)
	}
	return ips
}

// onLocalNetwork is true when the address names a machine on a private or link-local network,
// the only addresses macOS's local network privacy guards.
func onLocalNetwork(address string) bool {
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" {
		return false
	}
	host := u.Hostname()
	ips := []net.IP{net.ParseIP(host)}
	if ips[0] == nil {
		if strings.HasSuffix(host, ".local") || !strings.Contains(host, ".") {
			return true
		}
		ips = lookupHost(host)
	}
	for _, ip := range ips {
		if ip != nil && (ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
			return true
		}
	}
	return false
}

// runningButCannotSend is true when a watch wrote its status in the last three minutes yet has
// sent nothing for ten, with reports piling up: it runs and its sends fail.
func runningButCannotSend(s status, waiting int, now time.Time) bool {
	return now.Sub(s.At) < 3*time.Minute && now.Sub(s.Sent) > 10*time.Minute && waiting > 0
}

const localNetworkAdvice = "macOS blocks a program that runs in the background from reaching other machines on the local network until it is allowed, and answers its connections with \"no route to host\" while the same address works from Terminal. Install the signed release (a program built without the signature cannot be allowed), then turn on dokkit in System Settings > Privacy & Security > Local Network. Or run dokkit service install, which runs it as a system service that is not held to that permission."

// macBlockedHint is a note when this Mac's watch is running but cannot send while this
// terminal can reach the server, or "". It is a guess from what the watch last wrote down.
func (c *client) macBlockedHint() string {
	if runtime.GOOS != "darwin" || !onLocalNetwork(c.url) {
		return ""
	}
	var s status
	if b, err := os.ReadFile(filepath.Join(c.spool, "status.json")); err != nil || json.Unmarshal(b, &s) != nil {
		return ""
	}
	waiting, _ := filepath.Glob(filepath.Join(c.spool, "*.ndjson"))
	if !runningButCannotSend(s, len(waiting), time.Now()) {
		return ""
	}
	return "The background copy of dokkit (process " + fmt.Sprint(s.Pid) + ") is running but has sent nothing since " + s.Sent.Local().Format("Jan 2 15:04") + ", and " + fmt.Sprint(len(waiting)) + " report(s) are waiting, yet this terminal reaches the server. " + localNetworkAdvice
}
