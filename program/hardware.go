package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// sysRoot is where Linux keeps its sensor files. Tests point it at a folder of their own.
var sysRoot = "/sys"

var hwNow = time.Now

const (
	maxTemps   = 16
	maxFans    = 8
	resendTime = 5 * time.Minute
)

type reading struct {
	name  string
	value float64
	crit  float64
}

type hwState struct{ check, state, note string }

// hwFound is what one look at the hardware found, and what each source said, for dokkit hardware.
type hwFound struct {
	readings []reading
	states   []hwState
	said     []string
}

func (f *hwFound) say(format string, a ...any) { f.said = append(f.said, fmt.Sprintf(format, a...)) }

func (f *hwFound) add(name string, value, crit float64) {
	f.readings = append(f.readings, reading{name, math.Round(value*10) / 10, crit})
}

var (
	hwMu         sync.Mutex
	hwSent       = map[string]sentReading{}
	hwCapSaid    bool
	nvidiaField  string
	throttleLast uint64
	throttleSeen bool
	clockOffset  float64
	clockAt      time.Time
)

type sentReading struct {
	value float64
	at    time.Time
}

// lookHardware asks every source this machine might have, in order.
func lookHardware() *hwFound {
	f := &hwFound{}
	if runtime.GOOS == "darwin" {
		f.say("nvidia-smi: not on macOS")
	} else {
		nvidiaGPUs(f)
	}
	amdGPUs(f)
	hwmon(f)
	thermalZones(f)
	if runtime.GOOS == "linux" {
		qnap(f)
	} else {
		f.say("QNAP getsysinfo: not Linux")
	}
	throttle(f)
	hwMu.Lock()
	if !clockAt.IsZero() && hwNow().Sub(clockAt) < 10*time.Minute {
		f.add("clock.offset_seconds", clockOffset, 0)
		f.say("clock: %.3f seconds ahead of the server", clockOffset)
	} else {
		f.say("clock: measured from the server's answers while dokkit watch runs")
	}
	hwMu.Unlock()
	return f
}

// hardware is the metric and state lines to send this report: capped, and a reading that has
// not moved by its step is sent again only every five minutes.
func (c *client) hardware() []any {
	f := lookHardware()
	return hardwareLines(f, true)
}

func hardwareLines(f *hwFound, changeOnly bool) (lines []any) {
	kept := capReadings(f.readings)
	at := now()
	t := hwNow()
	hwMu.Lock()
	defer hwMu.Unlock()
	for _, r := range kept {
		last, ok := hwSent[r.name]
		if changeOnly && ok && math.Abs(r.value-last.value) < stepFor(r.name) && t.Sub(last.at) < resendTime {
			continue
		}
		if changeOnly {
			hwSent[r.name] = sentReading{r.value, t}
		}
		l := map[string]any{"type": "metric", "at": at, "name": r.name, "value": r.value}
		if r.crit > 0 {
			l["crit"] = r.crit
		}
		lines = append(lines, l)
	}
	for _, s := range f.states {
		l := map[string]any{"type": "state", "at": at, "check": s.check, "state": s.state}
		if s.note != "" {
			l["note"] = s.note
		}
		lines = append(lines, l)
	}
	return
}

func stepFor(name string) float64 {
	if strings.HasSuffix(name, "_rpm") {
		return 50
	}
	return 1
}

