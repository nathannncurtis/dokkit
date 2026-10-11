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

func TestEachDiskIsListedOnce(t *testing.T) {
	mac := []string{
		"Filesystem 1024-blocks Used Available Capacity Mounted on",
		"/dev/disk3s1s1 482000000 11000000 200000000 6% /",
		"/dev/disk3s5 482000000 280000000 200000000 59% /System/Volumes/Data",
		"/dev/disk3s6 482000000 20000 200000000 1% /System/Volumes/VM",
		"/dev/disk3s4 482000000 700000 200000000 1% /System/Volumes/Preboot",
		"/dev/disk1s2 500000 15000 480000 4% /System/Volumes/xarts",
		"/dev/disk3s3 482000000 900000 200000000 1% /Volumes/Recovery",
		"/dev/disk5s1 1000000 840000 160000 85% /Volumes/Backup",
	}
	got := disksFrom(mac)
	if len(got) != 2 || got[0]["mount"] != "/" || got[1]["mount"] != "/Volumes/Backup" {
		t.Fatalf("%v", got)
	}
	linux := []string{
		"/dev/sda2 100000000 50000000 50000000 50% /",
		"/dev/sda2 100000000 50000000 50000000 50% /var/lib/docker/etc-hosts",
		"/dev/loop3 100000 100000 0 100% /snap/core/1",
		"/dev/sdb1 200000000 1000 199999000 1% /data",
	}
	if got = disksFrom(linux); len(got) != 2 || got[1]["mount"] != "/data" {
		t.Fatalf("%v", got)
	}
}
