//go:build !windows && !linux

package main

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// readProcesses runs ps once, without the columns that carry a command line.
func readProcesses() (rows []procRow, machine, memory uint64, err error) {
	b, err := exec.Command("ps", "-axo", "pid=,ppid=,rss=,time=,user=,comm=").Output()
	if err != nil {
		return nil, 0, 0, err
	}
	machine = uint64(time.Now().UnixNano()/1e7) * uint64(runtime.NumCPU())
	if m := output("sysctl", "-n", "hw.memsize"); len(m) > 0 {
		memory, _ = strconv.ParseUint(strings.TrimSpace(m[0]), 10, 64)
	}
	return parsePs(string(b)), machine, memory, nil
}

// parsePs reads the output of ps. Processor time is in hundredths of a second.
func parsePs(out string) (rows []procRow) {
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) < 6 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		rss, e3 := strconv.ParseUint(f[2], 10, 64)
		if e1 != nil || e2 != nil || e3 != nil {
			continue
		}
		comm := afterFields(l, 5)
		r := procRow{pid: pid, ppid: ppid, memory: rss << 10, cpu: psTime(f[3]), user: f[4], name: filepath.Base(comm)}
		if strings.HasPrefix(comm, "/") {
			r.path = comm
		}
		rows = append(rows, r)
	}
	return
}

// afterFields is what is left of l once n whitespace-separated fields are gone.
func afterFields(l string, n int) string {
	for range n {
		l = strings.TrimLeft(l, " 	")
		l = l[strings.IndexAny(l+" ", " 	"):]
	}
	return strings.TrimSpace(l)
}

// psTime reads [dd-][hh:]mm:ss.ss into hundredths of a second.
func psTime(s string) uint64 {
	var days float64
	if d, rest, ok := strings.Cut(s, "-"); ok {
		days, _ = strconv.ParseFloat(d, 64)
		s = rest
	}
	var secs float64
	for _, p := range strings.Split(s, ":") {
		n, _ := strconv.ParseFloat(p, 64)
		secs = secs*60 + n
	}
	return uint64((days*86400+secs)*100 + 0.5)
}
