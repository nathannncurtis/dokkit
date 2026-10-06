//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAFolderClosedToOtherAccountsIsSaid(t *testing.T) {
	closed := filepath.Join(t.TempDir(), "private")
	os.Mkdir(closed, 0o700)
	os.Chmod(closed, 0o700)
	if othersCannotRead(closed) == "" {
		t.Fatal("a 0700 folder is closed to the dokkit user")
	}
	if othersCannotRead("/") != "" {
		t.Fatal("the root folder is open")
	}
}
