//go:build !windows

package main

import (
	"os"
	"testing"
)

func TestAFolderOthersCanWriteIsRefusedForRoot(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0o777)
	if rootProblem(dir, nil) == nil {
		t.Fatal("a folder others can write is refused")
	}
}
