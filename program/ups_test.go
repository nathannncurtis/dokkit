package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"
)

// fakeNut answers LIST UPS and LIST VAR the way upsd does, from upsc-style fixtures.
func fakeNut(t *testing.T, upses map[string]string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				r := bufio.NewScanner(conn)
				for r.Scan() {
					cmd := strings.Fields(r.Text())
					switch {
					case len(cmd) == 2 && cmd[0] == "LIST" && cmd[1] == "UPS":
						fmt.Fprint(conn, "BEGIN LIST UPS\n")
						for name := range upses {
							fmt.Fprintf(conn, "UPS %s \"Test UPS\"\n", name)
						}
						fmt.Fprint(conn, "END LIST UPS\n")
					case len(cmd) == 3 && cmd[0] == "LIST" && cmd[1] == "VAR" && upses[cmd[2]] != "":
						fmt.Fprintf(conn, "BEGIN LIST VAR %s\n", cmd[2])
						for _, l := range strings.Split(upses[cmd[2]], "\n") {
							if k, v, ok := strings.Cut(l, ": "); ok {
								fmt.Fprintf(conn, "VAR %s %s %q\n", cmd[2], k, v)
							}
						}
						fmt.Fprintf(conn, "END LIST VAR %s\n", cmd[2])
					case len(cmd) > 0 && cmd[0] == "LOGOUT":
						fmt.Fprint(conn, "OK Goodbye\n")
						return
					default:
						fmt.Fprint(conn, "ERR UNKNOWN-UPS\n")
					}
				}
			}()
		}
	}()
	return ln.Addr().String()
}

func upsReset(t *testing.T) {
	t.Helper()
	hwReset(t)
	oldAddrs, oldBoot := nutAddrs, thisBoot
	t.Cleanup(func() {
		nutAddrs, thisBoot = oldAddrs, oldBoot
		hwMu.Lock()
		restartKnown, restartAt = false, time.Time{}
		hwMu.Unlock()
	})
}

func statesOf(f *hwFound) map[string]hwState {
	m := map[string]hwState{}
	for _, s := range f.states {
		m[s.check] = s
	}
	return m
}

func TestNutOverItsProtocol(t *testing.T) {
	cases := []struct {
		file             string
		want             map[string]float64
		power, battery   string
		batteryNoteHas   string
		chargeOnTheState float64
	}{
		{"on-mains.txt", map[string]float64{"ups.charge_percent": 100, "ups.runtime_minutes": 47.2, "ups.load_percent": 23, "ups.input_v": 121}, "ok", "ok", "", 100},
		{"on-battery.txt", map[string]float64{"ups.charge_percent": 87, "ups.runtime_minutes": 28.7, "ups.load_percent": 31, "ups.input_v": 0}, "down", "ok", "", 87},
		{"low-battery.txt", map[string]float64{"ups.charge_percent": 9, "ups.runtime_minutes": 4, "ups.load_percent": 30, "ups.input_v": 0}, "down", "degraded", "battery is low", 9},
		{"replace-battery.txt", map[string]float64{"ups.charge_percent": 100, "ups.runtime_minutes": 10.2, "ups.load_percent": 18, "ups.input_v": 230.4}, "ok", "degraded", "needs replacing. The UPS failed its self-test: Done and error", 100},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			upsReset(t)
			nutAddrs = []string{fakeNut(t, map[string]string{"rack": fixture(t, "nut", c.file)})}
			f := &hwFound{}
			nutUPS(f)
			got := map[string]float64{}
			for _, r := range f.readings {
				got[r.name] = r.value
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("readings %v, want %v", got, c.want)
			}
			s := statesOf(f)
			if s["hw.ups.power"].state != c.power || s["hw.ups.battery"].state != c.battery {
				t.Fatalf("states %+v", f.states)
			}
			if !strings.Contains(s["hw.ups.battery"].note, c.batteryNoteHas) {
				t.Fatalf("battery note %q", s["hw.ups.battery"].note)
			}
			lines := hardwareLines(f, false)
			last := lines[len(lines)-1].(map[string]any)
			if last["check"] != "hw.ups.battery" || last["value"] != c.chargeOnTheState {
				t.Fatalf("battery line %v", last)
			}
		})
	}
}

