package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAFolderOwnedByAnyoneElseIsRefused(t *testing.T) {
	err := trustedOwner(os.Getenv("SystemRoot"))
	if err == nil || !strings.Contains(err.Error(), "owned by") {
		t.Fatalf("Windows is owned by its installer, not by administrators: %v", err)
	}
}

func TestAFolderOthersCanWriteIsRefused(t *testing.T) {
	if writableByOthers(t.TempDir()) == nil {
		t.Fatal("a folder the signed-in account can write is not one only administrators can write")
	}
	if err := writableByOthers(filepath.Join(os.Getenv("SystemRoot"), "System32")); err != nil {
		t.Fatalf("System32 is writable only by administrators: %v", err)
	}
}
