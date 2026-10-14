package main

import (
	"encoding/json"
	"math"
	"sort"
	"time"
)

const (
	processesMaxBytes = 1 << 20
	processesKeep     = 300
	processesTimeout  = 5 * time.Second
)

// procRow is one process as a platform reads it. cpu and machine are in the same unit; start tells a reused pid from the old one.
type procRow struct {
	pid, ppid int
	name      string
	path      string
	memory    uint64
	cpu       uint64
	start     uint64
	session   *int
	user      string
}

type procKey struct {
	pid   int
	start uint64
}

type procItem struct {
	Pid     int      `json:"pid"`
	Ppid    int      `json:"ppid"`
	Name    string   `json:"name"`
	Path    *string  `json:"path"`
	Memory  uint64   `json:"memory_bytes"`
	CPU     *float64 `json:"cpu_percent"`
	Session *int     `json:"session"`
	User    *string  `json:"user"`
}

type procLine struct {
	Type        string     `json:"type"`
	At          string     `json:"at"`
	TotalMemory uint64     `json:"total_memory_bytes"`
	Items       []procItem `json:"items"`
}

// procSampler keeps the previous look's processor times, so each look can say who used what since.
type procSampler struct {
	prev, next map[procKey]uint64
	machine    uint64
	items      []procItem
}

// build makes the line for rows read at at, and remembers their times for the next look.
func (s *procSampler) build(at string, rows []procRow, machine, totalMemory uint64) procLine {
	if s.next == nil {
		s.next = map[procKey]uint64{}
	}
	clear(s.next)
	s.items = s.items[:0]
	span := float64(machine) - float64(s.machine)
	for _, r := range rows {
		it := procItem{Pid: r.pid, Ppid: r.ppid, Name: r.name, Memory: r.memory, Session: r.session}
		if r.path != "" {
			it.Path = &r.path
		}
		if r.user != "" {
			it.User = &r.user
		}
		k := procKey{r.pid, r.start}
		s.next[k] = r.cpu
		if before, ok := s.prev[k]; ok && r.cpu >= before && s.machine != 0 && span > 0 {
			p := math.Min(100, math.Round(10000*float64(r.cpu-before)/span)/100)
			it.CPU = &p
		}
		s.items = append(s.items, it)
	}
	s.prev, s.next = s.next, s.prev
	s.machine = machine
	return procLine{"processes", at, totalMemory, s.items}
}

// fit is the line as bytes, kept under 1 MB: first without the paths, then with only the largest by memory.
func (l procLine) fit() json.RawMessage {
	b, _ := json.Marshal(l)
	if len(b) <= processesMaxBytes {
		return b
	}
	items := make([]procItem, len(l.Items))
	copy(items, l.Items)
	for i := range items {
		items[i].Path = nil
	}
	l.Items = items
	if b, _ = json.Marshal(l); len(b) <= processesMaxBytes {
		return b
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Memory > items[j].Memory })
	l.Items = items[:min(len(items), processesKeep)]
	b, _ = json.Marshal(l)
	return b
}

var processSampler procSampler

// sampleProcesses is the processes line for now, or nil when the system would not list them.
func sampleProcesses() any {
	rows, machine, memory, err := readProcesses()
	if err != nil {
		return nil
	}
	return processSampler.build(now(), rows, machine, memory).fit()
}

// processesSoon samples on its own goroutine, so a slow look holds no check back; a look over 5 seconds is not sent.
func (w *watcher) processesSoon() {
	if !w.procsBusy.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer w.procsBusy.Store(false)
		start := time.Now()
		if line := sampleProcesses(); line != nil && time.Since(start) < processesTimeout {
			w.c.report(line)
			w.statsReady.Store(true)
		}
	}()
}
