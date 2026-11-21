package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, parts ...string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(append([]string{"testdata", "hw"}, parts...)...))
	if err != nil {
		t.Fatal(err)
	}
	return strings.ReplaceAll(string(b), "\r", "")
}

// hwReset gives a test fresh hardware state and an empty /sys, and puts everything back after.
func hwReset(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	oldRoot, oldRun, oldNow := sysRoot, runCmd, hwNow
	sysRoot = root
	runCmd = func(string, ...string) ([]byte, error) { return nil, exec.ErrNotFound }
	reset := func() {
		hwMu.Lock()
		hwSent, hwCapSaid, nvidiaField = map[string]sentReading{}, false, ""
		throttleLast, throttleSeen, clockOffset, clockAt = 0, false, 0, time.Time{}
		hwMu.Unlock()
	}
	reset()
	t.Cleanup(func() {
		sysRoot, runCmd, hwNow = oldRoot, oldRun, oldNow
		reset()
	})
	return root
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// hwmonTree builds sysfs from a dump of "== /sys/class/hwmon/hwmonN name" headers and key=value lines.
func hwmonTree(t *testing.T, root, dump string) {
	dir := ""
	for _, l := range strings.Split(dump, "\n") {
		if rest, ok := strings.CutPrefix(l, "== "); ok {
			path, name, _ := strings.Cut(rest, " ")
			dir = filepath.Join(root, strings.TrimPrefix(path, "/sys"))
			write(t, filepath.Join(dir, "name"), name+"\n")
		} else if k, v, ok := strings.Cut(l, "="); ok && dir != "" {
			write(t, filepath.Join(dir, k), v+"\n")
		}
	}
}

func thermalTree(t *testing.T, root, dump string) {
	for _, l := range strings.Split(dump, "\n") {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		dir := filepath.Join(root, "class", "thermal", f[0])
		write(t, filepath.Join(dir, "type"), strings.Join(f[1:len(f)-1], " ")+"\n")
		write(t, filepath.Join(dir, "temp"), f[len(f)-1]+"\n")
	}
}

func readingsOf(f *hwFound) map[string]reading {
	m := map[string]reading{}
	for _, r := range f.readings {
		m[r.name] = r
	}
	return m
}

func TestNvidiaOutputs(t *testing.T) {
	cases := []struct {
		file   string
		want   map[string]float64
		states []hwState
	}{
		{"new-idle.txt", map[string]float64{"gpu.0.temp_c": 34, "gpu.0.used_percent": 0, "gpu.0.memory_percent": 79.2, "gpu.0.power_w": 12.2, "gpu.0.fan_percent": 30},
			[]hwState{{"hw.gpu.0", "ok", ""}}},
		{"new-power-cap.txt", map[string]float64{"gpu.0.temp_c": 30, "gpu.0.memory_percent": 49.8},
			[]hwState{{"hw.gpu.0", "ok", ""}}},
		{"na.txt", map[string]float64{"gpu.0.temp_c": 41, "gpu.0.used_percent": 3, "gpu.0.memory_percent": 12.5}, nil},
		{"thermal.txt", map[string]float64{"gpu.0.temp_c": 88, "gpu.1.temp_c": 70},
			[]hwState{{"hw.gpu.0", "degraded", "slowed by the card for heat"}, {"hw.gpu.1", "degraded", "slowed by its driver for heat, power brake"}}},
	}
	for _, c := range cases {
		f := &hwFound{}
		parseNvidia(fixture(t, "nvidia", c.file), f)
		got := readingsOf(f)
		for name, v := range c.want {
			if got[name].value != v {
				t.Errorf("%s: %s = %v, want %v", c.file, name, got[name].value, v)
			}
		}
		if c.file == "na.txt" {
			for _, gone := range []string{"gpu.0.power_w", "gpu.0.fan_percent"} {
				if _, ok := got[gone]; ok {
					t.Errorf("na.txt: %s should be skipped", gone)
				}
			}
		}
		if len(f.states) != len(c.states) {
			t.Fatalf("%s: states %v, want %v", c.file, f.states, c.states)
		}
		for i := range c.states {
			if f.states[i] != c.states[i] {
				t.Errorf("%s: state %v, want %v", c.file, f.states[i], c.states[i])
			}
		}
	}
}

func TestNvidiaFallsBackToTheOldField(t *testing.T) {
	hwReset(t)
	var asked []string
	runCmd = func(name string, args ...string) ([]byte, error) {
		asked = append(asked, args[0])
		if strings.Contains(args[0], "clocks_event_reasons") {
			return nil, &exec.ExitError{}
		}
		return []byte(fixture(t, "nvidia", "new-idle.txt")), nil
	}
	f := &hwFound{}
	nvidiaGPUs(f)
	nvidiaGPUs(f)
	if len(asked) != 3 || !strings.Contains(asked[2], "clocks_throttle_reasons") {
		t.Fatalf("asked %v; the old field should be remembered after one try of the new", asked)
	}
	if readingsOf(f)["gpu.0.temp_c"].value != 34 {
		t.Fatalf("readings %v", f.readings)
	}
}

func TestAnAMDCardIsNumberedAfterTheNVIDIAOnes(t *testing.T) {
	root := hwReset(t)
	for card, busy := range map[string]string{"card0": "40", "card10": "60", "card2": "50"} {
		dev := filepath.Join(root, "class", "drm", card, "device")
		write(t, filepath.Join(dev, "vendor"), "0x1002\n")
		write(t, filepath.Join(dev, "gpu_busy_percent"), busy+"\n")
	}
	write(t, filepath.Join(root, "class", "drm", "card0-DP-1", "device", "vendor"), "0x1002\n")
	f := &hwFound{}
	parseNvidia(fixture(t, "nvidia", "new-idle.txt"), f)
	amdGPUs(f)
	got := readingsOf(f)
	for name, v := range map[string]float64{"gpu.0.used_percent": 0, "gpu.1.used_percent": 40, "gpu.2.used_percent": 50, "gpu.3.used_percent": 60} {
		if r, ok := got[name]; !ok || r.value != v {
			t.Errorf("%s = %+v, want %v", name, r, v)
		}
	}
	if _, ok := got["gpu.4.used_percent"]; ok {
		t.Error("a connector folder is not a card")
	}
}

func TestHwmonOnATowerWithManyCores(t *testing.T) {
	root := hwReset(t)
	hwmonTree(t, root, fixture(t, "hwmon", "dell-tower.txt"))
	thermalTree(t, root, fixture(t, "thermal", "dell-tower.txt"))
	f := &hwFound{}
	hwmon(f)
	thermalZones(f)
	got := readingsOf(f)

	cpu := 0
	for _, r := range f.readings {
		if strings.HasPrefix(r.name, "temp.cpu") {
			cpu++
		}
		if strings.Contains(r.name, "core") || strings.Contains(r.name, "dell_smm") {
			t.Errorf("sent %s: one number per chip, and dell_smm is the same sensors again", r.name)
		}
	}
	if cpu != 1 || got["temp.cpu_c"].value != 35 || got["temp.cpu_c"].crit != 105 {
		t.Errorf("processor: %d readings, %+v", cpu, got["temp.cpu_c"])
	}
	for name, v := range map[string]float64{"temp.ambient_c": 27, "temp.disk.nvme0_c": 24.9, "fan.cpu_fan_rpm": 716, "fan.chassis_motherboard_fan_2_rpm": 725, "fan.chassis_motherboard_fan_4_rpm": 0, "temp.video_c": 34} {
		if r, ok := got[name]; !ok || r.value != v {
			t.Errorf("%s = %+v, want %v", name, r, v)
		}
	}
	if _, ok := got["temp.hdd_c"]; ok {
		t.Error("a sensor reading 0 °C is not there")
	}
	fans := 0
	for _, r := range f.readings {
		if strings.HasPrefix(r.name, "fan.") {
			fans++
		}
	}
	if fans != 5 {
		t.Errorf("%d fans, want the 5 of dell_ddv", fans)
	}
}

func TestThermalZonesFillInWhenHwmonHasNone(t *testing.T) {
	root := hwReset(t)
	thermalTree(t, root, fixture(t, "thermal", "dell-tower.txt"))
	f := &hwFound{}
	hwmon(f)
	thermalZones(f)
	got := readingsOf(f)
	if got["temp.ambient_c"].value != 24.1 || got["temp.cpu_c"].value != 35 || len(f.readings) != 2 {
		t.Fatalf("readings %v", f.readings)
	}
}

func TestQnapGetsysinfo(t *testing.T) {
	hwReset(t)
	answers := map[string]string{}
	for _, l := range strings.Split(fixture(t, "qnap", "nas.txt"), "\n") {
		if k, v, ok := strings.Cut(l, "\t"); ok {
			answers[k] = v
		}
	}
	runCmd = func(name string, args ...string) ([]byte, error) {
		if filepath.Base(name) != "getsysinfo" {
			return nil, exec.ErrNotFound
		}
		if v, ok := answers[strings.Join(args, " ")]; ok {
			return []byte(v), nil
		}
		return nil, &exec.ExitError{}
	}
	f := &hwFound{}
	qnap(f)
	got := readingsOf(f)
	for name, v := range map[string]float64{"temp.system_c": 32, "temp.cpu_c": 57, "fan.system1_rpm": 750, "temp.disk.hd3_c": 36, "temp.disk.hd9_c": 26} {
		if got[name].value != v {
			t.Errorf("%s = %v, want %v", name, got[name].value, v)
		}
	}
}

func TestNotAQnap(t *testing.T) {
	hwReset(t)
	f := &hwFound{}
	qnap(f)
	if len(f.readings) != 0 || f.said[0] != "QNAP getsysinfo: not a QNAP" {
		t.Fatalf("%v %v", f.readings, f.said)
	}
}

func TestPmsetThrottle(t *testing.T) {
	if s := pmsetThrottle(fixture(t, "pmset", "therm-none.txt")); s.state != "ok" {
		t.Errorf("nothing recorded: %v", s)
	}
	if s := pmsetThrottle(fixture(t, "pmset", "therm-limited.txt")); s.state != "degraded" || !strings.Contains(s.note, "72%") {
		t.Errorf("held to 72%%: %v", s)
	}
}

func TestLinuxThrottleCountersRising(t *testing.T) {
	if runtime.GOOS == "darwin" {
		t.Skip("macOS reads pmset instead")
	}
	root := hwReset(t)
	count := filepath.Join(root, "devices", "system", "cpu", "cpu0", "thermal_throttle", "package_throttle_count")
	write(t, count, "4\n")
	look := func() []hwState { f := &hwFound{}; throttle(f); return f.states }
	if s := look(); len(s) != 0 {
		t.Fatalf("first look sends nothing: %v", s)
	}
	if s := look(); len(s) != 1 || s[0].state != "ok" {
		t.Fatalf("unchanged: %v", s)
	}
	write(t, count, "9\n")
	if s := look(); len(s) != 1 || s[0].state != "degraded" {
		t.Fatalf("rose: %v", s)
	}
}

func TestCapsKeepTheProcessorAndAirFirst(t *testing.T) {
	hwReset(t)
	f := &hwFound{}
	for i := 0; i < 20; i++ {
		f.add("temp.zone"+string(rune('a'+i))+"_c", 30, 0)
		f.add("fan.f"+string(rune('a'+i))+"_rpm", 900, 0)
	}
	f.add("temp.cpu_c", 50, 100)
	f.add("temp.ambient_c", 25, 0)
	var stderr bytes.Buffer
	lines := captureStderr(t, &stderr, func() []any { return hardwareLines(f, true) })
	temps, fans := 0, 0
	names := map[string]bool{}
	for _, l := range lines {
		name := l.(map[string]any)["name"].(string)
		names[name] = true
		if strings.HasPrefix(name, "temp.") {
			temps++
		}
		if strings.HasPrefix(name, "fan.") {
			fans++
		}
	}
	if temps != maxTemps || fans != maxFans || !names["temp.cpu_c"] || !names["temp.ambient_c"] {
		t.Fatalf("%d temps, %d fans, %v", temps, fans, names)
	}
	if strings.Count(stderr.String(), "\n") != 1 {
		t.Fatalf("one line about what was left out: %q", stderr.String())
	}
	captureStderr(t, &stderr, func() []any { return hardwareLines(f, true) })
	if strings.Count(stderr.String(), "\n") != 1 {
		t.Fatalf("said again: %q", stderr.String())
	}
}

func TestUnchangedReadingsAreSentEveryFiveMinutes(t *testing.T) {
	hwReset(t)
	at := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	hwNow = func() time.Time { return at }
	send := func(v, rpm float64) []string {
		f := &hwFound{}
		f.add("gpu.0.temp_c", v, 0)
		f.add("fan.cpu_fan_rpm", rpm, 0)
		var names []string
		for _, l := range hardwareLines(f, true) {
			names = append(names, l.(map[string]any)["name"].(string))
		}
		return names
	}
	if n := send(60, 800); len(n) != 2 {
		t.Fatalf("first: %v", n)
	}
	at = at.Add(time.Minute)
	if n := send(60.6, 840); len(n) != 0 {
		t.Fatalf("within the step: %v", n)
	}
	at = at.Add(time.Minute)
	if n := send(61, 860); len(n) != 2 {
		t.Fatalf("a step away: %v", n)
	}
	at = at.Add(4 * time.Minute)
	if n := send(61, 860); len(n) != 0 {
		t.Fatalf("four minutes on: %v", n)
	}
	at = at.Add(time.Minute)
	if n := send(61, 860); len(n) != 2 {
		t.Fatalf("five minutes on: %v", n)
	}
}

func TestClockFromTheServersAnswer(t *testing.T) {
	hwReset(t)
	sent := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	got := sent.Add(200 * time.Millisecond)
	hwNow = func() time.Time { return got.Add(time.Minute) }
	server := sent.Add(100 * time.Millisecond).Add(-15 * time.Second).UnixMilli()
	noteClock(sent, got, []byte(`{"accepted":1,"refused":[],"server_ms":`+jsonNum(server)+`}`))
	f := lookHardware()
	if r := readingsOf(f)["clock.offset_seconds"]; r.value != 15 {
		t.Fatalf("offset %+v", r)
	}
	noteClock(sent, got, []byte(`{"accepted":1,"refused":[]}`))
	hwNow = func() time.Time { return got.Add(11 * time.Minute) }
	if _, ok := readingsOf(lookHardware())["clock.offset_seconds"]; ok {
		t.Fatal("a measurement over ten minutes old is not sent")
	}
}

func TestNoSensorsMeansNoLinesAndNoNoise(t *testing.T) {
	hwReset(t)
	var stderr bytes.Buffer
	lines := captureStderr(t, &stderr, func() []any { return (&client{}).hardware() })
	if len(lines) != 0 || stderr.Len() != 0 {
		t.Fatalf("lines %v, said %q", lines, stderr.String())
	}
}

func TestEveryNameIsInTheSpec(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "spec", "hardware-names.json"))
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Metrics []struct {
			Name string
			Step float64
		}
		States []string
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	pattern := func(p string) *regexp.Regexp {
		p = regexp.QuoteMeta(p)
		p = strings.ReplaceAll(p, "<n>", `\d+`)
		p = strings.NewReplacer("<dev>", "[a-z0-9_]+", "<label>", "[a-z0-9_]+").Replace(p)
		return regexp.MustCompile("^" + p + "$")
	}
	root := hwReset(t)
	hwmonTree(t, root, fixture(t, "hwmon", "dell-tower.txt"))
	f := &hwFound{}
	hwmon(f)
	for _, file := range []string{"new-idle.txt", "thermal.txt"} {
		parseNvidia(fixture(t, "nvidia", file), f)
	}
	f.add("clock.offset_seconds", 1, 0)
	f.add("temp.system_c", 30, 0)
	f.add("temp.disk.hd1_c", 30, 0)
	f.add("temp.cpu.1_c", 30, 0)
	f.states = append(f.states, pmsetThrottle(""))
	for _, r := range f.readings {
		ok := false
		for _, m := range spec.Metrics {
			if pattern(m.Name).MatchString(r.name) {
				ok = true
				if m.Step != stepFor(r.name) {
					t.Errorf("%s: step %v, the spec says %v", r.name, stepFor(r.name), m.Step)
				}
				break
			}
		}
		if !ok {
			t.Errorf("%s is not in spec/hardware-names.json", r.name)
		}
	}
	for _, s := range f.states {
		ok := false
		for _, p := range spec.States {
			ok = ok || pattern(p).MatchString(s.check)
		}
		if !ok {
			t.Errorf("state %s is not in spec/hardware-names.json", s.check)
		}
	}
}

func jsonNum(n int64) string { b, _ := json.Marshal(n); return string(b) }

func captureStderr(t *testing.T, into *bytes.Buffer, fn func() []any) []any {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	out := fn()
	os.Stderr = old
	w.Close()
	io.Copy(into, r)
	return out
}
