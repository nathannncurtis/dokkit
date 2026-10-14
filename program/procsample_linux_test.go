package main

import (
	"os"
	"path/filepath"
	"testing"
)

const statWithAwkwardName = "812 (my (odd) name) S 1 812 812 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 3 0 99999 1000000 500 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n"

func TestStatIsReadFromTheLastClosingBracket(t *testing.T) {
	r, ok := parseProcStat([]byte(statWithAwkwardName))
	if !ok || r.name != "my (odd) name" || r.ppid != 1 || r.cpu != 300 || r.start != 99999 {
		t.Fatalf("%+v %v", r, ok)
	}
	if _, ok := parseProcStat([]byte("812 (short) S 1")); ok {
		t.Fatal("a short line is not a process")
	}
}

func TestStatmStatusPasswdAndMeminfoAreRead(t *testing.T) {
	if got := parseStatm([]byte("5000 321 10 1 0 100 0\n"), 4096); got != 321*4096 {
		t.Fatalf("statm %d", got)
	}
	uid, ok := parseUid([]byte("Name:\tx\nUid:\t1001\t1001\t1001\t1001\nGid:\t5\t5\t5\t5\n"))
	if !ok || uid != 1001 {
		t.Fatalf("uid %d %v", uid, ok)
	}
	names := parsePasswd([]byte("root:x:0:0:root:/root:/bin/bash\nnathan:x:1001:1001::/home/n:/bin/sh\nother:x:1001:1::/:/bin/sh\n"))
	if names[0] != "root" || names[1001] != "nathan" {
		t.Fatalf("%v", names)
	}
	if got := parseMemTotal([]byte("MemTotal:       16384 kB\nMemFree: 1 kB\n")); got != 16384<<10 {
		t.Fatalf("meminfo %d", got)
	}
}

func TestProcStatTotalsAreSummed(t *testing.T) {
	idle, total, ok := parseCPULine("cpu  100 20 30 400 50 0 0 0 0 0\ncpu0 1 1 1 1 1 1\n")
	if !ok || idle != 450 || total != 600 {
		t.Fatalf("%d %d %v", idle, total, ok)
	}
}

func TestAFakeProcFolderIsRead(t *testing.T) {
	root := t.TempDir()
	old := procRoot
	procRoot = root
	defer func() { procRoot = old }()
	dir := filepath.Join(root, "812")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "stat"), []byte(statWithAwkwardName), 0o644)
	os.WriteFile(filepath.Join(dir, "comm"), []byte("my (odd) name\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "statm"), []byte("5000 2 0\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "status"), []byte("Uid:\t0\t0\t0\t0\n"), 0o644)
	os.MkdirAll(filepath.Join(root, "self"), 0o755)
	rows, _, _, err := readProcesses()
	if err != nil || len(rows) != 1 {
		t.Fatalf("%v %v", rows, err)
	}
	if r := rows[0]; r.pid != 812 || r.name != "my (odd) name" || r.memory != 2*uint64(os.Getpagesize()) || r.path != "" {
		t.Fatalf("%+v", r)
	}
}
