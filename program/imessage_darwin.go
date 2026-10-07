package main

import (
	"context"
	"errors"
	"os/exec"
	"time"
)

const messagesScript = `on run argv
tell application "Messages"
set s to 1st account whose service type = iMessage
send (item 2 of argv) to participant (item 1 of argv) of s
end tell
end run`

// sendMessages sends text to one recipient through Messages. The recipient and text are
// arguments to the script, never part of it.
func sendMessages(to, text string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-e", messagesScript, "--", to, text).CombinedOutput()
	if ctx.Err() != nil {
		return errors.New("Messages did not answer within 30 seconds")
	}
	if err != nil {
		return errors.New(sendFailure(string(out)))
	}
	return nil
}
