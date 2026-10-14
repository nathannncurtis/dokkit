package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	relayMaxBody     = 2 << 20
	relayUploadsMin  = 4
	relayFetchesMin  = 30
	base62           = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	relayNotFoundMsg = "No such mailbox, slot or token."
)

type relayMailbox struct {
	Name       string               `json:"name"`
	KeySha256  string               `json:"key_sha256"`
	Created    time.Time            `json:"created"`
	LastUpload *time.Time           `json:"last_upload,omitempty"`
	LastFetch  map[string]time.Time `json:"last_fetch,omitempty"`
}

type relayEnvelope struct {
	Schema  int                  `json:"schema"`
	Counter *int64               `json:"counter"`
	MadeAt  string               `json:"made_at"`
	Slots   map[string]relaySlot `json:"slots"`
	Nonce   string               `json:"nonce"`
	Body    string               `json:"body"`
}

type relaySlot struct {
	TokenSha256 string `json:"token_sha256"`
	Nonce       string `json:"nonce"`
	Key         string `json:"key"`
}

type relayServer struct {
	dir    string
	mu     sync.Mutex
	hits   map[string][]time.Time
	now    func() time.Time
	logOut io.Writer
}

func relayDir() (string, error) {
	if d := os.Getenv("DOKKIT_RELAY_DIR"); d != "" {
		return d, nil
	}
	dir, err := os.UserConfigDir()
	return filepath.Join(dir, "dokkit", "relay"), err
}

func newRelayServer(dir string) *relayServer {
	return &relayServer{dir: dir, hits: map[string][]time.Time{}, now: time.Now, logOut: os.Stdout}
}

func randomKey(prefix string) string {
	b := make([]byte, 30)
	rand.Read(b)
	for i := range b {
		b[i] = base62[int(b[i])%62]
	}
	return prefix + string(b) + keyChecksum(string(b))
}

func keyChecksum(body string) string {
	n := uint64(crc32.ChecksumIEEE([]byte(body)))
	out := ""
	for ; n > 0; n /= 62 {
		out = string(base62[n%62]) + out
	}
	return strings.Repeat("0", 6-len(out)) + out
}

func validKey(key, prefix string) bool {
	if len(key) != len(prefix)+36 || !strings.HasPrefix(key, prefix) {
		return false
	}
	body := key[len(prefix) : len(prefix)+30]
	for _, c := range body {
		if !strings.ContainsRune(base62, c) {
			return false
		}
	}
	return key[len(prefix)+30:] == keyChecksum(body)
}

func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func validID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for _, c := range s {
		if !strings.ContainsRune("0123456789abcdef", c) {
			return false
		}
	}
	return true
}

func writeFileAtomic(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(f.Name(), path)
	}
	if err != nil {
		os.Remove(f.Name())
	}
	return err
}

func (s *relayServer) readMailbox(id string) (*relayMailbox, error) {
	b, err := os.ReadFile(filepath.Join(s.dir, id, "mailbox.json"))
	if err != nil {
		return nil, err
	}
	var m relayMailbox
	return &m, json.Unmarshal(b, &m)
}

func (s *relayServer) writeMailbox(id string, m *relayMailbox) error {
	b, _ := json.MarshalIndent(m, "", "  ")
	return writeFileAtomic(filepath.Join(s.dir, id, "mailbox.json"), b)
}

func (s *relayServer) mailboxes() (map[string]*relayMailbox, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	out := map[string]*relayMailbox{}
	for _, e := range entries {
		if !e.IsDir() || !validID(e.Name()) {
			continue
		}
		m, err := s.readMailbox(e.Name())
		if err != nil {
			return nil, fmt.Errorf("mailbox %s: %w", e.Name(), err)
		}
		out[e.Name()] = m
	}
	return out, nil
}

func (s *relayServer) addMailbox(name, key string) (string, error) {
	all, err := s.mailboxes()
	if err != nil {
		return "", err
	}
	for _, m := range all {
		if m.Name == name {
			return "", fmt.Errorf("there is already a mailbox named %q", name)
		}
	}
	b := make([]byte, 16)
	rand.Read(b)
	id := hex.EncodeToString(b)
	if err := os.MkdirAll(filepath.Join(s.dir, id), 0o700); err != nil {
		return "", err
	}
	return id, s.writeMailbox(id, &relayMailbox{Name: name, KeySha256: sha256Hex(key), Created: s.now().UTC()})
}

