package main

import (
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

// mdstatPath is where Linux lists its md arrays. Tests point it at a file of their own.
var mdstatPath = "/proc/mdstat"

// arrays reports md arrays, ZFS pools and each drive's own verdict: states only, nothing needs rights.
func arrays(f *hwFound, onQNAP bool) {
	if runtime.GOOS == "linux" {
		text := readText(mdstatPath)
		if text == "" {
			f.say("md arrays: no %s", mdstatPath)
		} else {
			s := parseMdstat(text, onQNAP)
			f.states = append(f.states, s...)
			f.say("md arrays: %d", len(s))
		}
	} else {
		f.say("md arrays: not Linux")
	}
	if onQNAP {
		qnapVerdicts(f)
	}
	if runtime.GOOS == "darwin" {
		diskutilSmart(f)
	} else {
		f.say("diskutil: not macOS")
	}
	if runtime.GOOS == "windows" {
		f.say("zpool: not on Windows")
	} else {
		zfsPools(f)
	}
}

var (
	mdHead     = regexp.MustCompile(`^(md\d+)\s*:\s*(\S+)`)
	mdSlots    = regexp.MustCompile(`\[(\d+)/(\d+)\]`)
	mdProgress = regexp.MustCompile(`\b(recovery|resync|reshape|check|repair)\s*=\s*(\d+(?:\.\d+)?%|DELAYED|PENDING)`)
	// QNAP's own system arrays have 128 slots and always look short of drives.
	qnapInternal = regexp.MustCompile(`^md(9|13|256|32\d)$`)
)

// parseMdstat: an array short of drives is down, one rebuilding or resyncing is degraded with its
// progress, and a scheduled check is fine.
func parseMdstat(text string, onQNAP bool) []hwState {
	var out []hwState
	var cur *hwState
	var want, have int
	finish := func() {
		if cur == nil {
			return
		}
		if cur.state == "" {
			cur.state = "ok"
			if have < want {
				cur.state, cur.note = "down", fmt.Sprintf("%d of %d drives missing", want-have, want)
			}
		}
		out = append(out, *cur)
		cur = nil
	}
	for _, line := range strings.Split(text, "\n") {
		if m := mdHead.FindStringSubmatch(line); m != nil {
			finish()
			want, have = 0, 0
			if onQNAP && qnapInternal.MatchString(m[1]) {
				continue
			}
			cur = &hwState{check: "hw.array." + m[1]}
			if m[2] == "inactive" {
				cur.state, cur.note = "down", "Not running"
			}
			continue
		}
		if cur == nil || cur.state != "" {
			continue
		}
		if m := mdSlots.FindStringSubmatch(line); m != nil {
			want, _ = strconv.Atoi(m[1])
			have, _ = strconv.Atoi(m[2])
		}
		if m := mdProgress.FindStringSubmatch(line); m != nil {
			switch m[1] {
			case "check":
				cur.note = "Checking, " + m[2] + " done"
			case "repair":
				cur.note = "Repairing, " + m[2] + " done"
			default:
				word := map[string]string{"recovery": "Rebuilding", "resync": "Resyncing", "reshape": "Reshaping"}[m[1]]
				cur.state, cur.note = "degraded", word+", "+progress(m[2])
			}
		}
	}
	finish()
	return out
}

func progress(p string) string {
	if strings.HasSuffix(p, "%") {
		return p + " done"
	}
	return "waiting to start"
}

// verdict turns a drive's or volume's own word into a state by the first rule whose word it
// holds; a word no rule knows needs a look.
func verdict(word string, rules [][2]string) (state string, known bool) {
	w := strings.ToLower(strings.TrimSpace(word))
	if strings.Trim(w, "-") == "" {
		return "", false
	}
	for _, r := range rules {
		if strings.Contains(w, r[0]) {
			return r[1], true
		}
	}
	return "degraded", true
}

var (
	volumeRules = [][2]string{{"rebuild", "degraded"}, {"sync", "degraded"}, {"migrat", "degraded"}, {"expand", "degraded"},
		{"degrad", "down"}, {"fail", "down"}, {"error", "down"}, {"not active", "down"}, {"inactive", "down"}, {"unmount", "down"}, {"crash", "down"},
		{"ready", "ok"}, {"scrub", "ok"}, {"check", "ok"}}
	driveRules = [][2]string{{"abnormal", "down"}, {"bad", "down"}, {"fail", "down"}, {"error", "down"}, {"warn", "degraded"}, {"good", "ok"}, {"normal", "ok"}}
	smartRules = [][2]string{{"fail", "down"}, {"verified", "ok"}}
)

func firstLineOut(b []byte) string { return strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0]) }

