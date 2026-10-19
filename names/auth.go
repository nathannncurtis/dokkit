package main

import (
	"cmp"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"
)

// Provider is one OAuth sign-in. With JWKSURL set it is OpenID Connect and the account is the
// ID token's sub; otherwise the account is the id or sub its UserURL answers.
type Provider struct {
	Key, Title        string
	ClientID, Secret  string
	AuthURL, TokenURL string
	Scope             string
	UserURL           string
	JWKSURL           string
	Issuers           []string // "{tenantid}" stands for the token's tid claim
	Client            *http.Client
	NoPKCE            bool
	Mint              func(time.Time) (string, error) // makes the client secret per token call, in place of Secret
	Anon              string                          // the display name when the provider gives none
}

func (p *Provider) Big() bool {
	return slices.Contains([]string{"github", "google", "microsoft", "apple"}, p.Key)
}

type identity struct{ ID, Name string }

func (p *Provider) oidc() bool { return p.JWKSURL != "" }

func (p *Provider) client() *http.Client {
	if p.Client != nil {
		return p.Client
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (p *Provider) authorizeURL(redirect, state, verifier, nonce string) string {
	q := url.Values{"response_type": {"code"}, "client_id": {p.ClientID}, "redirect_uri": {redirect}, "state": {state}}
	if !p.NoPKCE {
		sum := sha256.Sum256([]byte(verifier))
		q.Set("code_challenge", b64.EncodeToString(sum[:]))
		q.Set("code_challenge_method", "S256")
	}
	if p.Scope != "" {
		q.Set("scope", p.Scope)
	}
	if p.oidc() {
		q.Set("nonce", nonce)
	}
	return p.AuthURL + "?" + q.Encode()
}

func (p *Provider) identify(code, redirect, verifier, nonce string, now time.Time) (identity, error) {
	secret := p.Secret
	if p.Mint != nil {
		var err error
		if secret, err = p.Mint(now); err != nil {
			return identity{}, err
		}
	}
	form := url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirect},
		"client_id": {p.ClientID}, "client_secret": {secret}}
	if !p.NoPKCE {
		form.Set("code_verifier", verifier)
	}
	req, _ := http.NewRequest("POST", p.TokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	var tok struct {
		AccessToken string `json:"access_token"`
		IDToken     string `json:"id_token"`
		Error       string `json:"error"`
	}
	if err := getJSON(p.client(), req, &tok); err != nil {
		return identity{}, err
	}
	var who struct {
		Sub, Login, Name, Username string
		GlobalName                 string `json:"global_name"`
		ID                         json.Number
	}
	if p.oidc() {
		if tok.IDToken == "" {
			return identity{}, errors.New("no id token: " + tok.Error)
		}
		keys, err := p.keys()
		if err != nil {
			return identity{}, err
		}
		c, err := checkIDToken(tok.IDToken, keys, p.Issuers, p.ClientID, nonce, now)
		if err != nil {
			return identity{}, err
		}
		who.Sub, who.Name = c.Sub, cmp.Or(c.Name, c.Nickname)
	} else {
		if tok.AccessToken == "" {
			return identity{}, errors.New("no access token: " + tok.Error)
		}
		req, _ = http.NewRequest("GET", p.UserURL, nil)
		req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", "dokkit-names")
		if err := getJSON(p.client(), req, &who); err != nil {
			return identity{}, err
		}
	}
	id := who.Sub
	if id == "" {
		id = who.ID.String()
	}
	if id == "" || id == "0" {
		return identity{}, errors.New("no account id")
	}
	for _, n := range []string{who.Login, who.GlobalName, who.Username, who.Name, p.Anon, id} {
		if n != "" {
			return identity{ID: id, Name: n}, nil
		}
	}
	return identity{}, nil
}

// shortcut: the key set is fetched on every sign-in; cache it if sign-ins ever get frequent.
func (p *Provider) keys() (map[string]*rsa.PublicKey, error) {
	req, _ := http.NewRequest("GET", p.JWKSURL, nil)
	var set struct {
		Keys []struct{ Kty, Kid, N, E string }
	}
	if err := getJSON(p.client(), req, &set); err != nil {
		return nil, fmt.Errorf("key set: %w", err)
	}
	out := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		n, err1 := b64.DecodeString(k.N)
		e, err2 := b64.DecodeString(k.E)
		if k.Kty != "RSA" || err1 != nil || err2 != nil || len(e) > 4 {
			continue
		}
		out[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	return out, nil
}

type audience []string

func (a *audience) UnmarshalJSON(b []byte) error {
	var one string
	if json.Unmarshal(b, &one) == nil {
		*a = audience{one}
		return nil
	}
	return json.Unmarshal(b, (*[]string)(a))
}

type idClaims struct {
	Iss, Sub, Nonce, Tid, Azp, Name, Nickname string
	Aud                                       audience
	Exp, Iat                                  int64
}

func checkIDToken(raw string, keys map[string]*rsa.PublicKey, issuers []string, clientID, nonce string, now time.Time) (*idClaims, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return nil, errors.New("id token is not a JWT")
	}
	var h struct{ Alg, Kid string }
	hb, err := b64.DecodeString(parts[0])
	if err != nil || json.Unmarshal(hb, &h) != nil || h.Alg != "RS256" {
		return nil, errors.New("id token is not RS256")
	}
	key := keys[h.Kid]
	sig, err := b64.DecodeString(parts[2])
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if key == nil || err != nil || rsa.VerifyPKCS1v15(key, crypto.SHA256, sum[:], sig) != nil {
		return nil, errors.New("id token signature does not verify")
	}
	var c idClaims
	cb, err := b64.DecodeString(parts[1])
	if err != nil || json.Unmarshal(cb, &c) != nil {
		return nil, errors.New("id token claims do not parse")
	}
	if !slices.ContainsFunc(issuers, func(iss string) bool {
		return (c.Tid != "" || !strings.Contains(iss, "{tenantid}")) && c.Iss == strings.ReplaceAll(iss, "{tenantid}", c.Tid)
	}) {
		return nil, fmt.Errorf("id token issuer %q is not expected", c.Iss)
	}
	if !slices.Contains(c.Aud, clientID) || (len(c.Aud) > 1 && c.Azp != clientID) {
		return nil, errors.New("id token is for another client")
	}
	if now.Unix() > c.Exp+int64(skew.Seconds()) || c.Iat > now.Add(skew).Unix() {
		return nil, errors.New("id token is out of date")
	}
	if !hmac.Equal([]byte(c.Nonce), []byte(nonce)) {
		return nil, errors.New("id token nonce does not match")
	}
	if c.Sub == "" {
		return nil, errors.New("id token has no sub")
	}
	return &c, nil
}

// configuredProviders is every sign-in whose client id and secret are set, in page order.
func configuredProviders() ([]*Provider, error) {
	gh, ms, oa := env("GITHUB_WEB", "https://github.com"), "https://login.microsoftonline.com", "https://auth.openai.com"
	ap, gl, cb := "https://appleid.apple.com", "https://gitlab.com", "https://codeberg.org"
	all := []*Provider{
		{Key: "github", Title: "GitHub", AuthURL: gh + "/login/oauth/authorize", TokenURL: gh + "/login/oauth/access_token",
			UserURL: env("GITHUB_API", "https://api.github.com") + "/user"},
		{Key: "google", Title: "Google", AuthURL: "https://accounts.google.com/o/oauth2/v2/auth", TokenURL: "https://oauth2.googleapis.com/token",
			JWKSURL: "https://www.googleapis.com/oauth2/v3/certs", Issuers: []string{"https://accounts.google.com", "accounts.google.com"}, Scope: "openid profile"},
		{Key: "microsoft", Title: "Microsoft", AuthURL: ms + "/common/oauth2/v2.0/authorize", TokenURL: ms + "/common/oauth2/v2.0/token",
			JWKSURL: ms + "/common/discovery/v2.0/keys", Issuers: []string{ms + "/{tenantid}/v2.0"}, Scope: "openid profile"},
		{Key: "apple", Title: "Apple", AuthURL: ap + "/auth/authorize", TokenURL: ap + "/auth/token",
			JWKSURL: ap + "/auth/keys", Issuers: []string{ap}, NoPKCE: true, Anon: "an Apple account"},
		{Key: "chatgpt", Title: "ChatGPT", AuthURL: oa + "/api/accounts/authorize", TokenURL: oa + "/api/accounts/oauth/token",
			JWKSURL: oa + "/.well-known/jwks.json", Issuers: []string{oa}, Scope: "openid profile"},
		{Key: "gitlab", Title: "GitLab", AuthURL: gl + "/oauth/authorize", TokenURL: gl + "/oauth/token",
			JWKSURL: gl + "/oauth/discovery/keys", Issuers: []string{gl}, Scope: "openid"},
		{Key: "discord", Title: "Discord", AuthURL: "https://discord.com/oauth2/authorize", TokenURL: "https://discord.com/api/oauth2/token",
			UserURL: "https://discord.com/api/users/@me", Scope: "identify"},
		{Key: "codeberg", Title: "Codeberg", AuthURL: cb + "/login/oauth/authorize", TokenURL: cb + "/login/oauth/access_token",
			JWKSURL: cb + "/login/oauth/keys", Issuers: []string{cb}, Scope: "openid profile"},
	}
	var out []*Provider
	for _, p := range all {
		up := strings.ToUpper(p.Key)
		if p.Key == "apple" {
			ok, err := setUpApple(p)
			if err != nil {
				return nil, err
			}
			if ok {
				out = append(out, p)
			}
			continue
		}
		p.ClientID, p.Secret = os.Getenv(up+"_CLIENT_ID"), os.Getenv(up+"_CLIENT_SECRET")
		if p.ClientID == "" && p.Secret == "" {
			continue
		}
		if p.ClientID == "" || p.Secret == "" {
			return nil, fmt.Errorf("%s_CLIENT_ID and %s_CLIENT_SECRET are set together", up, up)
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return nil, errors.New("no sign-in is set up: set the client id and secret of at least one of GitHub, Google, Microsoft, Apple, ChatGPT, GitLab, Discord, Codeberg")
	}
	return out, nil
}

var appleEnv = []string{"APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_CLIENT_ID", "APPLE_PRIVATE_KEY_FILE"}

func setUpApple(p *Provider) (bool, error) {
	var vals []string
	for _, k := range appleEnv {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			vals = append(vals, v)
		}
	}
	if len(vals) == 0 {
		return false, nil
	}
	if len(vals) != len(appleEnv) {
		return false, fmt.Errorf("%s are set together", strings.Join(appleEnv, ", "))
	}
	key, err := loadECKey(vals[3])
	if err != nil {
		return false, fmt.Errorf("APPLE_PRIVATE_KEY_FILE: %w", err)
	}
	p.ClientID, p.Mint = vals[2], appleSecret(vals[0], vals[1], vals[2], key)
	return true, nil
}

func loadECKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("not a PEM file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if ec, ok := k.(*ecdsa.PrivateKey); err == nil && ok && ec.Curve == elliptic.P256() {
		return ec, nil
	}
	return nil, errors.New("not a P-256 private key in PKCS #8")
}

// appleSecret makes Apple's client secret: an ES256 JWT from the team's key, short-lived since it is made per call.
func appleSecret(team, keyID, clientID string, key *ecdsa.PrivateKey) func(time.Time) (string, error) {
	return func(now time.Time) (string, error) {
		h, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
		c, _ := json.Marshal(map[string]any{"iss": team, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
			"aud": "https://appleid.apple.com", "sub": clientID})
		in := b64.EncodeToString(h) + "." + b64.EncodeToString(c)
		sum := sha256.Sum256([]byte(in))
		r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
		if err != nil {
			return "", err
		}
		sig := make([]byte, 64)
		r.FillBytes(sig[:32])
		s.FillBytes(sig[32:])
		return in + "." + b64.EncodeToString(sig), nil
	}
}
