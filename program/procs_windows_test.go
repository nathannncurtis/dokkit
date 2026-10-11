package main

import (
	"testing"

	"golang.org/x/sys/windows"
)

func TestAnotherAccountsProcessPathIsGivenWithoutOpeningIt(t *testing.T) {
	if windows.GetCurrentProcessToken().IsElevated() {
		t.Skip("an elevated process can open them all")
	}
	var shown int
	eachProcess(func(pid uint32, name string) {
		if pid == 0 || pid == 4 {
			return
		}
		old, via := handleImagePath(pid), imagePath(pid)
		if old == "" && via != "" {
			shown++
			if shown <= 5 {
				t.Logf("%s pid %d: QueryFullProcessImageName refused, handle-free %q", name, pid, via)
			}
		}
	})
	if shown == 0 {
		t.Fatal("no process had a path from the handle-free call that the handle call refused")
	}
}
