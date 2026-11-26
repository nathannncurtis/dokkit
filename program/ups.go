package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// NUT's own port, on this machine only: a UPS is read where it is plugged in.
var nutAddrs = []string{"127.0.0.1:3493", "[::1]:3493"}

// ups reads the UPS this machine is plugged into, from whatever this system offers.
func ups(f *hwFound) {
	switch runtime.GOOS {
	case "windows":
		batteryUPS(f)
	case "darwin":
		out, err := runCmd("pmset", "-g", "batt")
		if err != nil {
			f.say("UPS: pmset: %v", err)
			return
		}
		parsePmsetBatt(string(out), f)
	default:
		nutUPS(f)
	}
}

func (f *hwFound) value(check string, v float64) {
	if f.values == nil {
		f.values = map[string]float64{}
	}
	f.values[check] = v
}

func upsStates(f *hwFound, onBattery bool, charge float64, hasCharge bool, troubles []string) {
	power := hwState{check: "hw.ups.power", state: "ok"}
	if onBattery {
		power.state, power.note = "down", "On battery"
	}
	battery := hwState{check: "hw.ups.battery", state: "ok"}
	if len(troubles) > 0 {
		battery.state, battery.note = "degraded", strings.Join(troubles, ". ")
	}
	if hasCharge {
		f.value(power.check, charge)
		f.value(battery.check, charge)
	}
	f.states = append(f.states, power, battery)
}

var nutName = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

func nutUPS(f *hwFound) {
	var conn net.Conn
	var err error
	for _, a := range nutAddrs {
		if conn, err = net.DialTimeout("tcp", a, time.Second); err == nil {
			break
		}
	}
	if err != nil {
		f.say("UPS: NUT is not answering on this machine (port 3493)")
		return
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	r := bufio.NewReader(conn)
	list := func(cmd string) ([]string, error) {
		if _, err := fmt.Fprintf(conn, "%s\n", cmd); err != nil {
			return nil, err
		}
		var out []string
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return nil, err
			}
			line = strings.TrimRight(line, "\r\n")
			switch {
			case strings.HasPrefix(line, "ERR "):
				return nil, errors.New(line)
			case strings.HasPrefix(line, "END "):
				return out, nil
			case !strings.HasPrefix(line, "BEGIN "):
				out = append(out, line)
			}
		}
	}
	lines, err := list("LIST UPS")
	if err != nil {
		f.say("UPS: NUT: %v", err)
		return
	}
	var names []string
	for _, l := range lines {
		if fs := strings.Fields(l); len(fs) >= 2 && fs[0] == "UPS" && nutName.MatchString(fs[1]) {
			names = append(names, fs[1])
		}
	}
	if len(names) == 0 {
		f.say("UPS: NUT has no UPS")
		return
	}
	sort.Strings(names)
	// shortcut: only the first UPS NUT lists is read; read each once a machine with two exists.
	name := names[0]
	lines, err = list("LIST VAR " + name)
	fmt.Fprintf(conn, "LOGOUT\n")
	if err != nil {
		f.say("UPS: NUT %s: %v", name, err)
		return
	}
	vars := map[string]string{}
	for _, l := range lines {
		rest, ok := strings.CutPrefix(l, "VAR "+name+" ")
		if !ok {
			continue
		}
		key, quoted, _ := strings.Cut(rest, " ")
		if v, err := strconv.Unquote(quoted); err == nil {
			vars[key] = v
		}
	}
	upsFromNut(vars, f)
	f.say("UPS: NUT %s (%d listed)", name, len(names))
}

func upsFromNut(vars map[string]string, f *hwFound) {
	num := func(key string) (float64, bool) {
		v, err := strconv.ParseFloat(strings.TrimSpace(vars[key]), 64)
		return v, err == nil && !math.IsNaN(v)
	}
	charge, hasCharge := num("battery.charge")
	if hasCharge {
		f.add("ups.charge_percent", charge, 0)
	}
	if v, ok := num("battery.runtime"); ok {
		f.add("ups.runtime_minutes", v/60, 0)
	}
	if v, ok := num("ups.load"); ok {
		f.add("ups.load_percent", v, 0)
	}
	if v, ok := num("input.voltage"); ok {
		f.add("ups.input_v", v, 0)
	}
	status := map[string]bool{}
	for _, s := range strings.Fields(vars["ups.status"]) {
		status[s] = true
	}
	if !status["OL"] && !status["OB"] {
		return
	}
	var troubles []string
	if status["LB"] {
		troubles = append(troubles, "The UPS says its battery is low")
	}
	if status["RB"] {
		troubles = append(troubles, "The UPS says its battery needs replacing")
	}
	if t := strings.ToLower(vars["ups.test.result"]); strings.Contains(t, "fail") || strings.Contains(t, "error") {
		troubles = append(troubles, "The UPS failed its self-test: "+vars["ups.test.result"])
	}
	upsStates(f, status["OB"], charge, hasCharge, troubles)
}

var pmsetUPS = regexp.MustCompile(`^\s*-(.+?)\s+\(id=\d+\)\s+(\d+)%;\s*([^;]+);\s*(?:(\d+):(\d+) remaining)?`)

