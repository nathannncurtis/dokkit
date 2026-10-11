package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func lines(t *testing.T, file string) []string {
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n")
}

func byName(jobs []found, name string) found {
	for _, j := range jobs {
		if j["name"] == name {
			return j
		}
	}
	return nil
}

func TestSchtasksReadsTheMachinesOwnOutput(t *testing.T) {
	jobs := parseSchtasks(lines(t, "testdata/schtasks.csv"), -240)
	if len(jobs) != 8 {
		t.Fatalf("%d jobs: %v", len(jobs), jobs)
	}
	for _, j := range jobs {
		if strings.Contains(j["unit"], `\Microsoft\`) {
			t.Fatalf("a Microsoft task was proposed: %v", j)
		}
	}
	core := byName(jobs, "BraveSoftwareUpdateTaskUserS-1-5-21-1-2-3-1001Core{A045D7F7-8769-41F2-8A45-756C5C0DEC31}")
	if core["schedule"] != "0 17 * * *" || core["record"] != byRecord || !strings.Contains(core["schedule_note"], "-4") {
		t.Fatalf("%v", core)
	}
	if core["command"] != `"C:\Users\someone\AppData\Local\BraveSoftware\Update\BraveUpdate.exe" /c` {
		t.Fatalf("command: %q", core["command"])
	}
	if core["last_result"] != "ok" || !strings.HasPrefix(core["last_run"], "2026-10-11T") {
		t.Fatalf("%v", core)
	}
	if a := byName(jobs, "BraveSoftwareUpdateTaskUserS-1-5-21-1-2-3-1001UA{0E30A325-1DE6-4024-AC17-830158D4D213}"); a["schedule"] != "0 * * * *" {
		t.Fatalf("hourly repeat: %v", a)
	}
	if p := byName(jobs, "PDFXChangeAutoUpdate"); p["schedule"] != "" || !strings.Contains(p["schedule_note"], "every 14 days") {
		t.Fatalf("every 14 days: %v", p)
	}
	if o := byName(jobs, "OneDrive Per-Machine Standalone Update Task"); o["schedule"] != "0 9 * * *" || o["last_result"] != "failed, result -2147160572 (0x8004ee04)" {
		t.Fatalf("repeat of 24 hours: %v", o)
	}
	if l := byName(jobs, "OneDrive Startup Task-S-1-5-21-1-2-3-1001"); l["schedule"] != "" || !strings.Contains(l["schedule_note"], "at logon time") {
		t.Fatalf("at logon: %v", l)
	}
	if p := byName(jobs, "Autorun for someone"); p["last_run"] != "" {
		t.Fatalf("a task that never ran has no last run: %v", p)
	}
}

func TestWindowsSchedules(t *testing.T) {
	for _, c := range []struct {
		kind, start, days, months, repeat string
		offset                            int
		cron                              string
	}{
		{"Daily ", "1:00:00 AM", "Every 1 day(s)", "N/A", "Disabled", 0, "0 1 * * *"},
		{"Daily ", "11:30:00 PM", "Every 1 day(s)", "N/A", "Disabled", -300, "30 4 * * *"},
		{"Daily ", "1:00:00 AM", "Every 1 day(s)", "N/A", "Disabled", 120, "0 23 * * *"},
		{"Weekly", "3:00:00 AM", "MON, WED", "Every 1 week(s)", "Disabled", 0, "0 3 * * 1,3"},
		{"Weekly", "1:30:00 AM", "MON, SUN", "Every 1 week(s)", "Disabled", 120, "30 23 * * 0,6"},
		{"Weekly", "3:00:00 AM", "Every day of the week", "Every 1 week(s)", "Disabled", 0, "0 3 * * *"},
		{"Weekly", "3:00:00 AM", "MON", "Every 2 week(s)", "Disabled", 0, ""},
		{"Monthly", "2:00:00 AM", "1", "JAN, FEB, MAR, APR, MAY, JUN, JUL, AUG, SEP, OCT, NOV, DEC", "Disabled", 0, "0 2 1 * *"},
		{"Monthly", "2:00:00 AM", "1, 15", "JAN, JUL", "Disabled", 0, "0 2 1,15 1,7 *"},
		{"Monthly", "1:00:00 AM", "1", "Every month", "Disabled", 120, ""},
		{"Monthly", "2:00:00 AM", "Last", "Every month", "Disabled", 0, ""},
		{"One Time Only, Minute", "10:07:00 AM", "N/A", "N/A", "0 Hour(s), 15 Minute(s)", 0, "7,22,37,52 * * * *"},
		{"One Time Only, Hourly", "10:07:00 AM", "N/A", "N/A", "6 Hour(s), 0 Minute(s)", 0, "7 4,10,16,22 * * *"},
		{"One Time Only", "10:07:00 AM", "N/A", "N/A", "Disabled", 0, ""},
		{"On idle time", "N/A", "N/A", "N/A", "Disabled", 0, ""},
		{"Undefined", "N/A", "N/A", "N/A", "N/A", 0, ""},
	} {
		got, note := windowsSchedule(c.kind, c.start, c.days, c.months, c.repeat, c.offset)
		if got != c.cron {
			t.Errorf("%q %q %q: got %q (%s), want %q", c.kind, c.start, c.days, got, note, c.cron)
		}
		if got == "" && note == "" {
			t.Errorf("%q: no schedule and no reason", c.kind)
		}
	}
}

func TestLastRunOfATask(t *testing.T) {
	if at, result := windowsLast("11/30/1999 12:00:00 AM", "267011"); at != "" || result != "has not run yet" {
		t.Fatal(at, result)
	}
	if at, result := windowsLast("N/A", "0"); at != "" || result != "ok" {
		t.Fatal(at, result)
	}
	if _, result := windowsLast("1/2/2026 3:04:05 PM", "1"); result != "failed, result 1 (0x1)" {
		t.Fatal(result)
	}
}

func TestACronLineMovesToUTC(t *testing.T) {
	for _, c := range []struct {
		in     string
		offset int
		out    string
	}{
		{"30 2 * * *", 0, "30 2 * * *"},
		{"30 2 * * *", -300, "30 7 * * *"},
		{"30 2 * * *", 330, "0 21 * * *"},
		{"0 1 * * 1-5", 120, "0 23 * * 0,1,2,3,4"},
		{"0 1 1 * *", 120, ""},
		{"*/15 * * * *", 60, "*/15 * * * *"},
		{"*/15 * * * *", 330, "0,15,30,45 * * * *"},
		{"0 */6 * * *", -60, "0 1,7,13,19 * * *"},
		{"0 9-11 * * mon", 0, "0 9-11 * * mon"},
		{"0 22,23 * * *", 120, "0 20,21 * * *"},
		{"0 1,23 * * *", 120, "0 21,23 * * *"},
		{"0 1,23 * * 1", 120, ""},
	} {
		f := strings.Fields(c.in)
		got, ok := cronUTC([5]string{f[0], f[1], f[2], f[3], f[4]}, c.offset)
		if got != c.out {
			t.Errorf("%q at %d: got %q (%v), want %q", c.in, c.offset, got, ok, c.out)
		}
	}
}

const crontabText = `# m h dom mon dow command
MAILTO=ops@example.com
PATH=/usr/bin:/bin

15 3 * * *  /usr/local/bin/backup.sh --target /srv/backup --password hunter2
*/10 * * * * /usr/bin/flock -n /tmp/sync.lock python3 /opt/sync/sync.py
@daily cd /srv/app && ./cleanup.sh
@reboot /opt/start-tunnel.sh
0 7 * * mon-fri /usr/bin/env php /var/www/report.php
not a cron line
`

func TestCrontabLines(t *testing.T) {
	jobs := parseCrontab(strings.Split(crontabText, "\n"), false, "this account's crontab", -300)
	if len(jobs) != 5 {
		t.Fatalf("%d: %v", len(jobs), jobs)
	}
	b := jobs[0]
	if b["name"] != "backup" || b["schedule"] != "15 8 * * *" || b["record"] != byWrapper || b["command"] != "/usr/local/bin/backup.sh --target /srv/backup --password ***" {
		t.Fatalf("%v", b)
	}
	if s := jobs[1]; s["name"] != "sync" || s["schedule"] != "0,10,20,30,40,50 * * * *" && s["schedule"] != "*/10 * * * *" {
		t.Fatalf("%v", s)
	}
	if c := jobs[2]; c["name"] != "cleanup" || c["schedule"] != "0 5 * * *" {
		t.Fatalf("%v", c)
	}
	if r := jobs[3]; r["schedule"] != "" || !strings.Contains(r["schedule_note"], "boot") {
		t.Fatalf("%v", r)
	}
	if r := jobs[4]; r["name"] != "report" || r["schedule"] != "0 12 * * mon-fri" && r["schedule"] != "0 12 * * 1,2,3,4,5" {
		t.Fatalf("%v", r)
	}
}

func TestSystemCrontabHasAUser(t *testing.T) {
	text := "SHELL=/bin/sh\n17 * * * * root cd / && run-parts --report /etc/cron.hourly\n25 6 * * * www-data /srv/site/prune.sh\n"
	jobs := parseCrontab(strings.Split(text, "\n"), true, "/etc/crontab", 0)
	if len(jobs) != 2 || jobs[1]["user"] != "www-data" || jobs[1]["name"] != "prune" || jobs[0]["schedule"] != "17 * * * *" {
		t.Fatalf("%v", jobs)
	}
}

const listTimers = `Mon 2026-10-12 00:00:00 UTC 5h 19min left Sun 2026-10-11 00:00:01 UTC 18h ago logrotate.timer          logrotate.service
Mon 2026-10-12 03:10:00 UTC 8h left       Sun 2026-10-11 03:10:02 UTC 15h ago nightly-backup.timer    nightly-backup.service
Mon 2026-10-12 00:00:00 UTC 5h 19min left Sun 2026-10-11 00:00:01 UTC 18h ago systemd-tmpfiles-clean.timer systemd-tmpfiles-clean.service
n/a                         n/a           n/a                         n/a      boot-once.timer          boot-once.service
`

const showTimers = `Id=logrotate.timer
Description=Daily rotation of log files
TimersCalendar={ OnCalendar=*-*-* 00:00:00 ; next_elapse=Mon 2026-10-12 00:00:00 UTC }
TimersMonotonic=
LastTriggerUSec=Sun 2026-10-11 00:00:01 UTC
Unit=logrotate.service

Id=nightly-backup.timer
Description=Nightly backup
TimersCalendar={ OnCalendar=*-*-* 03:10:00 ; next_elapse=Mon 2026-10-12 03:10:00 UTC }
TimersMonotonic=
LastTriggerUSec=Sun 2026-10-11 03:10:02 UTC
Unit=nightly-backup.service

Id=systemd-tmpfiles-clean.timer
Description=Daily Cleanup of Temporary Directories
TimersCalendar={ OnCalendar=*-*-* 00:00:00 ; next_elapse=Mon 2026-10-12 00:00:00 UTC }
LastTriggerUSec=Sun 2026-10-11 00:00:01 UTC
Unit=systemd-tmpfiles-clean.service

Id=boot-once.timer
Description=After boot
TimersCalendar=
TimersMonotonic={ OnBootSec=15min ; next_elapse=n/a }
LastTriggerUSec=n/a
Unit=boot-once.service
`

const showServices = `Id=logrotate.service
Result=success
ExecStart={ path=/usr/sbin/logrotate ; argv[]=/usr/sbin/logrotate /etc/logrotate.conf ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }

Id=nightly-backup.service
Result=exit-code
ExecStart={ path=/usr/local/bin/backup ; argv[]=/usr/local/bin/backup --full --token abc123 ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }

Id=boot-once.service
Result=success
`

func TestSystemdTimers(t *testing.T) {
	names := timerNames(strings.Split(listTimers, "\n"))
	if len(names) != 4 || names[3] != "boot-once.timer" {
		t.Fatalf("%v", names)
	}
	timers, services := showBlocks(strings.Split(showTimers, "\n")), showBlocks(strings.Split(showServices, "\n"))
	if len(timers) != 4 || len(services) != 3 {
		t.Fatalf("%d %d", len(timers), len(services))
	}
	log, ok := timerJob(timers[0], services[0], 0)
	if !ok || log["name"] != "logrotate" || log["schedule"] != "0 0 * * *" || log["record"] != byRecord || log["unit"] != "logrotate.timer" ||
		log["last_run"] != "2026-10-11T00:00:01Z" || log["last_result"] != "ok" || log["command"] != "/usr/sbin/logrotate /etc/logrotate.conf" {
		t.Fatalf("%v", log)
	}
	backup, _ := timerJob(timers[1], services[1], -300)
	if backup["schedule"] != "10 8 * * *" || backup["last_result"] != "failed (exit-code)" || backup["command"] != "/usr/local/bin/backup --full --token ***" {
		t.Fatalf("%v", backup)
	}
	if _, ok := timerJob(timers[2], nil, 0); ok {
		t.Fatal("a systemd timer was proposed")
	}
	boot, _ := timerJob(timers[3], services[2], 0)
	if boot["schedule"] != "" || !strings.Contains(boot["schedule_note"], "after boot") {
		t.Fatalf("%v", boot)
	}
}

func TestCalendarExpressions(t *testing.T) {
	for in, want := range map[string]string{
		"*-*-* 03:00:00":          "0 3 * * *",
		"daily":                   "0 0 * * *",
		"hourly":                  "0 * * * *",
		"weekly":                  "0 0 * * 1",
		"Mon *-*-* 02:30":         "30 2 * * 1",
		"Mon,Fri *-*-* 02:30:00":  "30 2 * * 1,5",
		"*-*-01 04:00:00":         "0 4 1 * *",
		"*:0/15":                  "0-59/15 * * * *",
		"*-*-* 00/6:00":           "0 0-23/6 * * *",
		"*-*-* 03:00:00 UTC":      "0 3 * * *",
		"Mon..Fri *-*-* 02:30":    "",
		"*-*-* 03:00 Europe/Rome": "",
		"2026-12-25 03:00":        "",
	} {
		if got, _ := calendarCron(in, 0); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
	if got, _ := calendarCron("*-*-* 03:00:00", -300); got != "0 8 * * *" {
		t.Errorf("local time: %q", got)
	}
	if got, _ := calendarCron("*-*-* 03:00:00 UTC", -300); got != "0 3 * * *" {
		t.Errorf("a calendar written in UTC is not moved: %q", got)
	}
}

func TestLaunchd(t *testing.T) {
	cal := map[string]any{"Label": "com.example.backup", "ProgramArguments": []any{"/usr/local/bin/backup", "--quiet"},
		"StartCalendarInterval": map[string]any{"Hour": 2.0, "Minute": 30.0}}
	j, ok := parseLaunchd(cal, "/Library/LaunchDaemons/com.example.backup.plist", -420)
	if !ok || j["schedule"] != "30 9 * * *" || j["record"] != byWrapper || j["command"] != "/usr/local/bin/backup --quiet" {
		t.Fatalf("%v", j)
	}
	weekly := map[string]any{"Label": "com.example.weekly", "Program": "/bin/x", "StartCalendarInterval": map[string]any{"Weekday": 1.0, "Hour": 6.0, "Minute": 0.0}}
	if j, _ := parseLaunchd(weekly, "", 0); j["schedule"] != "0 6 * * 1" {
		t.Fatalf("%v", j)
	}
	many := map[string]any{"Label": "com.example.many", "StartCalendarInterval": []any{map[string]any{"Hour": 1.0}, map[string]any{"Hour": 2.0}}}
	if j, _ := parseLaunchd(many, "", 0); j["schedule"] != "" || j["schedule_note"] == "" {
		t.Fatalf("%v", j)
	}
	every := map[string]any{"Label": "com.example.poll", "StartInterval": 900.0}
	if j, _ := parseLaunchd(every, "", 0); j["schedule"] != "0,15,30,45 * * * *" {
		t.Fatalf("%v", j)
	}
	if _, ok := parseLaunchd(map[string]any{"Label": "com.apple.thing", "StartInterval": 60.0}, "", 0); ok {
		t.Fatal("an Apple job was proposed")
	}
	if _, ok := parseLaunchd(map[string]any{"Label": "com.example.always", "KeepAlive": true}, "", 0); ok {
		t.Fatal("a job with no schedule at all was proposed")
	}
}

func TestIISSiteAndContainerPort(t *testing.T) {
	s, ok := parseIISSite(`SITE "Default Web Site" (id:1,bindings:http/*:80:,https/*:443:,state:Started)`)
	if !ok || s["url"] != "http://localhost/" || s["state"] != "started" {
		t.Fatalf("%v", s)
	}
	s, _ = parseIISSite(`SITE "Portal" (id:2,bindings:net.tcp/808:*,https/*:8443:portal.example.com,state:Started)`)
	if s["url"] != "https://portal.example.com:8443/" {
		t.Fatalf("%v", s)
	}
	if got := publishedPort("0.0.0.0:8080->80/tcp, :::8080->80/tcp"); got != "8080" {
		t.Fatal(got)
	}
	if got := publishedPort("5432/tcp"); got != "" {
		t.Fatal(got)
	}
}

func TestARunInTheSystemsRecordIsReportedOnceWhenItChanges(t *testing.T) {
	signature := "a"
	real := readRecord
	defer func() { readRecord = real }()
	readRecord = func(item recordItem) (systemRun, bool) {
		return systemRun{signature: signature, at: time.Date(2026, 10, 11, 3, 0, 0, 0, time.UTC), failed: signature == "c", code: 7}, true
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"items":[{"service":"nightly","name":"nightly","source":"task-scheduler","unit":"\\Nightly"}]}`))
	}))
	defer srv.Close()
	c := &client{url: srv.URL, key: "dkm_machine", spool: t.TempDir()}
	sent := func() int {
		files, _ := filepath.Glob(filepath.Join(c.spool, "*.ndjson"))
		return len(files)
	}
	c.recordTick()
	c.recordTick()
	if sent() != 0 {
		t.Fatal("the first reading is only a starting point")
	}
	signature = "b"
	c.recordTick()
	c.recordTick()
	if sent() != 1 {
		t.Fatalf("%d reports", sent())
	}
	signature = "c"
	c.recordTick()
	files, _ := filepath.Glob(filepath.Join(c.spool, "*.ndjson"))
	b, _ := os.ReadFile(files[len(files)-1])
	if sent() != 2 || !strings.Contains(string(b), `"event":"fail"`) || !strings.Contains(string(b), `"exit_code":7`) || !strings.Contains(string(b), `"service":"nightly"`) {
		t.Fatalf("%d: %s", sent(), b)
	}
}

func TestLookAgainSendsTheScanAndAnswers(t *testing.T) {
	t.Setenv("DOKKIT_CONFIG", filepath.Join(t.TempDir(), "none.json"))
	got := make(chan string, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got <- r.URL.Path + " " + string(b)
		w.Write([]byte(`{"waiting":3}`))
	}))
	defer srv.Close()
	c := &client{url: srv.URL, key: "dkm_machine"}
	c.lookAgain("r9")
	first, second, third := <-got, <-got, <-got
	if !strings.HasPrefix(first, "/api/v1/proposals {") || !strings.Contains(first, `"found"`) {
		t.Fatal(first)
	}
	if !strings.HasPrefix(second, "/api/v1/work/r9/output ") || !strings.Contains(second, "3 thing(s) are waiting") {
		t.Fatal(second)
	}
	if !strings.HasPrefix(third, "/api/v1/work/r9/result ") || !strings.Contains(third, `"exit_code":0`) {
		t.Fatal(third)
	}
}

func TestTheSystemsRecordOfATaskIsReadAsARun(t *testing.T) {
	csv := []string{
		`"HostName","TaskName","Next Run Time","Status","Logon Mode","Last Run Time","Last Result"`,
		`"HOST","\DokkitScanProof","10/11/2026 5:00:00 PM","Ready","Interactive only","10/11/2026 4:55:01 PM","0"`,
	}
	run, ok := parseTaskRecord(csv, `\DokkitScanProof`)
	if !ok || run.failed || run.at.IsZero() || !strings.Contains(run.signature, "4:55:01 PM") {
		t.Fatalf("%+v", run)
	}
	csv[1] = strings.Replace(csv[1], `"0"`, `"-2147024894"`, 1)
	if r2, _ := parseTaskRecord(csv, `\DokkitScanProof`); !r2.failed || r2.signature == run.signature || r2.code != -2147024894 {
		t.Fatalf("%+v", r2)
	}
	if _, ok := parseTaskRecord(csv, `\Another`); ok {
		t.Fatal("another task's row was read")
	}

	timer := map[string]string{"LastTriggerUSec": "Sun 2026-10-11 03:10:02 UTC"}
	service := map[string]string{"Result": "exit-code", "ExecMainStatus": "3", "ExecMainStartTimestamp": "Sun 2026-10-11 03:10:02 UTC", "ExecMainExitTimestamp": "Sun 2026-10-11 03:10:32 UTC"}
	tr, _ := parseTimerRecord(timer, service)
	if !tr.failed || tr.code != 3 || tr.took != 30*time.Second || tr.at.Format(time.RFC3339) != "2026-10-11T03:10:02Z" {
		t.Fatalf("%+v", tr)
	}
	if tr, _ := parseTimerRecord(map[string]string{"LastTriggerUSec": "n/a"}, nil); tr.signature != "never" {
		t.Fatalf("%+v", tr)
	}
}