// limited counts one hit for key and returns the seconds to wait when it is over n a minute.
func (s *relayServer) limited(key string, n int) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	kept := s.hits[key][:0]
	for _, t := range s.hits[key] {
		if now.Sub(t) < time.Minute {
			kept = append(kept, t)
		}
	}
	if len(kept) >= n {
		s.hits[key] = kept
		return int((time.Minute - now.Sub(kept[0])).Seconds()) + 1
	}
	s.hits[key] = append(kept, now)
	return 0
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int) {
	w.status = c
	w.ResponseWriter.WriteHeader(c)
}

func (s *relayServer) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sw := &statusWriter{ResponseWriter: w, status: 200}
		parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
		mailbox, slot := "-", "-"
		if len(parts) >= 2 && parts[0] == "m" && validID(parts[1]) {
			mailbox = parts[1]
			if len(parts) == 3 && validID(parts[2]) {
				slot = parts[2]
			}
		}
		s.route(sw, r, parts)
		fmt.Fprintf(s.logOut, "%s %s mailbox=%s slot=%s %d\n", s.now().UTC().Format(time.RFC3339), r.Method, mailbox, slot, sw.status)
	})
}

func relayError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func relayNotFound(w http.ResponseWriter) {
	relayError(w, 404, "not_found", relayNotFoundMsg)
}

func relayJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

func (s *relayServer) route(w http.ResponseWriter, r *http.Request, parts []string) {
	switch {
	case len(parts) == 2 && parts[0] == "m" && r.Method == http.MethodPut && validID(parts[1]):
		s.upload(w, r, parts[1])
	case len(parts) == 3 && parts[0] == "m" && r.Method == http.MethodGet && validID(parts[1]):
		s.fetch(w, r, parts[1], parts[2])
	default:
		relayNotFound(w)
	}
}

func (s *relayServer) upload(w http.ResponseWriter, r *http.Request, id string) {
	m, err := s.readMailbox(id)
	if err != nil {
		relayNotFound(w)
		return
	}
	if subtle.ConstantTimeCompare([]byte(sha256Hex(bearer(r))), []byte(m.KeySha256)) != 1 {
		relayError(w, 401, "bad_key", "The upload key is missing or wrong.")
		return
	}
	if wait := s.limited("up:"+id, relayUploadsMin); wait > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(wait))
		relayError(w, 429, "rate_limited", "At most 4 uploads a minute.")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, relayMaxBody))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			relayError(w, 413, "too_large", "An envelope is at most 2 MB.")
		} else {
			relayError(w, 400, "bad_request", "The body could not be read.")
		}
		return
	}
	var env relayEnvelope
	if json.Unmarshal(body, &env) != nil || env.Schema != 1 || env.Counter == nil || env.Slots == nil || env.Nonce == "" || env.Body == "" {
		relayError(w, 422, "bad_envelope", "The body is not a snapshot envelope with schema 1.")
		return
	}
	for _, sl := range env.Slots {
		if sl.TokenSha256 == "" || sl.Nonce == "" || sl.Key == "" {
			relayError(w, 422, "bad_envelope", "Every slot needs token_sha256, nonce and key.")
			return
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if held, err := s.readEnvelope(id); err == nil && held.Counter != nil && *env.Counter <= *held.Counter {
		relayError(w, 409, "stale_counter", "The counter is not higher than the one held.")
		return
	}
	if m, err = s.readMailbox(id); err != nil {
		relayNotFound(w)
		return
	}
	now := s.now().UTC()
	fetched := map[string]time.Time{}
	answer := map[string]any{}
	for slot := range env.Slots {
		answer[slot] = nil
		if t, ok := m.LastFetch[slot]; ok {
			fetched[slot] = t
			answer[slot] = t.UTC().Format(time.RFC3339)
		}
	}
	m.LastFetch, m.LastUpload = fetched, &now
	if err := writeFileAtomic(filepath.Join(s.dir, id, "envelope.json"), body); err != nil {
		relayError(w, 500, "store_failed", "The envelope could not be stored.")
		return
	}
	if err := s.writeMailbox(id, m); err != nil {
		relayError(w, 500, "store_failed", "The mailbox could not be updated.")
		return
	}
	relayJSON(w, map[string]any{"ok": true, "slots": answer})
}

func (s *relayServer) readEnvelope(id string) (*relayEnvelope, error) {
	b, err := os.ReadFile(filepath.Join(s.dir, id, "envelope.json"))
	if err != nil {
		return nil, err
	}
	var env relayEnvelope
	return &env, json.Unmarshal(b, &env)
}

func (s *relayServer) fetch(w http.ResponseWriter, r *http.Request, id, slot string) {
	s.mu.Lock()
	_, merr := s.readMailbox(id)
	env, eerr := s.readEnvelope(id)
	s.mu.Unlock()
	want := strings.Repeat("0", 64)
	var sl relaySlot
	found := merr == nil && eerr == nil && env.Counter != nil
	if found {
		sl, found = env.Slots[slot]
		if found {
			want = sl.TokenSha256
		}
	}
	if subtle.ConstantTimeCompare([]byte(sha256Hex(bearer(r))), []byte(want)) != 1 || !found {
		relayNotFound(w)
		return
	}
	if wait := s.limited("get:"+id+":"+slot, relayFetchesMin); wait > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(wait))
		relayError(w, 429, "rate_limited", "At most 30 fetches a minute.")
		return
	}
	s.mu.Lock()
	if m, err := s.readMailbox(id); err == nil {
		if m.LastFetch == nil {
			m.LastFetch = map[string]time.Time{}
		}
		m.LastFetch[slot] = s.now().UTC()
		s.writeMailbox(id, m)
	}
	s.mu.Unlock()
	etag := `"` + strconv.FormatInt(*env.Counter, 10) + `"`
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	relayJSON(w, map[string]any{"schema": 1, "counter": *env.Counter, "made_at": env.MadeAt, "slot_nonce": sl.Nonce, "key": sl.Key, "nonce": env.Nonce, "body": env.Body})
}

