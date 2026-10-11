//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTheServiceReadsFoldersOnlyFromAFileOnlyRootCanWrite(t *testing.T) {
	if listsPath() != "" {
		t.Skip("a service is installed here")
	}
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"url":"https://s","key":"dkm_x","folders":["/srv/app"]}`), 0o600)
	t.Setenv("DOKKIT_CONFIG", cfg)
	t.Setenv("DOKKIT_FOLDERS", "")
	t.Setenv("DOKKIT_SPOOL", t.TempDir())
	c, err := load()
	if err != nil || len(c.folders) != 1 {
		t.Fatalf("under a login the person's own list counts: %v %v", c, err)
	}
	insideService(t)
	if c, err = load(); err != nil || len(c.folders) != 0 {
		t.Fatalf("the service refuses a list in a file others can write: %v %v", c, err)
	}
}

func TestAStatusFileTheAccountCannotReadSaysToUseSudo(t *testing.T) {
	spool := t.TempDir()
	f := filepath.Join(spool, "status.json")
	os.WriteFile(f, []byte("{}"), 0o000)
	if _, err := os.ReadFile(f); err == nil {
		t.Skip("this account can read anything")
	}
	out, _ := capture(t, func() { (&client{spool: spool}).status() })
	if !strings.Contains(out, "Run this with sudo") || strings.Contains(out, "has not run") {
		t.Fatalf("%q", out)
	}
}
