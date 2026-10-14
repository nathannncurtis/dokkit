package main

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func nudgeWith(t *testing.T, poke func() (string, error)) []string {
	old := pokeUpdater
	pokeUpdater = poke
	defer func() { pokeUpdater = old }()
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = append(got, r.URL.Path+" "+string(b))
	}))
	defer srv.Close()
	(&client{url: srv.URL, key: "k"}).nudge("r1")
	return got
}

func TestNudgeAnswersDoneAfterPoking(t *testing.T) {
	got := nudgeWith(t, func() (string, error) { return "Asked.\n", nil })
	if len(got) != 2 || got[0] != "/api/v1/work/r1/output Asked.\n" || got[1] != `/api/v1/work/r1/result {"exit_code":0,"duration_ms":0}` {
		t.Fatalf("%q", got)
	}
}

func TestNudgeWithNothingToPokeAnswersDoneAndSaysWhen(t *testing.T) {
	got := nudgeWith(t, func() (string, error) { return "", errNoNudge })
	if len(got) != 2 || !strings.Contains(got[0], "next scheduled check") || !strings.Contains(got[1], `"exit_code":0`) {
		t.Fatalf("%q", got)
	}
}

func TestNudgeThatCannotPokeGivesTheReason(t *testing.T) {
	got := nudgeWith(t, func() (string, error) { return "", errors.New("Access is denied") })
	if len(got) != 1 || !strings.Contains(got[0], `{"refused":"Could not ask the updater to check: Access is denied"}`) {
		t.Fatalf("%q", got)
	}
}