// qnapVerdicts reads each volume's status and each drive's SMART verdict from getsysinfo.
func qnapVerdicts(f *hwFound) {
	tool := qnapTool()
	get := func(args ...string) string {
		out, err := runCmd(tool, args...)
		if err != nil {
			return ""
		}
		return firstLineOut(out)
	}
	vols, _ := firstNum([]byte(get("sysvolnum")))
	for i := 1; i <= int(vols) && i <= 64; i++ {
		word := get("vol_status", strconv.Itoa(i))
		if s, ok := verdict(word, volumeRules); ok {
			f.states = append(f.states, hwState{fmt.Sprintf("hw.array.vol%d", i), s, noteUnlessOK(s, "The NAS says the volume is "+word)})
		}
	}
	disks, _ := firstNum([]byte(get("hdnum")))
	for i := 1; i <= int(disks) && i <= 64; i++ {
		word := get("hdsmart", strconv.Itoa(i))
		if s, ok := verdict(word, driveRules); ok {
			f.states = append(f.states, hwState{fmt.Sprintf("hw.smart.hd%d", i), s, noteUnlessOK(s, "The NAS says the drive is "+word)})
		}
	}
	f.say("QNAP volumes and drive verdicts: %d volume(s), %d drive(s)", int(vols), int(disks))
}

func noteUnlessOK(state, note string) string {
	if state == "ok" {
		return ""
	}
	return note
}

func diskutilSmart(f *hwFound) {
	out, err := runCmd("diskutil", "info", "-all")
	if err != nil {
		f.say("diskutil: %v", err)
		return
	}
	s := parseDiskutil(string(out))
	f.states = append(f.states, s...)
	f.say("diskutil: SMART status for %d drive(s)", len(s))
}

// parseDiskutil reads "SMART Status" for each whole, physical disk in diskutil info -all.
func parseDiskutil(text string) []hwState {
	var out []hwState
	for _, block := range strings.Split(text, "**********") {
		field := map[string]string{}
		for _, line := range strings.Split(block, "\n") {
			if k, v, ok := strings.Cut(line, ":"); ok {
				field[strings.TrimSpace(k)] = strings.TrimSpace(v)
			}
		}
		dev, smart := field["Device Identifier"], field["SMART Status"]
		if dev == "" || field["Whole"] != "Yes" || field["Virtual"] == "Yes" || strings.EqualFold(smart, "Not Supported") {
			continue
		}
		if s, ok := verdict(smart, smartRules); ok {
			out = append(out, hwState{"hw.smart." + label(dev), s, noteUnlessOK(s, "SMART status: "+smart)})
		}
	}
	return out
}

func zfsPools(f *hwFound) {
	out, err := runCmd("zpool", "list", "-H", "-o", "name,health")
	switch {
	case errors.Is(err, exec.ErrNotFound):
		f.say("zpool: not found")
		return
	case err != nil:
		f.say("zpool: %v", err)
		return
	}
	status := ""
	for _, line := range strings.Split(string(out), "\n") {
		if _, h, ok := strings.Cut(strings.TrimSpace(line), "\t"); ok && strings.TrimSpace(h) != "ONLINE" {
			if b, err := runCmd("zpool", "status", "-x"); err == nil {
				status = string(b)
			}
			break
		}
	}
	s := parseZpool(string(out), status)
	f.states = append(f.states, s...)
	f.say("zpool: %d pool(s)", len(s))
}

var zpoolScan = regexp.MustCompile(`(\d+(?:\.\d+)?%) done`)

// parseZpool: a pool that lost a device is down unless it is resilvering, which is degraded.
func parseZpool(list, status string) []hwState {
	resilver := map[string]string{}
	pool := ""
	for _, line := range strings.Split(status, "\n") {
		t := strings.TrimSpace(line)
		if p, ok := strings.CutPrefix(t, "pool:"); ok {
			pool = strings.TrimSpace(p)
		}
		if strings.Contains(t, "resilver in progress") {
			resilver[pool] = "in progress"
		}
		if m := zpoolScan.FindStringSubmatch(t); m != nil && resilver[pool] != "" {
			resilver[pool] = m[1] + " done"
		}
	}
	var out []hwState
	for _, line := range strings.Split(list, "\n") {
		name, health, ok := strings.Cut(strings.TrimSpace(line), "\t")
		if !ok || label(name) == "" {
			continue
		}
		s := hwState{check: "hw.array." + label(name), state: "ok"}
		switch health = strings.TrimSpace(health); {
		case health == "ONLINE":
		case resilver[name] != "":
			s.state, s.note = "degraded", "Resilvering, "+resilver[name]
		default:
			s.state, s.note = "down", "The ZFS pool is "+health
		}
		out = append(out, s)
	}
	return out
}
