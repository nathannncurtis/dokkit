package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	perAccount = 3
	codeLife   = 7 * 24 * time.Hour
	lapseAfter = 90 * 24 * time.Hour
	freeAfter  = 30 * 24 * time.Hour
	quietAfter = 7 * 24 * time.Hour
	maxTXT     = 2
)

var (
	labelRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$`)
	txtRe   = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

	reserved = strings.Fields(`www mcp relay names demo status api mail
		admin root app apps dashboard docs doc blog dev staging test cdn static assets
		ftp smtp imap pop pop3 ns ns1 ns2 ns3 dns mx vpn git login auth account accounts
		billing support help security abuse postmaster hostmaster webmaster noreply
		dokkit autodiscover autoconfig localhost update updates download downloads install
		get wpad isatap portal sso oauth id www1 www2 web site shop store news`)
)

type Service struct {
	Store    *Store
	DNS      *Azure
	Zone     string
	Max      int
	Reserved map[string]bool
	Blocked  map[string]bool
	Now      func() time.Time
}

type Problem struct {
	Status int
	Text   string
}

func (p *Problem) Error() string { return p.Text }

func refuse(status int, format string, a ...any) error {
	return &Problem{status, fmt.Sprintf(format, a...)}
}

func (s *Service) fqdn(label string) string { return label + "." + s.Zone }

func hashCode(code string) string {
	h := sha256.Sum256([]byte(code))
	return hex.EncodeToString(h[:])
}

func newCode() string {
	b := make([]byte, 15)
	rand.Read(b)
	return strings.ToLower(base32.StdEncoding.EncodeToString(b))
}

// CheckLabel gives the first rule a label breaks, in the words the page shows as you type.
func (s *Service) CheckLabel(label string) error {
	switch {
	case strings.Trim(label, "abcdefghijklmnopqrstuvwxyz0123456789-") != "":
		return refuse(400, "Only lower-case letters, digits and hyphens.")
	case strings.HasPrefix(label, "-"):
		return refuse(400, "It can't start with a hyphen.")
	case len(label) < 3:
		return refuse(400, "At least 3 characters.")
	case len(label) > 40:
		return refuse(400, "At most 40 characters.")
	case strings.HasSuffix(label, "-"):
		return refuse(400, "It can't end with a hyphen.")
	case len(label) >= 4 && label[2:4] == "--":
		return refuse(400, "It can't have two hyphens in the third and fourth places.")
	case !labelRe.MatchString(label):
		return refuse(400, "Only lower-case letters, digits and hyphens, starting and ending with a letter or digit.")
	case offensive(label, s.Blocked):
		return refuse(400, "That name isn't allowed.")
	case s.Reserved[label]:
		return refuse(409, "%s is kept back for Dokkit itself.", s.fqdn(label))
	}
	return nil
}

// Available says why owner cannot claim label now, or nil.
func (s *Service) Available(owner, label string) error {
	if err := s.CheckLabel(label); err != nil {
		return err
	}
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	return s.available(owner, label)
}

func (s *Service) available(owner, label string) error {
	if n := s.Store.s.Names[label]; n != nil {
		if n.Owner == owner {
			return refuse(409, "%s is already yours.", s.fqdn(label))
		}
		return refuse(409, "%s is taken.", s.fqdn(label))
	}
	if len(s.mine(owner)) >= perAccount {
		return refuse(409, "You hold %d names already. Release one to claim another.", perAccount)
	}
	if len(s.Store.s.Names) >= s.Max {
		return refuse(503, "No more names can be handed out for now.")
	}
	for _, fq := range []string{s.fqdn(label), "_acme-challenge." + s.fqdn(label)} {
		taken, err := s.DNS.Exists(fq)
		if err != nil {
			return refuse(502, "The DNS provider could not be asked: %v", err)
		}
		if taken {
			return refuse(409, "%s is taken.", s.fqdn(label))
		}
	}
	return nil
}

func (s *Service) mine(owner string) []*Name {
	var out []*Name
	for _, n := range s.Store.s.Names {
		if n.Owner == owner {
			out = append(out, n)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Label < out[j].Label })
	return out
}

func (s *Service) Mine(owner string) []Name {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	var out []Name
	for _, n := range s.mine(owner) {
		out = append(out, *n)
	}
	return out
}

// Claim holds the label for the account and returns a one-time claim code.
func (s *Service) Claim(owner string, login, label string) (string, error) {
	label = strings.ToLower(strings.TrimSpace(label))
	if err := s.CheckLabel(label); err != nil {
		return "", err
	}
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	if err := s.available(owner, label); err != nil {
		return "", err
	}
	code := newCode()
	now := s.Now()
	s.Store.s.Names[label] = &Name{Label: label, Owner: owner, Login: login, Created: now,
		CodeHash: hashCode(code), CodeUntil: now.Add(codeLife)}
	return code, s.Store.save()
}

// NewCode replaces the claim code; registering with it later replaces the name's key.
func (s *Service) NewCode(owner string, label string) (string, error) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	n := s.Store.s.Names[label]
	if n == nil || n.Owner != owner {
		return "", refuse(404, "No such name on this account.")
	}
	code := newCode()
	n.CodeHash, n.CodeUntil = hashCode(code), s.Now().Add(codeLife)
	return code, s.Store.save()
}

// Release removes the name's records and frees it.
func (s *Service) Release(owner string, label string) error {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	n := s.Store.s.Names[label]
	if n == nil || n.Owner != owner {
		return refuse(404, "No such name on this account.")
	}
	if err := s.clear(n); err != nil {
		return refuse(502, "The records could not be removed: %v", err)
	}
	delete(s.Store.s.Names, label)
	return s.Store.save()
}

func (s *Service) clear(n *Name) error {
	var errs []error
	for _, id := range []*string{&n.AID, &n.AAAAID} {
		if *id != "" {
			if err := s.DNS.Delete(*id); err != nil {
				errs = append(errs, err)
			} else {
				*id = ""
			}
		}
	}
	n.A, n.AAAA = "", ""
	errs = append(errs, s.clearTXT(n))
	return errors.Join(errs...)
}

func (s *Service) clearTXT(n *Name) error {
	var keep []TXT
	var errs []error
	for _, t := range n.TXT {
		if err := s.DNS.Delete(t.ID); err != nil {
			keep, errs = append(keep, t), append(errs, err)
		}
	}
	n.TXT = keep
	return errors.Join(errs...)
}

// Register binds the server's public key to the name whose code it holds.
func (s *Service) Register(code string, key JWK) (string, error) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	h := hashCode(strings.TrimSpace(code))
	now := s.Now()
	for _, n := range s.Store.s.Names {
		if n.CodeHash == h && now.Before(n.CodeUntil) {
			n.Key, n.CodeHash, n.CodeUntil, n.Seen, n.Lapsed = &key, "", time.Time{}, now, time.Time{}
			return s.fqdn(n.Label), s.Store.save()
		}
	}
	return "", refuse(403, "That claim code is not known or has run out.")
}

// KeyFor is the public key a signed call for the label must verify against.
func (s *Service) KeyFor(label string) *JWK {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	if n := s.Store.s.Names[label]; n != nil && n.Key != nil {
		k := *n.Key
		return &k
	}
	return nil
}

func checkAddr(text string, v4 bool) error {
	if text == "" {
		return nil
	}
	a, err := netip.ParseAddr(text)
	if err != nil || a.Is4() != v4 || a.Is4In6() || a.Zone() != "" || !a.IsGlobalUnicast() {
		kind := "IPv6"
		if v4 {
			kind = "IPv4"
		}
		return refuse(400, "%q is not a usable %s address.", text, kind)
	}
	return nil
}

// Address sets the name's A and AAAA records; an empty one removes that record.
func (s *Service) Address(label, a, aaaa string) (*Name, error) {
	if err := errors.Join(checkAddr(a, true), checkAddr(aaaa, false)); err != nil {
		return nil, err
	}
	return s.touch(label, func(n *Name) error {
		set := func(id *string, cur *string, typ, want string) error {
			if want == *cur && (want == "") == (*id == "") {
				return nil
			}
			if want == "" {
				if err := s.DNS.Delete(*id); err != nil {
					return err
				}
				*id, *cur = "", ""
				return nil
			}
			newID, err := s.DNS.Put(*id, typ, s.fqdn(n.Label), want)
			if err != nil {
				return err
			}
			*id, *cur = newID, want
			return nil
		}
		return errors.Join(set(&n.AID, &n.A, "A", a), set(&n.AAAAID, &n.AAAA, "AAAA", aaaa))
	})
}

// AddTXT puts a DNS-01 challenge value at _acme-challenge.<name>, dropping the oldest past two.
func (s *Service) AddTXT(label, value string) (*Name, error) {
	if !txtRe.MatchString(value) {
		return nil, refuse(400, "A challenge value is 43 base64url characters.")
	}
	return s.touch(label, func(n *Name) error {
		for len(n.TXT) >= maxTXT {
			if err := s.DNS.Delete(n.TXT[0].ID); err != nil {
				return err
			}
			n.TXT = n.TXT[1:]
		}
		id, err := s.DNS.Put("", "TXT", "_acme-challenge."+s.fqdn(n.Label), value)
		if err != nil {
			return err
		}
		n.TXT = append(n.TXT, TXT{ID: id, Value: value, At: s.Now()})
		return nil
	})
}

func (s *Service) ClearTXT(label string) (*Name, error) {
	return s.touch(label, s.clearTXT)
}

// touch runs a signed call's change. Any accepted call is a renewal: it keeps the name alive.
func (s *Service) touch(label string, change func(*Name) error) (*Name, error) {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	n := s.Store.s.Names[label]
	if n == nil || n.Key == nil {
		return nil, refuse(404, "No such name.")
	}
	n.Seen, n.Lapsed = s.Now(), time.Time{}
	err := change(n)
	if serr := s.Store.save(); serr != nil {
		return nil, serr
	}
	if err != nil {
		return nil, refuse(502, "The DNS provider refused: %v", err)
	}
	out := *n
	return &out, nil
}

// Sweep lapses names whose server stopped calling, and frees lapsed and never-registered ones.
func (s *Service) Sweep() {
	s.Store.mu.Lock()
	defer s.Store.mu.Unlock()
	now := s.Now()
	changed := false
	for label, n := range s.Store.s.Names {
		switch {
		case n.Key == nil && now.After(n.CodeUntil):
			delete(s.Store.s.Names, label)
			changed = true
		case n.Key != nil && n.Lapsed.IsZero() && now.Sub(n.Seen) > lapseAfter:
			if s.clear(n) == nil {
				n.Lapsed = now
			}
			changed = true
		case !n.Lapsed.IsZero() && now.Sub(n.Lapsed) > freeAfter && s.clear(n) == nil:
			delete(s.Store.s.Names, label)
			changed = true
		}
	}
	if changed {
		s.Store.save()
	}
}

// State is what the page says about a name.
func (s *Service) State(n Name) (string, string) {
	day := func(t time.Time) string { return t.UTC().Format("2006-01-02") }
	switch {
	case n.Key == nil:
		return "waiting for the server", "the claim code runs out " + day(n.CodeUntil)
	case !n.Lapsed.IsZero():
		return "lapsed", "records removed; the name is freed " + day(n.Lapsed.Add(freeAfter))
	case s.Now().Sub(n.Seen) > quietAfter:
		return "lapsing", "no call since " + day(n.Seen) + "; records removed " + day(n.Seen.Add(lapseAfter))
	}
	return "live", "renewed " + day(n.Seen)
}
