package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"
)

// Azure writes the zone's records through Azure DNS. A record's id is "TYPE/name/value",
// since Azure keeps records in sets by name and type, not one by one.
type Azure struct {
	API, Login                string
	Tenant, ClientID, Secret  string
	Subscription, Group, Zone string
	Client                    *http.Client
	mu                        sync.Mutex
	token                     string
	until                     time.Time
}

var errNotFound = errors.New("no such record set")

func (az *Azure) client() *http.Client {
	if az.Client != nil {
		return az.Client
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (az *Azure) bearer() (string, error) {
	az.mu.Lock()
	defer az.mu.Unlock()
	if az.token != "" && time.Now().Before(az.until) {
		return az.token, nil
	}
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {az.ClientID}, "client_secret": {az.Secret}, "scope": {"https://management.azure.com/.default"}}
	resp, err := az.client().PostForm(az.Login+"/"+az.Tenant+"/oauth2/v2.0/token", form)
	if err != nil {
		return "", fmt.Errorf("azure sign-in could not be reached: %w", err)
	}
	defer resp.Body.Close()
	var r struct {
		Token   string `json:"access_token"`
		Expires int    `json:"expires_in"`
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&r); resp.StatusCode != 200 || r.Token == "" {
		return "", fmt.Errorf("azure sign-in answered %d", resp.StatusCode)
	}
	az.token, az.until = r.Token, time.Now().Add(time.Duration(r.Expires-120)*time.Second)
	return az.token, nil
}

type azSet struct {
	Properties struct {
		TTL int `json:"TTL"`
		A   []struct {
			IPv4 string `json:"ipv4Address"`
		} `json:"ARecords,omitempty"`
		AAAA []struct {
			IPv6 string `json:"ipv6Address"`
		} `json:"AAAARecords,omitempty"`
		TXT []struct {
			Value []string `json:"value"`
		} `json:"TXTRecords,omitempty"`
	} `json:"properties"`
}

func (s *azSet) values(typ string) (out []string) {
	switch typ {
	case "A":
		for _, r := range s.Properties.A {
			out = append(out, r.IPv4)
		}
	case "AAAA":
		for _, r := range s.Properties.AAAA {
			out = append(out, r.IPv6)
		}
	case "TXT":
		for _, r := range s.Properties.TXT {
			out = append(out, strings.Join(r.Value, ""))
		}
	}
	return out
}

func setOf(typ string, values []string) azSet {
	var s azSet
	s.Properties.TTL = 60
	for _, v := range values {
		switch typ {
		case "A":
			s.Properties.A = append(s.Properties.A, struct {
				IPv4 string `json:"ipv4Address"`
			}{v})
		case "AAAA":
			s.Properties.AAAA = append(s.Properties.AAAA, struct {
				IPv6 string `json:"ipv6Address"`
			}{v})
		case "TXT":
			s.Properties.TXT = append(s.Properties.TXT, struct {
				Value []string `json:"value"`
			}{[]string{v}})
		}
	}
	return s
}

func (az *Azure) rel(fqdn string) string {
	if fqdn == az.Zone {
		return "@"
	}
	return strings.TrimSuffix(fqdn, "."+az.Zone)
}

func (az *Azure) call(method, typ, rel string, in, out any) error {
	tok, err := az.bearer()
	if err != nil {
		return err
	}
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	u := fmt.Sprintf("%s/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/dnsZones/%s/%s/%s?api-version=2018-05-01",
		az.API, az.Subscription, az.Group, az.Zone, typ, url.PathEscape(rel))
	req, _ := http.NewRequest(method, u, body)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := az.client().Do(req)
	if err != nil {
		return fmt.Errorf("azure dns could not be reached: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode >= 300 {
		var e struct{ Error struct{ Message string } }
		json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&e)
		return fmt.Errorf("azure dns answered %d: %s", resp.StatusCode, e.Error.Message)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
	}
	return nil
}

func (az *Azure) get(typ, rel string) ([]string, error) {
	var s azSet
	if err := az.call("GET", typ, rel, nil, &s); errors.Is(err, errNotFound) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	return s.values(typ), nil
}

func (az *Azure) write(typ, rel string, values []string) error {
	if len(values) == 0 {
		if err := az.call("DELETE", typ, rel, nil, nil); !errors.Is(err, errNotFound) {
			return err
		}
		return nil
	}
	return az.call("PUT", typ, rel, setOf(typ, values), nil)
}

// Exists says whether the zone holds any record at fqdn.
func (az *Azure) Exists(fqdn string) (bool, error) {
	for _, typ := range []string{"A", "AAAA", "CNAME", "TXT", "MX", "NS"} {
		err := az.call("GET", typ, az.rel(fqdn), nil, nil)
		if err == nil {
			return true, nil
		}
		if !errors.Is(err, errNotFound) {
			return false, err
		}
	}
	return false, nil
}

// Put sets the record and returns its id. An address replaces the name's set; a TXT value joins it.
func (az *Azure) Put(id, typ, fqdn, content string) (string, error) {
	rel, newID := az.rel(fqdn), typ+"/"+az.rel(fqdn)+"/"+content
	if typ != "TXT" {
		return newID, az.write(typ, rel, []string{content})
	}
	if id != "" && id != newID {
		if err := az.Delete(id); err != nil {
			return "", err
		}
	}
	have, err := az.get(typ, rel)
	if err != nil || slices.Contains(have, content) {
		return newID, err
	}
	return newID, az.write(typ, rel, append(have, content))
}

func (az *Azure) Delete(id string) error {
	typ, rest, _ := strings.Cut(id, "/")
	rel, value, _ := strings.Cut(rest, "/")
	have, err := az.get(typ, rel)
	if err != nil {
		return err
	}
	return az.write(typ, rel, slices.DeleteFunc(have, func(v string) bool { return v == value }))
}
