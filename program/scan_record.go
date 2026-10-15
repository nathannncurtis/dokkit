package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
)

var recordEvery = time.Minute

// A run of a job that the system keeps its own record of.
type systemRun struct {
	signature string
	at        time.Time
	code      int
	failed    bool
	took      time.Duration
	tail      string
}

type recordItem struct {
	Service, Name, Source, Unit string
}

// records reports the runs of accepted jobs whose runs the system records itself: each tick it
// reads the last run time and result and reports a run when they changed since the last tick.
func (c *client) records() {
	for {
		time.Sleep(recordEvery)
		c.recordTick()
	}
}

func (c *client) recordTick() {
	var a struct{ Items []recordItem }
	if status, err := c.call("GET", "/api/v1/records", "", nil, &a); err != nil || status != 200 || len(a.Items) == 0 {
		return
	}
	file := filepath.Join(c.spool, "records.json")
	known := map[string]string{}
	if b, err := os.ReadFile(file); err == nil {
		json.Unmarshal(b, &known)
	}
	changed := false
	for _, item := range a.Items {
		run, ok := readRecord(item)
		if !ok {
			continue
		}
		before, seen := known[item.Service]
		if before == run.signature {
			continue
		}
		known[item.Service] = run.signature
		changed = true
		if seen {
			c.report(recordLine(item, run))
		}
	}
	if changed {
		b, _ := json.Marshal(known)
		writeFile(file, b)
	}
}

func recordLine(item recordItem, run systemRun) line {
	event, took, code := "ok", run.took.Milliseconds(), run.code
	if run.failed {
		event = "fail"
	}
	l := line{Type: "job", At: run.at.UTC().Format(time.RFC3339Nano), Service: item.Service, Name: item.Name, Run: id(), Event: event, ExitCode: &code, Tail: run.tail}
	if run.took > 0 {
		l.Duration = &took
	}
	return l
}

var systemdTimer = regexp.MustCompile(`^[A-Za-z0-9:_.@\\-]+\.timer$`)

var readRecord = func(item recordItem) (systemRun, bool) {
	switch {
	case item.Source == "task-scheduler" && runtime.GOOS == "windows" && strings.HasPrefix(item.Unit, `\`):
		return parseTaskRecord(output("schtasks", "/query", "/tn", item.Unit, "/fo", "csv", "/v"), item.Unit)
	case item.Source == "systemd-timer" && systemdTimer.MatchString(item.Unit):
		timer := showBlocks(output("systemctl", "show", "-p", "Id", "-p", "Unit", "-p", "LastTriggerUSec", item.Unit))
		if len(timer) == 0 {
			return systemRun{}, false
		}
		service := showBlocks(output("systemctl", "show", "-p", "Id", "-p", "Result", "-p", "ActiveState", "-p", "ExecMainStatus", "-p", "ExecMainStartTimestamp", "-p", "ExecMainExitTimestamp", timer[0]["Unit"]))
		one := map[string]string{}
		if len(service) > 0 {
			one = service[0]
		}
		return parseTimerRecord(timer[0], one)
	}
	return systemRun{}, false
}

func parseTaskRecord(lines []string, unit string) (systemRun, bool) {
	rows := table(lines)
	if len(rows) < 2 {
		return systemRun{}, false
	}
	cols := map[string]int{}
	for i, h := range rows[0] {
		cols[h] = i
	}
	for _, row := range rows[1:] {
		if i, ok := cols["TaskName"]; !ok || len(row) < len(rows[0]) || !strings.EqualFold(row[i], unit) {
			continue
		}
		when, code := row[cols["Last Run Time"]], row[cols["Last Result"]]
		at, result := windowsLast(when, code)
		n, err := strconv.ParseInt(strings.TrimSpace(code), 10, 64)
		if n == stillRunning {
			return systemRun{}, false
		}
		if at == "" || err != nil {
			return systemRun{signature: when + "|" + code}, true
		}
		t, _ := time.Parse(time.RFC3339, at)
		run := systemRun{signature: when + "|" + code, at: t, code: int(n), failed: n != 0}
		if run.failed {
			run.tail = "Task Scheduler recorded: " + result
		}
		return run, true
	}
	return systemRun{}, false
}

func parseTimerRecord(timer, service map[string]string) (systemRun, bool) {
	if slices.Contains([]string{"activating", "active", "deactivating"}, service["ActiveState"]) {
		return systemRun{}, false
	}
	at := systemdWhen(timer["LastTriggerUSec"])
	if at == "" {
		return systemRun{signature: "never"}, true
	}
	t, _ := time.Parse(time.RFC3339, at)
	run := systemRun{signature: at + "|" + service["Result"], at: t}
	if r := service["Result"]; r != "" && r != "success" {
		run.failed = true
		run.tail = "systemd recorded: " + r
		run.code, _ = strconv.Atoi(service["ExecMainStatus"])
		if run.code == 0 {
			run.code = 1
		}
	}
	start, end := systemdWhen(service["ExecMainStartTimestamp"]), systemdWhen(service["ExecMainExitTimestamp"])
	if start != "" && end != "" {
		s, _ := time.Parse(time.RFC3339, start)
		e, _ := time.Parse(time.RFC3339, end)
		if e.After(s) && !s.Before(t.Add(-time.Minute)) {
			run.took = e.Sub(s)
		}
	}
	return run, true
}

// autoScan looks the machine over shortly after it starts and then once a day, and sends the
// proposal. Nothing it finds is watched until a person accepts it.
func (c *client) autoScan() {
	time.Sleep(scanFirst)
	for {
		wait := scanEvery
		if _, err := c.scanAndSend(); err != nil {
			fmt.Fprintln(os.Stderr, time.Now().Format("15:04:05"), "scan:", err)
			wait = time.Hour
		}
		time.Sleep(wait)
	}
}
