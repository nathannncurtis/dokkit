package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"sync"
	"time"
)

type JWK struct {
	Kty string `json:"kty"`
	Crv string `json:"crv"`
	X   string `json:"x"`
	Y   string `json:"y"`
}

type TXT struct {
	ID    string    `json:"id"`
	Value string    `json:"value"`
	At    time.Time `json:"at"`
}

type Name struct {
	Label     string    `json:"label"`
	Owner     string    `json:"account"`
	GitHubID  int64     `json:"owner,omitempty"` // before accounts named their provider
	Login     string    `json:"login"`
	Created   time.Time `json:"created"`
	CodeHash  string    `json:"code_hash,omitempty"`
	CodeUntil time.Time `json:"code_until,omitempty"`
	Key       *JWK      `json:"key,omitempty"`
	Seen      time.Time `json:"seen,omitempty"`
	Lapsed    time.Time `json:"lapsed,omitempty"`
	A         string    `json:"a,omitempty"`
	AID       string    `json:"a_id,omitempty"`
	AAAA      string    `json:"aaaa,omitempty"`
	AAAAID    string    `json:"aaaa_id,omitempty"`
	TXT       []TXT     `json:"txt,omitempty"`
}

type State struct {
	Secret string           `json:"secret"`
	Names  map[string]*Name `json:"names"`
}

// Store is the whole state in one JSON file, rewritten on each change. One mutex serialises
// every change, including the DNS calls it makes, so two calls can never race on a record.
type Store struct {
	mu   sync.Mutex
	path string
	s    State
}

func OpenStore(path string) (*Store, error) {
	st := &Store{path: path}
	b, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(b, &st.s); err != nil {
			return nil, err
		}
	}
	if st.s.Names == nil {
		st.s.Names = map[string]*Name{}
	}
	migrated := false
	for _, n := range st.s.Names {
		if n.Owner == "" && n.GitHubID != 0 {
			n.Owner, n.GitHubID, migrated = "github:"+strconv.FormatInt(n.GitHubID, 10), 0, true
		}
	}
	if st.s.Secret == "" || migrated {
		if st.s.Secret == "" {
			st.s.Secret = randomHex(32)
		}
		if err := st.save(); err != nil {
			return nil, err
		}
	}
	return st, nil
}

func (st *Store) save() error {
	b, err := json.MarshalIndent(st.s, "", " ")
	if err != nil {
		return err
	}
	tmp := st.path + ".new"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
