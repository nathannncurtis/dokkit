package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const imessageWork = "dokkit:imessage"

// Tests replace these.
var (
	isMac    = runtime.GOOS == "darwin"
	sendText = sendMessages
)

const (
	notMacSaid   = "iMessage is sent only from a Mac signed in to Messages, and this machine is not a Mac."
	notOnSaid    = "This Mac has not been told it may send iMessages. On it, run: dokkit imessage on"
	notAllowed   = "macOS has not allowed dokkit to control Messages. On this Mac's screen, allow it when asked, or switch it on under System Settings, Privacy & Security, Automation."
	badRecipient = "not a phone number or an email address"
	textLimit    = 1000
)

var (
	phoneRe = regexp.MustCompile(`^\+?[0-9 ()-]+$`)
	emailRe = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
)

func validRecipient(r string) bool {
	if emailRe.MatchString(r) {
		return true
	}
	digits := 0
	for _, c := range r {
		if c >= '0' && c <= '9' {
			digits++
		}
	}
	return phoneRe.MatchString(r) && digits >= 3
}

// cutText limits a message to textLimit characters, ending in "..." when it was cut.
func cutText(s string) string {
	r := []rune(s)
	if len(r) <= textLimit {
		return s
	}
	return string(r[:textLimit-3]) + "..."
}

// sendFailure is the reason for a failed osascript run, from what it printed.
func sendFailure(out string) string {
	if strings.Contains(out, "-1743") || strings.Contains(strings.ToLower(out), "not authorized") {
		return notAllowed
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return "osascript failed"
}

// sendAll sends text to each recipient and returns one line each and whether all were sent.
func sendAll(to []string, text string) ([]string, bool) {
	text = cutText(text)
	var lines []string
	all := true
	for _, r := range to {
		r = strings.TrimSpace(r)
		why := ""
		if !validRecipient(r) {
			why = badRecipient
		} else if err := sendText(r, text); err != nil {
			why = err.Error()
		}
		if why != "" {
			all = false
			lines = append(lines, "not sent to "+r+": "+why)
		} else {
			lines = append(lines, "sent to "+r)
		}
	}
	return lines, all
}

// imessageRefusal is why this machine will not send for the server, or "".
func imessageRefusal(on bool, to []string, text string) string {
	switch {
	case !isMac:
		return notMacSaid
	case !on:
		return notOnSaid
	case len(to) == 0:
		return "The request names no one to send to."
	case strings.TrimSpace(text) == "":
		return "The request has no text to send."
	}
	return ""
}

// imessage answers a piece of work for sending.
func (c *client) imessage(run string, to []string, text string) {
	result := "/api/v1/work/" + run + "/result"
	s, _ := readConfig()
	if why := imessageRefusal(s.IMessage, to, text); why != "" {
		body, _ := json.Marshal(map[string]string{"refused": why})
		c.postResult(result, body)
		return
	}
	started := time.Now()
	lines, all := sendAll(to, text)
	said := strings.Join(lines, "\n") + "\n"
	fmt.Println(time.Now().Format("15:04:05"), "", strings.Join(lines, "; "))
	c.call("POST", "/api/v1/work/"+run+"/output", "text/plain", []byte(said), nil)
	code := 0
	if !all {
		code = 1
	}
	body, _ := json.Marshal(map[string]any{"exit_code": code, "duration_ms": time.Since(started).Milliseconds()})
	c.postResult(result, body)
}

// imessageCommand turns this Mac's sending for the server on or off, or tries one send.
func imessageCommand(args []string) int {
	word := "status"
	if len(args) > 0 {
		word = args[0]
	}
	switch {
	case word == "test" && len(args) >= 2:
		if !isMac {
			fmt.Fprintln(os.Stderr, "dokkit: "+notMacSaid)
			return 1
		}
		text := "Test message from dokkit"
		if len(args) > 2 {
			text = strings.Join(args[2:], " ")
		}
		lines, all := sendAll(args[1:2], text)
		fmt.Println(lines[0])
		if !all {
			return 1
		}
		return 0
	case (word == "status" || word == "on" || word == "off") && len(args) <= 1:
	default:
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	path, service := folderConfig()
	fail := func(err error) int {
		if errors.Is(err, fs.ErrPermission) && service {
			fmt.Fprintln(os.Stderr, "dokkit: only an administrator can change or read the installed service's configuration. Run it "+elevated(append([]string{"imessage"}, args...)...))
		} else {
			fmt.Fprintln(os.Stderr, "dokkit:", err)
		}
		return 1
	}
	raw, list, err := readFolders(path)
	if err != nil {
		return fail(err)
	}
	if word == "status" {
		var on bool
		json.Unmarshal(raw["imessage"], &on)
		if on {
			fmt.Println("iMessage is on: this Mac may send iMessages when the server asks.")
		} else {
			fmt.Println("iMessage is off: this Mac sends nothing for the server. Turn it on with: dokkit imessage on")
		}
		return 0
	}
	if word == "on" {
		if !isMac {
			fmt.Fprintln(os.Stderr, "dokkit: "+notMacSaid)
			return 1
		}
		raw["imessage"] = json.RawMessage("true")
	} else {
		delete(raw, "imessage")
	}
	if err := saveFolders(path, raw, list, service); err != nil {
		return fail(err)
	}
	if word == "on" {
		fmt.Println("iMessage is on. A running dokkit watch picks it up on the next request, with no restart. Prove Messages works first with: dokkit imessage test <recipient>")
	} else {
		fmt.Println("iMessage is off. A running dokkit watch picks it up on the next request, with no restart.")
	}
	return 0
}