// parsePmsetBatt reads a UPS from pmset -g batt. A laptop's own battery is not a UPS.
func parsePmsetBatt(out string, f *hwFound) {
	onUPS := strings.Contains(out, "'UPS Power'")
	for _, line := range strings.Split(out, "\n") {
		m := pmsetUPS.FindStringSubmatch(line)
		if m == nil || strings.HasPrefix(m[1], "InternalBattery") {
			continue
		}
		charge, _ := strconv.ParseFloat(m[2], 64)
		f.add("ups.charge_percent", charge, 0)
		if m[4] != "" {
			h, _ := strconv.Atoi(m[4])
			min, _ := strconv.Atoi(m[5])
			f.add("ups.runtime_minutes", float64(h*60+min), 0)
		}
		upsStates(f, onUPS || strings.TrimSpace(m[3]) == "discharging", charge, true, nil)
		f.say("UPS: %s, from pmset", m[1])
		return
	}
	f.say("UPS: none in pmset -g batt")
}

// Battery-class values Windows gives for each battery it knows.
const (
	batteryShortTerm   = 0x20000000
	batteryOnLine      = 0x1
	batteryDischarging = 0x2
	batteryCritical    = 0x8
	batteryUnknown     = 0xFFFFFFFF
)

type winBattery struct {
	caps, state, capacity, full, seconds uint32
}

// upsFromBatteries takes the first battery Windows marks as short-term, which is how it marks a
// UPS; a laptop's own battery is not one.
func upsFromBatteries(all []winBattery, f *hwFound) {
	for _, b := range all {
		if b.caps&batteryShortTerm == 0 {
			continue
		}
		charge, hasCharge := 0.0, b.full > 0 && b.full != batteryUnknown && b.capacity != batteryUnknown
		if hasCharge {
			charge = math.Min(100, 100*float64(b.capacity)/float64(b.full))
			f.add("ups.charge_percent", charge, 0)
		}
		if b.seconds != batteryUnknown {
			f.add("ups.runtime_minutes", float64(b.seconds)/60, 0)
		}
		var troubles []string
		if b.state&batteryCritical != 0 {
			troubles = append(troubles, "The UPS says its battery is low")
		}
		upsStates(f, b.state&batteryOnLine == 0 && b.state&batteryDischarging != 0, charge, hasCharge, troubles)
		f.say("UPS: from the Windows battery class, %d batteries", len(all))
		return
	}
	f.say("UPS: none among %d Windows batteries (a laptop's own battery is not one)", len(all))
}

// A boot of this machine, and whether the program stopped cleanly before it went down.
type bootMark struct {
	ID         string `json:"id,omitempty"`
	At         int64  `json:"at"`
	Clean      bool   `json:"clean"`
	Unexpected bool   `json:"unexpected"`
}

var (
	restartAt    time.Time
	restartKnown bool
)

func (a bootMark) same(b bootMark) bool {
	if a.ID != "" || b.ID != "" {
		return a.ID == b.ID
	}
	d := a.At - b.At
	// shortcut: a boot is told apart by its start time within five minutes where the system gives no boot id.
	return d < 300 && d > -300
}

var thisBoot = func() (bootMark, bool) {
	up, ok := uptime()
	if !ok {
		return bootMark{}, false
	}
	return bootMark{ID: readText("/proc/sys/kernel/random/boot_id"), At: hwNow().Add(-up).Unix()}, true
}

// noteBoot runs when dokkit watch starts: a new boot after a run that never stopped cleanly is
// a restart without a shutdown, the trace a power cut leaves.
func noteBoot(spool string) {
	now, ok := thisBoot()
	if !ok {
		return
	}
	path := filepath.Join(spool, "boot.json")
	var prev bootMark
	b, err := os.ReadFile(path)
	known := err == nil && json.Unmarshal(b, &prev) == nil
	if known {
		now.Unexpected = prev.Unexpected
		if !prev.same(now) {
			now.Unexpected = !prev.Clean
		}
	}
	saveMark(path, now)
	hwMu.Lock()
	restartKnown, restartAt = known, time.Unix(now.At, 0)
	if !now.Unexpected {
		restartAt = time.Time{}
	}
	hwMu.Unlock()
}

// markClean says the program stopped on purpose, so the next boot is not taken for a power cut.
func markClean(spool string) {
	path := filepath.Join(spool, "boot.json")
	var m bootMark
	if b, err := os.ReadFile(path); err == nil && json.Unmarshal(b, &m) == nil {
		m.Clean = true
		saveMark(path, m)
	}
}

func saveMark(path string, m bootMark) {
	b, _ := json.Marshal(m)
	if err := writeFile(path, b); err != nil {
		fmt.Fprintln(os.Stderr, "dokkit: could not save", path+":", err)
	}
}

func restartState(f *hwFound) {
	hwMu.Lock()
	known, at := restartKnown, restartAt
	hwMu.Unlock()
	switch {
	case !known:
		f.say("restart: known once dokkit watch has run through a boot")
	case at.IsZero():
		f.states = append(f.states, hwState{check: "hw.restart", state: "ok"})
		f.say("restart: the last boot followed a clean stop")
	default:
		f.value("hw.restart", float64(at.Unix()))
		f.states = append(f.states, hwState{check: "hw.restart", state: "degraded", note: "Started " + at.UTC().Format(time.RFC3339) + " after stopping without a shutdown"})
		f.say("restart: started %s after stopping without a shutdown", at.UTC().Format(time.RFC3339))
	}
}
