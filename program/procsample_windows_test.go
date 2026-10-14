package main

import (
	"encoding/binary"
	"os"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func fakeEntry(b []byte, o, next, pid, ppid, session int, private, working, create, user, kernel uint64, name string) {
	binary.LittleEndian.PutUint32(b[o+spiNext:], uint32(next))
	binary.LittleEndian.PutUint64(b[o+spiPrivateWS:], private)
	binary.LittleEndian.PutUint64(b[o+spiCreateTime:], create)
	binary.LittleEndian.PutUint64(b[o+spiUserTime:], user)
	binary.LittleEndian.PutUint64(b[o+spiKernelTime:], kernel)
	binary.LittleEndian.PutUint64(b[o+spiPid:], uint64(pid))
	binary.LittleEndian.PutUint64(b[o+spiPpid:], uint64(ppid))
	binary.LittleEndian.PutUint32(b[o+spiSession:], uint32(session))
	binary.LittleEndian.PutUint64(b[o+spiWorkingSet:], working)
	if name != "" {
		u, _ := windows.UTF16FromString(name)
		at := o + spiMinimum + 16
		for i, c := range u[:len(u)-1] {
			binary.LittleEndian.PutUint16(b[at+2*i:], c)
		}
		binary.LittleEndian.PutUint16(b[o+spiImageName:], uint16(2*(len(u)-1)))
		binary.LittleEndian.PutUint16(b[o+spiImageName+2:], uint16(2*len(u)))
		binary.LittleEndian.PutUint64(b[o+spiImageName+8:], uint64(uintptr(unsafe.Pointer(&b[at]))))
	}
}

func fakeList() []byte {
	b := make([]byte, 3*256)
	fakeEntry(b, 0, 256, 0, 0, 0, 0, 8192, 0, 0, 5000, "")
	fakeEntry(b, 256, 256, 4120, 812, 0, 30<<30, 31<<30, 77, 300, 200, "sqlservr.exe")
	fakeEntry(b, 512, 0, 9000, 4120, 2, 0, 1<<20, 88, 1, 2, "ünï.exe")
	return b
}

func TestAProcessListBufferIsWalkedByNextEntryOffset(t *testing.T) {
	rows := parseProcesses(fakeList())
	if len(rows) != 3 {
		t.Fatalf("%d rows", len(rows))
	}
	sql := rows[1]
	if sql.pid != 4120 || sql.ppid != 812 || sql.name != "sqlservr.exe" || sql.memory != 30<<30 || *sql.session != 0 || sql.cpu != 500 || sql.start != 77 {
		t.Fatalf("%+v", sql)
	}
	if rows[0].name != "System Idle Process" || rows[0].memory != 8192 {
		t.Fatalf("%+v", rows[0])
	}
	if r := rows[2]; r.name != "ünï.exe" || *r.session != 2 || r.memory != 1<<20 || r.cpu != 3 {
		t.Fatalf("a missing private working set falls back to the working set: %+v", r)
	}
}

func TestTheBufferDoublesWhileTheSystemSaysItIsTooSmall(t *testing.T) {
	oldCall, oldBuf := querySystem, processBuf
	defer func() { querySystem, processBuf = oldCall, oldBuf }()
	processBuf = make([]byte, 100)
	var sizes []int
	querySystem = func(class int32, info unsafe.Pointer, size uint32, ret *uint32) error {
		sizes = append(sizes, int(size))
		if size < 1000 {
			*ret = 0
			return windows.STATUS_INFO_LENGTH_MISMATCH
		}
		*ret = 777
		return nil
	}
	n, err := queryProcesses()
	if err != nil || n != 777 || len(sizes) != 5 || sizes[1] != 200 || sizes[4] != 1600 || len(processBuf) != 1600 {
		t.Fatalf("n=%d err=%v sizes=%v", n, err, sizes)
	}
	sizes = nil
	if _, err = queryProcesses(); err != nil || len(sizes) != 1 {
		t.Fatalf("the grown buffer is kept: %v %v", err, sizes)
	}
}

func TestNTPathsBecomeDriveLetterPaths(t *testing.T) {
	builds := 0
	d := &driveMap{build: func() map[string]string {
		builds++
		return map[string]string{`\device\harddiskvolume3`: "C:"}
	}}
	d.refresh()
	if got := d.dos(`\Device\HarddiskVolume3\Program Files\x\a.exe`); got != `C:\Program Files\x\a.exe` {
		t.Fatal(got)
	}
	unknown := `\Device\Mup\server\share\b.exe`
	if got := d.dos(unknown); got != unknown || builds != 2 {
		t.Fatalf("%q after %d builds", got, builds)
	}
	d.dos(unknown)
	if builds != 2 {
		t.Fatal("a look rebuilds the map once for a miss")
	}
}

func TestARealPathHasADriveLetter(t *testing.T) {
	rows, _, _, err := readProcesses()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.pid == os.Getpid() {
			t.Logf("own path: %s", r.path)
			if len(r.path) < 3 || r.path[1] != ':' {
				t.Fatal(r.path)
			}
			return
		}
	}
	t.Fatal("not found")
}
