package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/url"
	"sync"
	"time"
)

const skew = 5 * time.Minute

type header struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
	JWK *JWK   `json:"jwk"`
	URL string `json:"url"`
	Iat int64  `json:"iat"`
}

type jws struct {
	Protected string `json:"protected"`
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

var b64 = base64.RawURLEncoding

func publicKey(k *JWK) (*ecdsa.PublicKey, error) {
	if k == nil || k.Kty != "EC" || k.Crv != "P-256" {
		return nil, errors.New("the key must be an EC P-256 key")
	}
	x, err1 := b64.DecodeString(k.X)
	y, err2 := b64.DecodeString(k.Y)
	if err1 != nil || err2 != nil || len(x) != 32 || len(y) != 32 {
		return nil, errors.New("the key's coordinates are not 32 bytes each")
	}
	return ecdsa.ParseUncompressedPublicKey(elliptic.P256(), append(append([]byte{4}, x...), y...))
}

type Replays struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func (r *Replays) first(sig string, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.seen == nil {
		r.seen = map[string]time.Time{}
	}
	for k, at := range r.seen {
		if now.Sub(at) > 2*skew {
			delete(r.seen, k)
		}
	}
	if _, ok := r.seen[sig]; ok {
		return false
	}
	r.seen[sig] = now
	return true
}

// Signed like ACME, but "iat" plus a replay memory stands in for nonces, so a call is one round trip.
func Verify(body []byte, path string, now time.Time, replays *Replays, keyFor func(string) *JWK) (*header, []byte, error) {
	var msg jws
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, nil, errors.New("the body is not a signed request")
	}
	raw, err := b64.DecodeString(msg.Protected)
	if err != nil {
		return nil, nil, errors.New("the protected header is not base64url")
	}
	var h header
	if err := json.Unmarshal(raw, &h); err != nil || h.Alg != "ES256" {
		return nil, nil, errors.New("the protected header must say alg ES256")
	}
	if u := pathOf(h.URL); u != path {
		return nil, nil, errors.New("the signed url is not this address")
	}
	if d := now.Sub(time.Unix(h.Iat, 0)); d > skew || d < -skew {
		return nil, nil, errors.New("iat is more than five minutes from this server's clock")
	}
	key := h.JWK
	if key == nil {
		key = keyFor(h.Kid)
	}
	pub, err := publicKey(key)
	if err != nil {
		return nil, nil, err
	}
	sig, err := b64.DecodeString(msg.Signature)
	if err != nil || len(sig) != 64 {
		return nil, nil, errors.New("the signature is not 64 bytes")
	}
	digest := sha256.Sum256([]byte(msg.Protected + "." + msg.Payload))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return nil, nil, errors.New("the signature does not verify")
	}
	if !replays.first(string(digest[:]), now) {
		return nil, nil, errors.New("this request was already used")
	}
	payload, err := b64.DecodeString(msg.Payload)
	if err != nil {
		return nil, nil, errors.New("the payload is not base64url")
	}
	return &h, payload, nil
}

func pathOf(u string) string {
	if p, err := url.Parse(u); err == nil {
		return p.Path
	}
	return ""
}
