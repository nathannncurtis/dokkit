package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidRecipient(t *testing.T) {
	for _, r := range []string{"+15555550100", "(555) 555-0100", "555 555 0100", "someone@example.com"} {
		if !validRecipient(r) {
			t.Errorf("%q should be valid", r)
		}
	}
	for _, r := range []string{"", "+", "12", "abc", "555-0100; rm", "a b@example.com", "x@y", `5" & quit`, "-e"} {
		if validRecipient(r) {
			t.Errorf("%q should be invalid", r)
		}
	}
}

func TestCutText(t *testing.T) {
	if got := cutText("short"); got != "short" {
		t.Fatal(got)
	}
	long := strings.Repeat("é", 1500)
	got := cutText(long)
	if r := []rune(got); len(r) != textLimit || !strings.HasSuffix(got, "...") {
		t.Fatalf("got %d runes", len(r))
	}
	if exact := strings.Repeat("a", textLimit); cutText(exact) != exact {
		t.Fatal("a message at the limit was cut")
	}
}

func TestSendFailure(t *testing.T) {
	for _, out := range []string{
		"execution error: Not authorized to send Apple events to Messages. (-1743)\n",
		"something -1743 happened",
	} {
		if sendFailure(out) != notAllowed {
			t.Errorf("%q", out)
		}
	}
	if got := sendFailure("first\n\nexecution error: Can't get account. (-1728)\n\n"); got != "execution error: Can't get account. (-1728)" {
		t.Fatal(got)
	}
	if sendFailure("") == "" {
		t.Fatal("empty output gave no reason")
	}
}

func TestImessageRefusal(t *testing.T) {
	was := isMac
	defer func() { isMac = was }()
	to := []string{"+15555550100"}
	isMac = false
	if imessageRefusal(true, to, "hi") != notMacSaid {
		t.Fatal("not a Mac")
	}
	isMac = true
	if imessageRefusal(false, to, "hi") != notOnSaid {
		t.Fatal("not on")
	}
	if imessageRefusal(true, nil, "hi") == "" || imessageRefusal(true, to, "  ") == "" {
		t.Fatal("empty request allowed")
	}
	if imessageRefusal(true, to, "hi") != "" {
		t.Fatal("refused a good request")
	}
}

func TestSendAll(t *testing.T) {
	was := sendText
	defer func() { sendText = was }()
	var sent []string
	sendText = func(to, text string) error {
		if to == "bad@example.com" {
			return errors.New("no such account")
		}
		sent = append(sent, to+"|"+text)
		return nil
	}
	lines, all := sendAll([]string{"+15555550100", "bad@example.com", "nope"}, "hello")
	want := []string{"sent to +15555550100", "not sent to bad@example.com: no such account", "not sent to nope: " + badRecipient}
	if all || strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("%v %v", all, lines)
	}
	if len(sent) != 1 || sent[0] != "+15555550100|hello" {
		t.Fatal(sent)
	}
	if _, all := sendAll([]string{"a@b.co"}, "x"); !all {
		t.Fatal("one sent should be all sent")
	}
}

func TestImessageOnOff(t *testing.T) {
	was := isMac
	defer func() { isMac = was }()
	cfg := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("DOKKIT_CONFIG", cfg)
	os.WriteFile(cfg, []byte(`{"url":"u","key":"k"}`), 0o600)
	isMac = false
	if imessageCommand([]string{"on"}) != 1 {
		t.Fatal("on worked off a Mac")
	}
	isMac = true
	if imessageCommand([]string{"on"}) != 0 {
		t.Fatal("on failed")
	}
	if s, _ := readConfig(); !s.IMessage || s.URL != "u" {
		t.Fatalf("%+v", s)
	}
	if imessageCommand([]string{"off"}) != 0 {
		t.Fatal("off failed")
	}
	if s, _ := readConfig(); s.IMessage || s.Key != "k" {
		t.Fatalf("%+v", s)
	}
	if imessageCommand(nil) != 0 || imessageCommand([]string{"bogus"}) != 2 || imessageCommand([]string{"test"}) != 2 {
		t.Fatal("status or usage")
	}
}
