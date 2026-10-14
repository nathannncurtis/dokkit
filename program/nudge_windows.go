package main

import (
	"golang.org/x/sys/windows/svc/eventlog"
)

const (
	eventSource = "Dokkit"
	eventID     = 100
	eventText   = "Update requested"
)

var writeEvent = func() error {
	l, err := eventlog.Open(eventSource)
	if err != nil {
		return err
	}
	defer l.Close()
	return l.Info(eventID, eventText)
}

// realPoke writes an entry to the Application log. The updater's task has an event trigger for it.
func realPoke() (string, error) {
	if err := writeEvent(); err != nil {
		return "", err
	}
	return "Asked the updater to check now (event written).\n", nil
}
