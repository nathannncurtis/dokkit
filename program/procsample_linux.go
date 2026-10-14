package main

import (
	"os"
	"strconv"
	"strings"
)

var procRoot = "/proc"

// readProcesses reads stat, statm, status, comm and exe of each process, and the totals in /proc/stat and /proc/meminfo. Never a command line.
func readProcesses() (rows []procRow, machine, memory uint64, err error) {
	dirs, err := os.ReadDir(procRoot)
	if err != nil {
		return nil, 0, 0, err
	}
	var names map[int]string
	page := uint64(os.Getpagesize())
	for _, d := range dirs {
		pid, err := strconv.Atoi(d.Name())
		if err != nil {
			continue
		}
		dir := procRoot + "/" + d.Name() + "/"
		b, err := os.ReadFile(dir + "stat")
		if err != nil {
			continue
		}
		r, ok := parseProcStat(b)
		if !ok {
			continue
		}
		r.pid = pid
		if c, err := os.ReadFile(dir + "comm"); err == nil && len(c) > 1 {
			r.name = strings.TrimSuffix(string(c), "\n")
		}
		if m, err := os.ReadFile(dir + "statm"); err == nil {
			r.memory = parseStatm(m, page)
		}
		if s, err := os.ReadFile(dir + "status"); err == nil {
			if uid, ok := parseUid(s); ok {
				if names == nil {
					p, _ := os.ReadFile("/etc/passwd")
					names = parsePasswd(p)
				}
				r.user = names[uid]
				if r.user == "" {
					r.user = strconv.Itoa(uid)
				}
			}
		}
		r.path, _ = os.Readlink(dir + "exe")
		rows = append(rows, r)
	}
	_, machine, _ = cpuTimes()
	if b, err := os.ReadFile(procRoot + "/meminfo"); err == nil {
		memory = parseMemTotal(b)
	}
	return rows, machine, memory, nil
}

// parseProcStat reads the name, parent, processor time and start of a process from its stat line. The name sits in brackets and may hold spaces and brackets, so the fields are counted from the last closing one.
func parseProcStat(b []byte) (r procRow, ok bool) {
	s := string(b)
	open, end := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || end < open {
		return r, false
	}
	f := strings.Fields(s[end+1:])
	if len(f) < 20 {
		return r, false
	}
	num := func(i int) uint64 { n, _ := strconv.ParseUint(f[i], 10, 64); return n }
	r.name = s[open+1 : end]
	r.ppid = int(num(1))
	r.cpu = num(11) + num(12)
	r.start = num(19)
	return r, true
}

// parseStatm is the resident set in bytes: the second number of statm is pages.
func parseStatm(b []byte, page uint64) uint64 {
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return 0
	}
	n, _ := strconv.ParseUint(f[1], 10, 64)
	return n * page
}

// parseUid is the real user id on the Uid line of status.
func parseUid(b []byte) (int, bool) {
	for _, l := range strings.Split(string(b), "\n") {
		if rest, ok := strings.CutPrefix(l, "Uid:"); ok {
			if f := strings.Fields(rest); len(f) > 0 {
				n, err := strconv.Atoi(f[0])
				return n, err == nil
			}
		}
	}
	return 0, false
}

func parsePasswd(b []byte) map[int]string {
	m := map[int]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Split(l, ":"); len(f) >= 3 {
			if n, err := strconv.Atoi(f[2]); err == nil {
				if _, seen := m[n]; !seen {
					m[n] = f[0]
				}
			}
		}
	}
	return m
}

func parseMemTotal(b []byte) uint64 {
	for _, l := range strings.Split(string(b), "\n") {
		if rest, ok := strings.CutPrefix(l, "MemTotal:"); ok {
			if f := strings.Fields(rest); len(f) > 0 {
				n, _ := strconv.ParseUint(f[0], 10, 64)
				return n << 10
			}
		}
	}
	return 0
}