// capReadings keeps the first 16 temperatures and 8 fans, the processor and air first.
func capReadings(all []reading) []reading {
	first := map[string]int{"temp.cpu_c": 0, "temp.ambient_c": 2, "temp.system_c": 3, "temp.board_c": 4}
	rank := func(name string) int {
		if n, ok := first[name]; ok {
			return n
		}
		if strings.HasPrefix(name, "temp.cpu.") {
			return 1
		}
		return 5
	}
	sorted := append([]reading(nil), all...)
	sort.SliceStable(sorted, func(i, j int) bool {
		a, b := sorted[i].name, sorted[j].name
		if rank(a) != rank(b) {
			return rank(a) < rank(b)
		}
		return a < b
	})
	var out []reading
	temps, fans, dropped := 0, 0, 0
	for _, r := range sorted {
		switch {
		case strings.HasPrefix(r.name, "temp."):
			if temps++; temps > maxTemps {
				dropped++
				continue
			}
		case strings.HasPrefix(r.name, "fan."):
			if fans++; fans > maxFans {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	if dropped > 0 && !hwCapSaid {
		hwCapSaid = true
		fmt.Fprintf(os.Stderr, "dokkit: this machine has %d temperatures and %d fans; %d are not sent (at most %d and %d)\n", temps, fans, dropped, maxTemps, maxFans)
	}
	return out
}

// noteClock measures this machine's clock against the time the server put in its answer,
// taking the middle of the round trip as the moment the server wrote it.
func noteClock(sent, got time.Time, answer []byte) {
	var a struct {
		ServerMS int64 `json:"server_ms"`
	}
	if json.Unmarshal(answer, &a) != nil || a.ServerMS <= 0 {
		return
	}
	mid := sent.Add(got.Sub(sent) / 2)
	hwMu.Lock()
	clockOffset = float64(mid.UnixMilli()-a.ServerMS) / 1000
	clockAt = got
	hwMu.Unlock()
}

var nvidiaQuery = "index,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,fan.speed,"

func nvidiaGPUs(f *hwFound) {
	run := func(field string) ([]byte, error) {
		return runCmd("nvidia-smi", "--query-gpu="+nvidiaQuery+field, "--format=csv,noheader,nounits")
	}
	fields := []string{"clocks_event_reasons.active", "clocks_throttle_reasons.active"}
	if nvidiaField != "" {
		fields = []string{nvidiaField}
	}
	var out []byte
	var err error
	for _, field := range fields {
		if out, err = run(field); err == nil {
			nvidiaField = field
			break
		}
		if errors.Is(err, exec.ErrNotFound) {
			break
		}
	}
	switch {
	case errors.Is(err, exec.ErrNotFound):
		f.say("nvidia-smi: not found")
		return
	case err != nil:
		f.say("nvidia-smi: %v", err)
		return
	}
	n := parseNvidia(string(out), f)
	f.say("nvidia-smi: %d card(s)", n)
}

// Clock event bits that mean the card is slowing itself for heat or power. 0x1 (idle) and
// 0x4 (the application's power cap) are ordinary.
var gpuBrakes = []struct {
	bit  uint64
	note string
}{{0x20, "slowed by its driver for heat"}, {0x40, "slowed by the card for heat"}, {0x80, "power brake"}}

func parseNvidia(out string, f *hwFound) int {
	cards := 0
	for _, line := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		col := strings.Split(line, ",")
		if len(col) < 8 {
			continue
		}
		for i := range col {
			col[i] = strings.TrimSpace(col[i])
		}
		if _, err := strconv.Atoi(col[0]); err != nil {
			continue
		}
		cards++
		num := func(i int) (float64, bool) {
			v, err := strconv.ParseFloat(col[i], 64)
			return v, err == nil
		}
		g := "gpu." + col[0] + "."
		if v, ok := num(1); ok {
			f.add(g+"temp_c", v, 0)
		}
		if v, ok := num(2); ok {
			f.add(g+"used_percent", v, 0)
		}
		used, ok1 := num(3)
		total, ok2 := num(4)
		if ok1 && ok2 && total > 0 {
			f.add(g+"memory_percent", 100*used/total, 0)
		}
		if v, ok := num(5); ok {
			f.add(g+"power_w", v, 0)
		}
		if v, ok := num(6); ok {
			f.add(g+"fan_percent", v, 0)
		}
		bits, err := strconv.ParseUint(strings.TrimPrefix(strings.ToLower(col[7]), "0x"), 16, 64)
		if err != nil {
			continue
		}
		var notes []string
		for _, b := range gpuBrakes {
			if bits&b.bit != 0 {
				notes = append(notes, b.note)
			}
		}
		state := hwState{check: "hw.gpu." + col[0], state: "ok"}
		if len(notes) > 0 {
			state.state, state.note = "degraded", strings.Join(notes, ", ")
		}
		f.states = append(f.states, state)
	}
	return cards
}

func readNum(path string) (float64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
	return v, err == nil
}

func readText(path string) string {
	b, _ := os.ReadFile(path)
	return strings.TrimSpace(string(b))
}

var cardDir = regexp.MustCompile(`^card(\d+)$`)

func amdGPUs(f *hwFound) {
	dirs, _ := filepath.Glob(filepath.Join(sysRoot, "class", "drm", "card*"))
	cards := 0
	for _, d := range dirs {
		m := cardDir.FindStringSubmatch(filepath.Base(d))
		if m == nil || readText(filepath.Join(d, "device", "vendor")) != "0x1002" {
			continue
		}
		cards++
		g, dev := "gpu."+m[1]+".", filepath.Join(d, "device")
		if v, ok := readNum(filepath.Join(dev, "gpu_busy_percent")); ok {
			f.add(g+"used_percent", v, 0)
		}
		used, ok1 := readNum(filepath.Join(dev, "mem_info_vram_used"))
		total, ok2 := readNum(filepath.Join(dev, "mem_info_vram_total"))
		if ok1 && ok2 && total > 0 {
			f.add(g+"memory_percent", 100*used/total, 0)
		}
		mons, _ := filepath.Glob(filepath.Join(dev, "hwmon", "hwmon*"))
		for _, h := range mons {
			if v, ok := readNum(filepath.Join(h, "temp1_input")); ok {
				f.add(g+"temp_c", v/1000, 0)
			}
			if v, ok := readNum(filepath.Join(h, "power1_average")); ok {
				f.add(g+"power_w", v/1e6, 0)
			}
		}
	}
	if cards == 0 {
		f.say("AMD cards: none in %s", filepath.Join(sysRoot, "class", "drm"))
	} else {
		f.say("AMD cards: %d", cards)
	}
}

var unsafeLabel = regexp.MustCompile(`[^a-z0-9]+`)

func label(s string) string {
	return strings.Trim(unsafeLabel.ReplaceAllString(strings.ToLower(s), "_"), "_")
}

type sensor struct {
	n        int
	label    string
	value    float64
	crit     float64
	hasLabel bool
}

// chip reads one hwmon folder's temperatures (in °C) and fans (in RPM).
func chip(dir string) (temps, fans []sensor) {
	files, _ := filepath.Glob(filepath.Join(dir, "*_input"))
	for _, p := range files {
		base := strings.TrimSuffix(filepath.Base(p), "_input")
		var kind string
		var n int
		if _, err := fmt.Sscanf(base, "temp%d", &n); err == nil && strings.HasPrefix(base, "temp") {
			kind = "temp"
		} else if _, err := fmt.Sscanf(base, "fan%d", &n); err == nil && strings.HasPrefix(base, "fan") {
			kind = "fan"
		} else {
			continue
		}
		v, ok := readNum(p)
		if !ok {
			continue
		}
		lb, err := os.ReadFile(filepath.Join(dir, base+"_label"))
		s := sensor{n: n, label: strings.TrimSpace(string(lb)), hasLabel: err == nil && strings.TrimSpace(string(lb)) != ""}
		if kind == "temp" {
			s.value = v / 1000
			if c, ok := readNum(filepath.Join(dir, base+"_crit")); ok && c > 0 {
				s.crit = c / 1000
			}
			temps = append(temps, s)
		} else {
			s.value = v
			fans = append(fans, s)
		}
	}
	byN := func(l []sensor) { sort.Slice(l, func(i, j int) bool { return l[i].n < l[j].n }) }
	byN(temps)
	byN(fans)
	return
}

var cpuChips = map[string]bool{"coretemp": true, "k10temp": true, "zenpower": true}

func hwmon(f *hwFound) {
	dirs, _ := filepath.Glob(filepath.Join(sysRoot, "class", "hwmon", "hwmon*"))
	if len(dirs) == 0 {
		f.say("hwmon: no %s", filepath.Join(sysRoot, "class", "hwmon"))
		return
	}
	sort.Slice(dirs, func(i, j int) bool { return hwmonNum(dirs[i]) < hwmonNum(dirs[j]) })
	names := map[string]bool{}
	for _, d := range dirs {
		names[readText(filepath.Join(d, "name"))] = true
	}
	temps := map[string]reading{}
	put := func(name string, v, crit float64) {
		if old, ok := temps[name]; !ok || v > old.value {
			temps[name] = reading{name, v, crit}
		}
	}
	fanSeen := map[string]int{}
	var fans []reading
	cpus, nvmes, used := 0, 0, 0
	for _, d := range dirs {
		name := readText(filepath.Join(d, "name"))
		// dell_smm and dell_ddv are two drivers for the same sensors.
		if name == "dell_smm" && names["dell_ddv"] {
			continue
		}
		ts, fs := chip(d)
		if len(ts)+len(fs) > 0 {
			used++
		}
		switch {
		case cpuChips[name]:
			best := sensor{value: -1}
			for _, t := range ts {
				l := strings.ToLower(t.label)
				if strings.HasPrefix(l, "package id") || l == "tctl" || l == "tdie" {
					best = t
					break
				}
				if t.value > best.value {
					best = t
				}
			}
			if best.value > 0 {
				n := cpus
				if l := strings.ToLower(best.label); strings.HasPrefix(l, "package id ") {
					n, _ = strconv.Atoi(strings.TrimPrefix(l, "package id "))
				}
				cpus++
				put(cpuName(n), best.value, best.crit)
			}
		case name == "nvme":
			for _, t := range ts {
				if strings.EqualFold(t.label, "composite") || (!t.hasLabel && t.n == 1) {
					put(fmt.Sprintf("temp.disk.nvme%d_c", nvmes), t.value, 0)
					break
				}
			}
			nvmes++
		default:
			for _, t := range ts {
				if t.value <= 0 {
					continue
				}
				l := label(t.label)
				if !t.hasLabel || l == "" {
					l = label(name) + strconv.Itoa(t.n)
				}
				switch l {
				case "cpu", "cpu_temperature":
					put("temp.cpu_c", t.value, t.crit)
				case "ambient":
					put("temp.ambient_c", t.value, 0)
				case "board", "motherboard", "systin", "mb_temperature":
					put("temp.board_c", t.value, 0)
				default:
					put("temp."+l+"_c", t.value, 0)
				}
			}
		}
		for _, s := range fs {
			l := label(s.label)
			if !s.hasLabel || l == "" {
				l = label(name) + strconv.Itoa(s.n)
			}
			fanSeen[l]++
			if n := fanSeen[l]; n > 1 {
				l += "_" + strconv.Itoa(n)
			}
			fans = append(fans, reading{name: "fan." + l + "_rpm", value: s.value})
		}
	}
	for _, r := range temps {
		f.add(r.name, r.value, r.crit)
	}
	for _, r := range fans {
		f.add(r.name, r.value, 0)
	}
	f.say("hwmon: %d chip(s) with readings, %d temperature(s), %d fan(s)", used, len(temps), len(fans))
}

func cpuName(n int) string {
	if n == 0 {
		return "temp.cpu_c"
	}
	return fmt.Sprintf("temp.cpu.%d_c", n)
}

func hwmonNum(dir string) int {
	n, _ := strconv.Atoi(strings.TrimPrefix(filepath.Base(dir), "hwmon"))
	return n
}

// thermalZones fills in the processor and the air when hwmon named neither.
func thermalZones(f *hwFound) {
	have := map[string]bool{}
	for _, r := range f.readings {
		have[r.name] = true
	}
	zones, _ := filepath.Glob(filepath.Join(sysRoot, "class", "thermal", "thermal_zone*"))
	if len(zones) == 0 {
		f.say("thermal zones: none")
		return
	}
	added := 0
	for _, z := range zones {
		name := map[string]string{"TAMB": "temp.ambient_c", "x86_pkg_temp": "temp.cpu_c"}[readText(filepath.Join(z, "type"))]
		v, ok := readNum(filepath.Join(z, "temp"))
		if name == "" || have[name] || !ok || v <= 0 {
			continue
		}
		have[name] = true
		added++
		f.add(name, v/1000, 0)
	}
	f.say("thermal zones: %d, %d used where hwmon had none", len(zones), added)
}

var leadNum = regexp.MustCompile(`^\s*(-?\d+(?:\.\d+)?)`)

func firstNum(b []byte) (float64, bool) {
	m := leadNum.FindSubmatch(b)
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(string(m[1]), 64)
	return v, err == nil
}

func qnap(f *hwFound) {
	tool := "getsysinfo"
	if _, err := os.Stat("/sbin/getsysinfo"); err == nil {
		tool = "/sbin/getsysinfo"
	}
	get := func(args ...string) (float64, bool) {
		out, err := runCmd(tool, args...)
		if err != nil {
			return 0, false
		}
		return firstNum(out)
	}
	sys, ok := get("systmp")
	if !ok {
		f.say("QNAP getsysinfo: not a QNAP")
		return
	}
	f.add("temp.system_c", sys, 0)
	if v, ok := get("cputmp"); ok {
		f.add("temp.cpu_c", v, 0)
	}
	fans, _ := get("sysfannum")
	for i := 1; i <= int(fans) && i <= maxFans; i++ {
		if v, ok := get("sysfan", strconv.Itoa(i)); ok {
			f.add(fmt.Sprintf("fan.system%d_rpm", i), v, 0)
		}
	}
	disks, _ := get("hdnum")
	for i := 1; i <= int(disks) && i <= maxTemps; i++ {
		if v, ok := get("hdtmp", strconv.Itoa(i)); ok && v > 0 {
			f.add(fmt.Sprintf("temp.disk.hd%d_c", i), v, 0)
		}
	}
	f.say("QNAP getsysinfo: %d fan(s), %d drive(s)", int(fans), int(disks))
}

var speedLimit = regexp.MustCompile(`CPU_Speed_Limit\s*=\s*(\d+)`)

// throttle says whether the processor is slowing itself to keep cool: on Linux when its
// throttle counters rose since the last look, on macOS when its speed limit is under 100.
func throttle(f *hwFound) {
	if runtime.GOOS == "darwin" {
		out, err := runCmd("pmset", "-g", "therm")
		if err != nil {
			f.say("throttle: pmset: %v", err)
			return
		}
		f.states = append(f.states, pmsetThrottle(string(out)))
		f.say("throttle: from pmset")
		return
	}
	files, _ := filepath.Glob(filepath.Join(sysRoot, "devices", "system", "cpu", "cpu*", "thermal_throttle", "package_throttle_count"))
	if len(files) == 0 {
		f.say("throttle: no thermal_throttle counters")
		return
	}
	var sum uint64
	for _, p := range files {
		if v, ok := readNum(p); ok {
			sum += uint64(v)
		}
	}
	hwMu.Lock()
	defer hwMu.Unlock()
	if !throttleSeen {
		throttleSeen, throttleLast = true, sum
		f.say("throttle: first look, %d counter(s)", len(files))
		return
	}
	state := hwState{check: "hw.throttle", state: "ok"}
	if sum > throttleLast {
		state.state, state.note = "degraded", fmt.Sprintf("Throttled %d more times since the last report", sum-throttleLast)
	}
	throttleLast = sum
	f.states = append(f.states, state)
	f.say("throttle: %d counter(s)", len(files))
}

func pmsetThrottle(out string) hwState {
	s := hwState{check: "hw.throttle", state: "ok"}
	if m := speedLimit.FindStringSubmatch(out); m != nil {
		if n, _ := strconv.Atoi(m[1]); n < 100 {
			s.state, s.note = "degraded", "The processor is held to "+m[1]+"% of its speed"
		}
	}
	return s
}

// hardwareCommand is dokkit hardware: it says what each source found and prints the lines it
// would send. It sends nothing.
func hardwareCommand() int {
	f := lookHardware()
	for _, s := range f.said {
		fmt.Println(s)
	}
	lines := hardwareLines(f, false)
	if len(lines) == 0 {
		fmt.Println("Nothing to send: this machine reports no hardware readings to a program without administrator rights.")
		return 0
	}
	fmt.Println("Would send:")
	for _, l := range lines {
		b, _ := json.Marshal(l)
		fmt.Println(" ", string(b))
	}
	return 0
}
