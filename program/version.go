package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// The release workflow sets this with -ldflags "-X main.version=v1.2.3".
var version = "v0.0.0-dev"

// releaseKey is the public half of the key that signs every release.
var releaseKey = "xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk="

var versionPattern = regexp.MustCompile(`^v(\d+)\.(\d+)\.(\d+)$`)

func parseVersion(s string) (v [3]int, ok bool) {
	m := versionPattern.FindStringSubmatch(s)
	if m == nil {
		return v, false
	}
	for i := range v {
		n, err := strconv.Atoi(m[i+1])
		if err != nil {
			return v, false
		}
		v[i] = n
	}
	return v, true
}

// compareVersions is -1, 0 or 1. What is not a version is older than every version.
func compareVersions(a, b string) (int, error) {
	x, okA := parseVersion(a)
	y, okB := parseVersion(b)
	switch {
	case !okA && !okB:
		return 0, fmt.Errorf("neither %q nor %q is a version", a, b)
	case !okA:
		return -1, nil
	case !okB:
		return 1, nil
	}
	return slices.Compare(x[:], y[:]), nil
}

// verifyRelease checks the signature over the exact bytes of the list and its version line,
// and returns file name to lower-case hex SHA-256.
func verifyRelease(sums, sig []byte, want string) (map[string]string, error) {
	pub, err := base64.StdEncoding.DecodeString(releaseKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, errors.New("the built-in release key is not valid")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(raw) != ed25519.SignatureSize {
		return nil, errors.New("SHA256SUMS.sig is not a base64 Ed25519 signature")
	}
	if !ed25519.Verify(pub, sums, raw) {
		return nil, errors.New("the signature of SHA256SUMS does not check against the release key")
	}
	lines := strings.Split(strings.TrimSuffix(string(sums), "\n"), "\n")
	if lines[0] != "version "+want {
		return nil, fmt.Errorf("the signed list says %q, not version %s", lines[0], want)
	}
	files := map[string]string{}
	for _, l := range lines[1:] {
		// sha256sum writes two spaces, or a space and an asterisk for a binary file.
		h, name, ok := strings.Cut(l, " ")
		name = strings.TrimPrefix(strings.TrimPrefix(name, " "), "*")
		if _, err := hex.DecodeString(h); !ok || err != nil || len(h) != 64 || name == "" {
			return nil, fmt.Errorf("the signed list has a line that is not a hash and a file name: %q", l)
		}
		files[name] = strings.ToLower(h)
	}
	return files, nil
}