func relayCommand(args []string) int {
	bad := func() int {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	if len(args) == 0 {
		return bad()
	}
	dir, err := relayDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	s := newRelayServer(dir)
	fail := func(err error) int {
		fmt.Fprintln(os.Stderr, "dokkit:", err)
		return 1
	}
	switch args[0] {
	case "add":
		if len(args) != 2 {
			return bad()
		}
		key := randomKey("dkr_")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fail(err)
		}
		id, err := s.addMailbox(args[1], key)
		if err != nil {
			return fail(err)
		}
		fmt.Printf("Made the mailbox %s.\nAddress: /m/%s\nUpload key (shown once): %s\n", args[1], id, key)
	case "list":
		if len(args) != 1 {
			return bad()
		}
		all, err := s.mailboxes()
		if err != nil {
			return fail(err)
		}
		if len(all) == 0 {
			fmt.Println("No mailboxes. dokkit relay add <name> makes one.")
		}
		ids := make([]string, 0, len(all))
		for id := range all {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return all[ids[i]].Name < all[ids[j]].Name })
		for _, id := range ids {
			m := all[id]
			up := "never"
			if m.LastUpload != nil {
				up = m.LastUpload.UTC().Format(time.RFC3339)
			}
			fmt.Printf("%s  %s  last upload %s\n", m.Name, id, up)
			slots := []string{}
			if env, err := s.readEnvelope(id); err == nil {
				for slot := range env.Slots {
					slots = append(slots, slot)
				}
			}
			sort.Strings(slots)
			for _, slot := range slots {
				f := "never"
				if t, ok := m.LastFetch[slot]; ok {
					f = t.UTC().Format(time.RFC3339)
				}
				fmt.Printf("  slot %s  last fetch %s\n", slot, f)
			}
		}
	case "remove":
		if len(args) != 2 {
			return bad()
		}
		all, err := s.mailboxes()
		if err != nil {
			return fail(err)
		}
		for id, m := range all {
			if m.Name == args[1] {
				if err := os.RemoveAll(filepath.Join(s.dir, id)); err != nil {
					return fail(err)
				}
				fmt.Printf("Removed the mailbox %s.\n", args[1])
				return 0
			}
		}
		return fail(fmt.Errorf("there is no mailbox named %q", args[1]))
	case "serve":
		if len(args) != 3 || args[1] != "--http" {
			return bad()
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fail(err)
		}
		srv := &http.Server{Addr: args[2], Handler: s.handler(), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
			WriteTimeout: 30 * time.Second, IdleTimeout: 2 * time.Minute, MaxHeaderBytes: 16 << 10}
		fmt.Fprintln(os.Stderr, "dokkit: relay listening on", args[2])
		return fail(srv.ListenAndServe())
	default:
		return bad()
	}
	return 0
}
