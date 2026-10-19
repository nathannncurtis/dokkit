package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

var errNotFound = errors.New("cloudflare has no such record")

type Cloudflare struct {
	API    string
	Token  string
	Zone   string
	Client *http.Client
}

type cfRecord struct {
	ID      string `json:"id,omitempty"`
	Type    string `json:"type"`
	Name    string `json:"name"`
	Content string `json:"content"`
	TTL     int    `json:"ttl"`
	Proxied bool   `json:"proxied"`
}

func (cf *Cloudflare) call(method, path string, in any, out any) error {
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, cf.API+"/zones/"+cf.Zone+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cf.Token)
	req.Header.Set("Content-Type", "application/json")
	client := cf.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("cloudflare could not be reached: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound && path != "/dns_records" {
		return errNotFound
	}
	var r struct {
		Success bool                       `json:"success"`
		Errors  []struct{ Message string } `json:"errors"`
		Result  json.RawMessage            `json:"result"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&r); err != nil || !r.Success {
		if len(r.Errors) > 0 {
			return fmt.Errorf("cloudflare refused: %s", r.Errors[0].Message)
		}
		return fmt.Errorf("cloudflare answered %d", resp.StatusCode)
	}
	if out != nil {
		return json.Unmarshal(r.Result, out)
	}
	return nil
}

// Exists says whether the zone holds any record at fqdn.
func (cf *Cloudflare) Exists(fqdn string) (bool, error) {
	var recs []cfRecord
	err := cf.call("GET", "/dns_records?name="+url.QueryEscape(fqdn), nil, &recs)
	return len(recs) > 0, err
}

// Put creates the record, or changes it when id names one. It returns the record's id.
func (cf *Cloudflare) Put(id, typ, fqdn, content string) (string, error) {
	rec := cfRecord{Type: typ, Name: fqdn, Content: content, TTL: 60}
	var out cfRecord
	var err error
	if id == "" {
		err = cf.call("POST", "/dns_records", rec, &out)
	} else if err = cf.call("PUT", "/dns_records/"+id, rec, &out); errors.Is(err, errNotFound) {
		return cf.Put("", typ, fqdn, content)
	}
	return out.ID, err
}

func (cf *Cloudflare) Delete(id string) error {
	if err := cf.call("DELETE", "/dns_records/"+id, nil, nil); !errors.Is(err, errNotFound) {
		return err
	}
	return nil
}