func TestNutNotRunningSaysSoAndSendsNothing(t *testing.T) {
	upsReset(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	nutAddrs = []string{ln.Addr().String()}
	ln.Close()
	f := &hwFound{}
	nutUPS(f)
	if len(f.readings)+len(f.states) != 0 || len(f.said) != 1 || !strings.Contains(f.said[0], "NUT is not answering") {
		t.Fatalf("%+v", f)
	}
}

func TestNutWithNoUPS(t *testing.T) {
	upsReset(t)
	nutAddrs = []string{fakeNut(t, map[string]string{})}
	f := &hwFound{}
	nutUPS(f)
	if len(f.states) != 0 || f.said[0] != "UPS: NUT has no UPS" {
		t.Fatalf("%+v", f)
	}
}

func TestPmsetBatt(t *testing.T) {
	cases := []struct {
		file   string
		charge float64
		power  string
	}{
		{"batt-ups-ac.txt", 100, "ok"},
		{"batt-ups-battery.txt", 82, "down"},
		{"batt-laptop.txt", -1, ""},
		{"batt-desktop.txt", -1, ""},
	}
	for _, c := range cases {
		f := &hwFound{}
		parsePmsetBatt(fixture(t, "pmset", c.file), f)
		r, ok := readingsOf(f)["ups.charge_percent"]
		if c.charge < 0 {
			if ok || len(f.states) != 0 {
				t.Errorf("%s: a laptop's battery or no battery is not a UPS: %+v", c.file, f)
			}
			continue
		}
		if r.value != c.charge || statesOf(f)["hw.ups.power"].state != c.power {
			t.Errorf("%s: %+v", c.file, f)
		}
	}
	f := &hwFound{}
	parsePmsetBatt(fixture(t, "pmset", "batt-ups-battery.txt"), f)
	if readingsOf(f)["ups.runtime_minutes"].value != 31 {
		t.Fatalf("%+v", f.readings)
	}
}

func TestWindowsBatteryClass(t *testing.T) {
	laptop := winBattery{caps: 0x80000000, state: batteryDischarging, capacity: 40000, full: 50000, seconds: 7200}
	mains := winBattery{caps: 0x80000000 | batteryShortTerm, state: batteryOnLine, capacity: 864, full: 864, seconds: 2700}
	out := winBattery{caps: batteryShortTerm | 0x40000000, state: batteryDischarging | batteryCritical, capacity: 21, full: 100, seconds: batteryUnknown}

	f := &hwFound{}
	upsFromBatteries([]winBattery{laptop}, f)
	if len(f.readings)+len(f.states) != 0 {
		t.Fatalf("a laptop's own battery is not a UPS: %+v", f)
	}

	f = &hwFound{}
	upsFromBatteries([]winBattery{laptop, mains}, f)
	if r := readingsOf(f); r["ups.charge_percent"].value != 100 || r["ups.runtime_minutes"].value != 45 {
		t.Fatalf("%+v", f.readings)
	}
	if s := statesOf(f); s["hw.ups.power"].state != "ok" || s["hw.ups.battery"].state != "ok" {
		t.Fatalf("%+v", f.states)
	}

	f = &hwFound{}
	upsFromBatteries([]winBattery{out}, f)
	if _, ok := readingsOf(f)["ups.runtime_minutes"]; ok {
		t.Fatal("an unknown time left is not sent")
	}
	if s := statesOf(f); s["hw.ups.power"].state != "down" || s["hw.ups.battery"].state != "degraded" || readingsOf(f)["ups.charge_percent"].value != 21 {
		t.Fatalf("%+v %+v", f.states, f.readings)
	}
}

func TestARestartWithoutAShutdown(t *testing.T) {
	upsReset(t)
	spool := t.TempDir()
	boot := func(id string, at int64) {
		thisBoot = func() (bootMark, bool) { return bootMark{ID: id, At: at}, true }
		noteBoot(spool)
	}
	look := func() hwState {
		f := &hwFound{}
		restartState(f)
		return statesOf(f)["hw.restart"]
	}

	boot("a", 1000)
	if s := look(); s.check != "" {
		t.Fatalf("the first run knows nothing of the boot before: %+v", s)
	}

	boot("a", 1000)
	if look().state != "ok" {
		t.Fatal("the program starting again in the same boot is no restart")
	}

	boot("b", 5000)
	s := look()
	if s.state != "degraded" || !strings.Contains(s.note, "1970-01-01T01:23:20Z") {
		t.Fatalf("a new boot after no clean stop: %+v", s)
	}

	markClean(spool)
	boot("b", 5000)
	if look().state != "degraded" {
		t.Fatal("the same boot stays a restart without a shutdown after the program restarts")
	}

	markClean(spool)
	boot("c", 9000)
	if look().state != "ok" {
		t.Fatal("a boot after a clean stop is fine")
	}

	b, _ := os.ReadFile(filepath.Join(spool, "boot.json"))
	var m bootMark
	if json.Unmarshal(b, &m) != nil || m.ID != "c" || m.Clean {
		t.Fatalf("mark %s", b)
	}

	if !(bootMark{At: 1000}).same(bootMark{At: 1100}) || (bootMark{At: 1000}).same(bootMark{At: 2000}) {
		t.Fatal("without a boot id, boots are told apart by their start time")
	}
}

func TestUPSNamesAreInTheSpec(t *testing.T) {
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
	in := func(name string, patterns []string) bool {
		for _, p := range patterns {
			if regexp.MustCompile("^" + strings.ReplaceAll(regexp.QuoteMeta(p), "<n>", `\d+`) + "$").MatchString(name) {
				return true
			}
		}
		return false
	}
	var metrics []string
	for _, m := range spec.Metrics {
		metrics = append(metrics, m.Name)
	}
	upsReset(t)
	nutAddrs = []string{fakeNut(t, map[string]string{"rack": fixture(t, "nut", "low-battery.txt")})}
	f := &hwFound{}
	nutUPS(f)
	f.states = append(f.states, hwState{check: "hw.restart"})
	for _, r := range f.readings {
		if !in(r.name, metrics) {
			t.Errorf("%s is not in spec/hardware-names.json", r.name)
		}
	}
	for _, s := range f.states {
		if !in(s.check, spec.States) {
			t.Errorf("state %s is not in spec/hardware-names.json", s.check)
		}
	}
}
