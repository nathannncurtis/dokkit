package main

import (
	"os"
	"strings"
	"testing"
)

func TestAFolderOwnedByAnyoneElseIsRefused(t *testing.T) {
	err := trustedOwner(os.Getenv("SystemRoot"))
	if err == nil || !strings.Contains(err.Error(), "owned by") {
		t.Fatalf("Windows is owned by its installer, not by administrators: %v", err)
	}
}
