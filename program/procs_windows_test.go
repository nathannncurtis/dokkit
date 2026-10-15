package main

import (
	"strings"
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
		old, via := openedImagePath(pid), processPath(pid)
		if old == "" && via != "" && !strings.HasPrefix(via, `\Device\`) {
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

func openedImagePath(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, 32768)
	n := uint32(len(buf))
	if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) != nil {
		return ""
	}
	return windows.UTF16ToString(buf[:n])
}
