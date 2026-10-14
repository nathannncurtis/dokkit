package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCPUPercentIsTheShareOfTheWholeMachineSinceTheLastLook(t *testing.T) {
	var s procSampler
	rows := func(a, b uint64) []procRow {
		return []procRow{{pid: 10, name: "a", start: 1, cpu: a}, {pid: 11, name: "b", start: 5, cpu: b}}
	}
	first := s.build("t", rows(100, 100), 1000, 1<<30)
	if first.Items[0].CPU != nil {
		t.Fatal("the first look has nothing to compare with")
	}
	second := s.build("t", rows(150, 100), 1400, 1<<30)
	if got := *second.Items[0].CPU; got != 12.5 {
		t.Fatalf("cpu_percent = %v, want 12.5", got)
	}
	if got := *second.Items[1].CPU; got != 0 {
		t.Fatalf("cpu_percent = %v, want 0", got)
	}
}

func TestAReusedPidWithAnotherStartHasNoCPUPercent(t *testing.T) {
	var s procSampler
	s.build("t", []procRow{{pid: 10, start: 1, cpu: 900}}, 1000, 0)
	l := s.build("t", []procRow{{pid: 10, start: 2, cpu: 5}}, 2000, 0)
	if l.Items[0].CPU != nil {
		t.Fatalf("got %v for a different process", *l.Items[0].CPU)
	}
	l = s.build("t", []procRow{{pid: 10, start: 2, cpu: 1}}, 3000, 0)
	if l.Items[0].CPU != nil {
		t.Fatal("time that went backwards must not give a number")
	}
}

func TestTheProcessesLineHasTheAgreedShape(t *testing.T) {
	var s procSampler
	session := 0
	l := s.build("2026-01-01T00:00:00Z", []procRow{{pid: 4120, ppid: 812, name: "sqlservr.exe", path: `C:\x\sqlservr.exe`, memory: 99, session: &session}}, 1, 34359738368)
	b := l.fit()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	item := m["items"].([]any)[0].(map[string]any)
	if m["type"] != "processes" || m["total_memory_bytes"] != 34359738368.0 || item["pid"] != 4120.0 || item["user"] != nil || item["cpu_percent"] != nil || item["session"] != 0.0 || item["memory_bytes"] != 99.0 {
		t.Fatalf("%s", b)
	}
}

func TestAnOversizedLineLosesItsPathsThenAllButTheLargest(t *testing.T) {
	var s procSampler
	long := strings.Repeat("p", 3000)
	var rows []procRow
	for i := range 500 {
		rows = append(rows, procRow{pid: i, name: "n", path: long, memory: uint64(i)})
	}
	b := s.build("t", rows, 1, 1).fit()
	if len(b) > processesMaxBytes || strings.Contains(string(b), "ppp") {
		t.Fatalf("paths kept or too large: %d bytes", len(b))
	}
	var l procLine
	json.Unmarshal(b, &l)
	if len(l.Items) != 500 {
		t.Fatalf("%d items, want all 500 without paths", len(l.Items))
	}
	for i := range 20000 {
		rows = append(rows, procRow{pid: 1000 + i, name: strings.Repeat("n", 100), memory: uint64(1000 + i)})
	}
	b = s.build("t", rows, 1, 1).fit()
	json.Unmarshal(b, &l)
	if len(b) > processesMaxBytes || len(l.Items) != processesKeep || l.Items[0].Memory != 20999 {
		t.Fatalf("%d bytes, %d items", len(b), len(l.Items))
	}
}

func TestTheRealProcessListHasThisProcessInIt(t *testing.T) {
	var s procSampler
	start := time.Now()
	rows, machine, memory, err := readProcesses()
	took := time.Since(start)
	if err != nil {
		t.Fatal(err)
	}
	line := s.build("t", rows, machine, memory)
	b := line.fit()
	t.Logf("%d processes in %s, %d bytes, total memory %d", len(rows), took, len(b), memory)
	if len(rows) <= 20 || memory == 0 {
		t.Fatalf("only %d processes, memory %d", len(rows), memory)
	}
	for _, r := range rows {
		if r.pid == os.Getpid() {
			if r.memory < 1<<20 || r.memory > memory || r.name == "" || r.ppid == 0 {
				t.Fatalf("this process looks wrong: %+v", r)
			}
			return
		}
	}
	t.Fatal("this process is not in the list")
}
