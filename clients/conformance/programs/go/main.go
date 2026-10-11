package main

import (
	"os"

	dokkit "github.com/nathannncurtis/dokkit/clients/go"
)

type ConformanceError struct{}

func (ConformanceError) Error() string { return "x" }

func main() {
	tag := os.Args[1]
	dokkit.Start("9.9.9")
	dokkit.Beat("conf-beat", 60)
	dokkit.Job("conf-job", func(*dokkit.Run) error { return nil })
	dokkit.Check("conf-check", "ok", 1, "")
	dokkit.Metric("conf.metric", 5, "n")
	dokkit.Log("info", "conformance "+tag, map[string]any{"tag": tag, "n": 1})
	dokkit.Capture(ConformanceError{})
	dokkit.Flush()
}
