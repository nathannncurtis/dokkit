package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/url"
	"time"
)

const turnstileVerify = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

// Turnstile asks Cloudflare whether the claim form was filled in by a person.
type Turnstile struct {
	SiteKey, Secret string
	URL             string
	Client          *http.Client
}

func (t *Turnstile) Verify(token, ip string) error {
	if token == "" {
		return refuse(http.StatusForbidden, "Wait for the check under the name to finish, then claim.")
	}
	endpoint, client := t.URL, t.Client
	if endpoint == "" {
		endpoint = turnstileVerify
	}
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.PostForm(endpoint, url.Values{"secret": {t.Secret}, "response": {token}, "remoteip": {ip}})
	if err != nil {
		log.Printf("turnstile: %v", err)
		return refuse(http.StatusServiceUnavailable, "The check that you are a person could not be confirmed just now. Try again.")
	}
	defer resp.Body.Close()
	var out struct {
		Success bool     `json:"success"`
		Action  string   `json:"action"`
		Codes   []string `json:"error-codes"`
	}
	if resp.StatusCode != 200 || json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&out) != nil {
		log.Printf("turnstile: answered %s", resp.Status)
		return refuse(http.StatusServiceUnavailable, "The check that you are a person could not be confirmed just now. Try again.")
	}
	if !out.Success || out.Action != "claim" {
		log.Printf("turnstile: refused %v", out.Codes)
		return refuse(http.StatusForbidden, "The check that you are a person did not pass. Try again.")
	}
	return nil
}
