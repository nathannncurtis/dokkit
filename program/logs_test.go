package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAJSONLineAfterAByteOrderMarkIsRead(t *testing.T) {
	c, lines := logSink(t)
	file := filepath.Join(t.TempDir(), "app.log")
	os.WriteFile(file, []byte("\xef\xbb\xbf{\"level\":\"info\",\"msg\":\"started\"}\n"), 0o600)
	c.sendLog("s", file, map[string]int64{})
	if len(*lines) != 1 || (*lines)[0] != "started" {
		t.Fatalf("%q", *lines)
	}
}
