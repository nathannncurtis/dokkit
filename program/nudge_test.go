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
	got, _ := nudgeLogged(t, poke)
	return got
}

func nudgeLogged(t *testing.T, poke func() (string, error)) ([]string, []string) {
	old, oldLog := pokeUpdater, nudgeLog
	pokeUpdater = poke
	var logged []string
	nudgeLog = func(said string) { logged = append(logged, said) }
	defer func() { pokeUpdater, nudgeLog = old, oldLog }()
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = append(got, r.URL.Path+" "+string(b))
	}))
	defer srv.Close()
	(&client{url: srv.URL, key: "k"}).nudge("r1")
	return got, logged
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

func TestNudgeLogsEachOutcome(t *testing.T) {
	_, logged := nudgeLogged(t, func() (string, error) { return "Started the updater task.\n", nil })
	if len(logged) != 1 || !strings.Contains(logged[0], "Started the updater task") {
		t.Fatalf("%q", logged)
	}
	_, logged = nudgeLogged(t, func() (string, error) { return "", errNoNudge })
	if len(logged) != 1 || !strings.Contains(logged[0], "next scheduled check") {
		t.Fatalf("%q", logged)
	}
	got, logged := nudgeLogged(t, func() (string, error) { return "", errors.New("schtasks: exit status 1 ERROR: Access is denied.") })
	want := "Could not ask the updater to check: schtasks: exit status 1 ERROR: Access is denied."
	if len(logged) != 1 || logged[0] != want || len(got) != 1 || !strings.Contains(got[0], want) {
		t.Fatalf("%q %q", logged, got)
	}
}
