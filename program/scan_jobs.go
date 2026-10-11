package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The minutes the local clock is ahead of UTC.
var zoneMinutes = func() int {
	_, off := time.Now().Zone()
	return off / 60
}

const (
	byRecord  = "record"
	byWrapper = "wrapper"
)

const (
	noteTaskScheduler = "Task Scheduler lists only the tasks this account is allowed to read. Tasks only administrators or the system account can read are not listed; run the scan from an administrator prompt to see them."
	noteCron          = "Only the crontab of the account the scan runs as, /etc/crontab and the files of /etc/cron.d this account can read were looked at. Other accounts' crontabs are readable only by root, and the scripts in /etc/cron.daily and the like are not listed."
	noteTimers        = "systemd timers of the system are listed; timers of a user's own systemd (systemctl --user) are not."
	noteLaunchd       = "Only launchd jobs in ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons that this account can read are listed; Apple's own are left out."
)

// findJobs looks for work the machine runs on a schedule. A command line is kept to be shown
// for recognition and is never run.
func findJobs() (jobs []found, notes []string) {
	switch runtime.GOOS {
	case "windows":
		jobs = parseSchtasks(output("schtasks", "/query", "/fo", "csv", "/v"), zoneMinutes())
		notes = []string{noteTaskScheduler}
	case "darwin":
		jobs, notes = findCron(), []string{noteCron, noteLaunchd}
		jobs = append(jobs, findLaunchd()...)
	default:
		jobs, notes = findCron(), []string{noteCron}
		if _, err := exec.LookPath("systemctl"); err == nil {
			jobs = append(jobs, findTimers()...)
			notes = append(notes, noteTimers)
		}
	}
	return nameJobs(jobs), notes
}

// nameJobs makes each name unique, so each job has a key that stays the same between scans.
func nameJobs(jobs []found) []found {
	seen := map[string]int{}
	for _, j := range jobs {
		base := j["name"]
		seen[base]++
		if n := seen[base]; n > 1 {
			j["name"] = fmt.Sprintf("%s %d", base, n)
		}
	}
	return jobs
}

var secretWords = regexp.MustCompile(`(?i)((?:--?|\b)(?:pass\w*|secret|token|api[_-]?key)[= ])\S+`)

func shown(command string) string {
	command = secretWords.ReplaceAllString(strings.Join(strings.Fields(command), " "), "${1}***")
	if len(command) > 300 {
		command = strings.ToValidUTF8(command[:300], "") + "..."
	}
	return command
}

// Windows Task Scheduler.

const neverRan = 267011

// parseSchtasks reads the output of schtasks /query /fo csv /v. Microsoft's own tasks, and
// tasks that are turned off, are left out.
func parseSchtasks(lines []string, offset int) (jobs []found) {
	rows := table(lines)
	cols := map[string]int{}
	for _, row := range rows {
		if len(row) > 1 && row[1] == "TaskName" {
			cols = map[string]int{}
			for i, h := range row {
				cols[h] = i
			}
			continue
		}
		get := func(name string) string {
			if i, ok := cols[name]; ok && i < len(row) {
				return strings.TrimSpace(row[i])
			}
			return ""
		}
		name := get("TaskName")
		if name == "" || strings.HasPrefix(strings.ToLower(name), `\microsoft\`) || get("Scheduled Task State") == "Disabled" {
			continue
		}
		j := found{"name": strings.TrimLeft(name[strings.LastIndex(name, `\`)+1:], " "), "source": "task-scheduler", "record": byRecord, "unit": name}
		if j["name"] == "" {
			continue
		}
		if c := get("Task To Run"); c != "" && c != "N/A" {
			j["command"] = shown(c)
		}
		if who := get("Run As User"); who != "" && who != "N/A" {
			j["user"] = who
		}
		j["schedule"], j["schedule_note"] = windowsSchedule(get("Schedule Type"), get("Start Time"), get("Days"), get("Months"), get("Repeat: Every"), offset)
		j["last_run"], j["last_result"] = windowsLast(get("Last Run Time"), get("Last Result"))
		jobs = append(jobs, j)
	}
	return jobs
}

func windowsLast(when, code string) (string, string) {
	n, err := strconv.ParseInt(code, 10, 64)
	if err != nil {
		return "", ""
	}
	switch n {
	case neverRan:
		return "", "has not run yet"
	case 267009:
		return "", "running"
	}
	at := ""
	for _, layout := range []string{"1/2/2006 3:04:05 PM", "1/2/2006 15:04:05", "2006-01-02 15:04:05", "2/1/2006 15:04:05"} {
		if t, err := time.ParseInLocation(layout, when, time.Local); err == nil {
			if t.Year() > 2000 {
				at = t.UTC().Format(time.RFC3339)
			}
			break
		}
	}
	if n == 0 {
		return at, "ok"
	}
	return at, fmt.Sprintf("failed, result %d (0x%x)", n, uint32(n))
}

var windowsDays = map[string]int{"SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6}

func windowsSchedule(kind, start, days, months, repeat string, offset int) (cron, note string) {
	kind = strings.TrimSpace(strings.Split(kind, ",")[0])
	clock := func() (h, m int, ok bool) {
		for _, layout := range []string{"3:04:05 PM", "3:04 PM", "15:04:05", "15:04"} {
			if t, err := time.Parse(layout, start); err == nil {
				return t.Hour(), t.Minute(), true
			}
		}
		return 0, 0, false
	}
	every := func(s string) int {
		var n int
		fmt.Sscanf(strings.TrimSpace(strings.TrimPrefix(s, "Every")), "%d", &n)
		return n
	}
	switch kind {
	case "At logon time", "At system start up", "At idle time", "On idle time", "When an event occurs":
		return "", "Runs " + strings.ToLower(strings.Replace(kind, "At ", "at ", 1)) + ", which is not a time of day."
	case "On demand only", "Undefined", "":
		return "", "Runs only when started, so it has no schedule."
	}
	h, m, ok := clock()
	if !ok {
		return "", "The start time could not be read."
	}
	if rm := intervalMinutes(repeat); rm > 0 {
		return repeating(h, m, rm, offset)
	}
	switch kind {
	case "Daily":
		if n := every(days); n != 1 {
			return "", fmt.Sprintf("Runs every %d days, which a cron line cannot say.", n)
		}
		return shift(strconv.Itoa(m), strconv.Itoa(h), "*", "*", "*", offset)
	case "Weekly":
		if every(months) > 1 {
			return "", fmt.Sprintf("Runs every %d weeks, which a cron line cannot say.", every(months))
		}
		dow := "*"
		if !strings.Contains(strings.ToLower(days), "every") {
			var list []string
			for _, d := range strings.Split(days, ",") {
				n, ok := windowsDays[strings.ToUpper(strings.TrimSpace(d))]
				if !ok {
					return "", "The days could not be read."
				}
				list = append(list, strconv.Itoa(n))
			}
			dow = strings.Join(list, ",")
		}
		return shift(strconv.Itoa(m), strconv.Itoa(h), "*", "*", dow, offset)
	case "Monthly":
		dom := "*"
		if !strings.Contains(strings.ToLower(days), "every") {
			if _, err := strconv.Atoi(strings.NewReplacer(",", "", " ", "").Replace(days)); err != nil {
				return "", "Runs on a day such as the last of the month, which a cron line cannot say."
			}
			dom = strings.ReplaceAll(days, " ", "")
		}
		mon := "*"
		if names := strings.Split(strings.ToUpper(months), ","); len(names) < 12 && !strings.Contains(strings.ToLower(months), "every") {
			var list []string
			for _, n := range names {
				i := strings.Index("JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC", strings.TrimSpace(n))
				if len(strings.TrimSpace(n)) != 3 || i%3 != 0 {
					return "", "The months could not be read."
				}
				list = append(list, strconv.Itoa(i/3+1))
			}
			mon = strings.Join(list, ",")
		}
		return shift(strconv.Itoa(m), strconv.Itoa(h), dom, mon, "*", offset)
	case "One Time Only":
		return "", "Runs once."
	}
	return "", "Its schedule could not be put in a cron line."
}

// intervalMinutes reads "1 Hour(s), 30 Minute(s)" as minutes; 0 when there is no repeat.
func intervalMinutes(s string) int {
	var h, m int
	if _, err := fmt.Sscanf(s, "%d Hour(s), %d Minute(s)", &h, &m); err != nil {
		return 0
	}
	return h*60 + m
}

// repeating turns "every n minutes from a start time" into a cron line when n divides the day.
func repeating(h, m, every, offset int) (string, string) {
	if every <= 0 || 1440%every != 0 || (every > 60 && every%60 != 0) {
		return "", fmt.Sprintf("Repeats every %d minutes, which a cron line cannot say.", every)
	}
	start := h*60 + m
	var hours, minutes []string
	seenH, seenM := map[int]bool{}, map[int]bool{}
	for t := start % every; t < 1440; t += every {
		if every < 60 {
			if !seenM[t%60] {
				seenM[t%60] = true
				minutes = append(minutes, strconv.Itoa(t%60))
			}
		} else if !seenH[t/60] {
			seenH[t/60] = true
			hours = append(hours, strconv.Itoa(t/60))
			if len(minutes) == 0 {
				minutes = []string{strconv.Itoa(t % 60)}
			}
		}
	}
	if every < 60 {
		return shift(strings.Join(minutes, ","), "*", "*", "*", "*", offset)
	}
	hour := strings.Join(hours, ",")
	if len(hours) == 24 {
		hour = "*"
	}
	return shift(strings.Join(minutes, ","), hour, "*", "*", "*", offset)
}

// shift writes a cron line given in the machine's local time as one in UTC.
func shift(minute, hour, dom, mon, dow string, offset int) (string, string) {
	line, ok := cronUTC([5]string{minute, hour, dom, mon, dow}, offset)
	if !ok {
		return "", "Its time of day could not be moved to UTC in a cron line."
	}
	if offset != 0 {
		return line, fmt.Sprintf("Read in UTC: converted from this machine's local time, %s hours from UTC now.", offsetText(offset))
	}
	return line, ""
}

func offsetText(offset int) string {
	sign := "+"
	if offset < 0 {
		sign, offset = "-", -offset
	}
	if offset%60 == 0 {
		return fmt.Sprintf("%s%d", sign, offset/60)
	}
	return fmt.Sprintf("%s%d:%02d", sign, offset/60, offset%60)
}

// Cron.

var cronDow = map[string]int{"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}

// expand reads one cron field of numbers, lists, ranges and steps as the values it stands for.
func expand(field string, lo, hi int) ([]int, bool) {
	seen := map[int]bool{}
	for _, part := range strings.Split(field, ",") {
		rng, step, hasStep := strings.Cut(part, "/")
		n := 1
		if hasStep {
			var err error
			if n, err = strconv.Atoi(step); err != nil || n < 1 {
				return nil, false
			}
		}
		from, to := lo, hi
		if rng != "*" {
			a, b, isRange := strings.Cut(rng, "-")
			var ok bool
			if from, ok = cronNumber(a); !ok {
				return nil, false
			}
			to = from
			if isRange {
				if to, ok = cronNumber(b); !ok {
					return nil, false
				}
			} else if hasStep {
				to = hi
			}
		}
		if from < lo || to > hi+1 || from > to {
			return nil, false
		}
		for v := from; v <= to; v += n {
			seen[v] = true
		}
	}
	var all []int
	for v := range seen {
		all = append(all, v)
	}
	sort.Ints(all)
	return all, len(all) > 0
}

func cronNumber(s string) (int, bool) {
	if n, ok := cronDow[strings.ToLower(s)]; ok {
		return n, true
	}
	n, err := strconv.Atoi(s)
	return n, err == nil
}

func join(values []int) string {
	var s []string
	for _, v := range values {
		s = append(s, strconv.Itoa(v))
	}
	return strings.Join(s, ",")
}

func floorDiv(a, b int) int {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

// cronUTC moves a cron line from the machine's local time to UTC. offset is how many minutes
// local time is ahead of UTC. It says no for lines it cannot move without changing their meaning.
func cronUTC(f [5]string, offset int) (string, bool) {
	if offset == 0 {
		return strings.Join(f[:], " "), true
	}
	minute, hour, dom, mon, dow := f[0], f[1], f[2], f[3], f[4]
	if hour == "*" && (minute == "*" || offset%60 == 0) {
		return strings.Join(f[:], " "), true
	}
	mins, ok := expand(minute, 0, 59)
	if !ok {
		return "", false
	}
	if hour == "*" {
		var out []int
		for _, m := range mins {
			out = append(out, ((m-offset)%60+60)%60)
		}
		sort.Ints(out)
		return strings.Join([]string{join(out), "*", dom, mon, dow}, " "), true
	}
	hours, ok := expand(hour, 0, 23)
	if !ok || (len(mins) > 1 && offset%60 != 0) {
		return "", false
	}
	day := 0
	var outH []int
	for i, h := range hours {
		total := h*60 + mins[0] - offset
		d := floorDiv(total, 1440)
		if i > 0 && d != day {
			if dom != "*" || dow != "*" {
				return "", false
			}
			d = 0
		}
		day = d
		outH = append(outH, (total%1440+1440)%1440/60)
	}
	outMinute := minute
	if len(mins) == 1 {
		outMinute = strconv.Itoa(((mins[0]-offset)%60 + 60) % 60)
	}
	sort.Ints(outH)
	if day != 0 {
		if dom != "*" {
			return "", false
		}
		if dow != "*" {
			days, ok := expand(dow, 0, 7)
			if !ok {
				return "", false
			}
			var moved []int
			for _, d := range days {
				moved = append(moved, ((d+day)%7+7)%7)
			}
			sort.Ints(moved)
			dow = join(moved)
		}
	}
	return strings.Join([]string{outMinute, join(outH), dom, mon, dow}, " "), true
}

var cronShorthand = map[string]string{
	"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
	"@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
}

var cronVariable = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*\s*=`)

// parseCrontab reads crontab lines. A system file has a user name before the command.
func parseCrontab(lines []string, system bool, where string, offset int) (jobs []found) {
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") || cronVariable.MatchString(l) {
			continue
		}
		f := strings.Fields(l)
		var fields [5]string
		var rest []string
		if strings.HasPrefix(f[0], "@") {
			rest = f[1:]
			spec, ok := cronShorthand[strings.ToLower(f[0])]
			if ok {
				copy(fields[:], strings.Fields(spec))
			}
		} else if len(f) > 5 {
			copy(fields[:], f[:5])
			rest = f[5:]
		} else {
			continue
		}
		user := ""
		if system && len(rest) > 1 {
			user, rest = rest[0], rest[1:]
		}
		if len(rest) == 0 {
			continue
		}
		command := strings.Join(rest, " ")
		j := found{"name": cronName(rest), "source": "cron", "record": byWrapper, "command": shown(command), "where": where}
		if user != "" {
			j["user"] = user
		}
		switch {
		case fields[0] == "" && strings.EqualFold(f[0], "@reboot"):
			j["schedule_note"] = "Runs at boot, which is not a time of day."
		case fields[0] == "":
			j["schedule_note"] = "Its schedule could not be read."
		default:
			j["schedule"], j["schedule_note"] = shift(fields[0], fields[1], fields[2], fields[3], fields[4], offset)
		}
		jobs = append(jobs, j)
	}
	return jobs
}

var wrapperWords = map[string]bool{"sh": true, "bash": true, "zsh": true, "dash": true, "env": true, "python": true, "python3": true, "php": true, "node": true, "perl": true, "ruby": true, "flock": true, "nice": true, "ionice": true, "timeout": true, "nohup": true, "sudo": true, "cd": true}

func cronName(command []string) string {
	pick := ""
	for i, w := range command {
		if strings.HasPrefix(w, "-") || strings.Contains(w, "=") || w == "&&" || w == ";" || (i > 0 && command[i-1] == "cd") {
			continue
		}
		w = strings.Trim(w, `"'`)
		base := path.Base(w)
		if pick == "" {
			pick = base
		}
		if !wrapperWords[strings.TrimSuffix(base, filepath.Ext(base))] && !wrapperWords[base] {
			return strings.TrimSuffix(base, filepath.Ext(base))
		}
	}
	if pick == "" {
		return "cron job"
	}
	return pick
}

func findCron() (jobs []found) {
	offset := zoneMinutes()
	if lines := output("crontab", "-l"); lines != nil {
		jobs = append(jobs, parseCrontab(lines, false, "this account's crontab", offset)...)
	}
	files, _ := filepath.Glob("/etc/cron.d/*")
	for _, file := range append([]string{"/etc/crontab"}, files...) {
		if b, err := os.ReadFile(file); err == nil {
			jobs = append(jobs, parseCrontab(strings.Split(string(b), "\n"), true, file, offset)...)
		}
	}
	if os.Geteuid() == 0 {
		spools, _ := filepath.Glob("/var/spool/cron/crontabs/*")
		more, _ := filepath.Glob("/var/spool/cron/*")
		for _, file := range append(spools, more...) {
			if b, err := os.ReadFile(file); err == nil {
				for _, j := range parseCrontab(strings.Split(string(b), "\n"), false, file, offset) {
					j["user"] = filepath.Base(file)
					jobs = append(jobs, j)
				}
			}
		}
	}
	return jobs
}

// systemd timers.

// timerNames reads the timers out of systemctl list-timers --all --no-legend --plain.
func timerNames(lines []string) (all []string) {
	for _, l := range lines {
		for _, w := range strings.Fields(l) {
			if strings.HasSuffix(w, ".timer") {
				all = append(all, w)
				break
			}
		}
	}
	return all
}

// showBlocks reads the output of systemctl show for several units: Key=Value lines, a blank
// line between units.
func showBlocks(lines []string) (blocks []map[string]string) {
	one := map[string]string{}
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			if len(one) > 0 {
				blocks = append(blocks, one)
				one = map[string]string{}
			}
			continue
		}
		if k, v, ok := strings.Cut(l, "="); ok {
			one[k] = v
		}
	}
	if len(one) > 0 {
		blocks = append(blocks, one)
	}
	return blocks
}

var onCalendar = regexp.MustCompile(`OnCalendar=([^;}]*?)\s*(?:;|\})`)

var systemdKeywords = map[string]string{
	"minutely": "* * * * *", "hourly": "0 * * * *", "daily": "0 0 * * *", "weekly": "0 0 * * 1",
	"monthly": "0 0 1 * *", "yearly": "0 0 1 1 *", "annually": "0 0 1 1 *",
}

// calendarCron reads a systemd calendar expression of the common shapes: a keyword, or
// [days] [*-*-*|*-*-DD|*-MM-DD] HH:MM[:SS], or *:MM and */N minute steps.
func calendarCron(expr string, offset int) (string, string) {
	words := strings.Fields(expr)
	local := true
	if n := len(words); n > 0 && (words[n-1] == "UTC" || words[n-1] == "utc") {
		words, local = words[:n-1], false
	}
	if len(words) == 0 {
		return "", "Its schedule could not be put in a cron line."
	}
	off := offset
	if !local {
		off = 0
	}
	if kw, ok := systemdKeywords[strings.ToLower(words[0])]; ok && len(words) == 1 {
		f := strings.Fields(kw)
		return shift(f[0], f[1], f[2], f[3], f[4], off)
	}
	dow, date, clock := "*", "*-*-*", ""
	for _, w := range words {
		switch {
		case strings.Contains(w, ".."):
			return "", "Its schedule could not be put in a cron line."
		case strings.Contains(w, ":"):
			clock = w
		case strings.Count(w, "-") == 2 && !strings.ContainsAny(w, "~"):
			date = w
		default:
			var list []string
			for _, d := range strings.Split(strings.ToLower(w), ",") {
				n, ok := cronDow[d[:min(3, len(d))]]
				if !ok {
					return "", "Its schedule could not be put in a cron line."
				}
				list = append(list, strconv.Itoa(n))
			}
			dow = strings.Join(list, ",")
		}
	}
	d := strings.Split(date, "-")
	if clock == "" || len(d) != 3 || d[0] != "*" {
		return "", "Its schedule could not be put in a cron line."
	}
	c := strings.Split(clock, ":")
	hour, minute := c[0], c[1]
	if strings.Contains(hour, "/") && !strings.HasPrefix(hour, "*") {
		hour = strings.Replace(hour, "/", "-23/", 1)
	}
	if strings.Contains(minute, "/") && !strings.HasPrefix(minute, "*") {
		minute = strings.Replace(minute, "/", "-59/", 1)
	}
	return shift(clean(minute), clean(hour), clean(d[2]), clean(d[1]), dow, off)
}

var digits = regexp.MustCompile(`\d+`)

// clean writes 01 as 1 in each number of a field.
func clean(field string) string {
	return digits.ReplaceAllStringFunc(field, func(d string) string {
		n, _ := strconv.Atoi(d)
		return strconv.Itoa(n)
	})
}

var systemdTime = "Mon 2006-01-02 15:04:05 MST"

func systemdWhen(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || s == "n/a" {
		return ""
	}
	if t, err := time.ParseInLocation(systemdTime, s, time.Local); err == nil {
		return t.UTC().Format(time.RFC3339)
	}
	return ""
}

func timerJob(timer, service map[string]string, offset int) (found, bool) {
	name := strings.TrimSuffix(timer["Id"], ".timer")
	if name == "" || strings.HasPrefix(name, "systemd-") {
		return nil, false
	}
	j := found{"name": name, "source": "systemd-timer", "record": byRecord, "unit": timer["Id"]}
	if d := timer["Description"]; d != "" {
		j["description"] = d
	}
	if cal := onCalendar.FindStringSubmatch(timer["TimersCalendar"]); cal != nil {
		if strings.Count(timer["TimersCalendar"], "OnCalendar=") > 1 {
			j["schedule_note"] = "Has several calendar times, which one cron line cannot say."
		} else {
			j["schedule"], j["schedule_note"] = calendarCron(cal[1], offset)
		}
	} else {
		j["schedule_note"] = "Runs a set time after boot or after its last run, not at a time of day."
	}
	if i := strings.Index(service["ExecStart"], "argv[]="); i >= 0 {
		argv, _, _ := strings.Cut(service["ExecStart"][i+7:], " ;")
		j["command"] = shown(argv)
	}
	j["last_run"] = systemdWhen(timer["LastTriggerUSec"])
	if j["last_run"] != "" {
		j["last_result"] = "ok"
		if r := service["Result"]; r != "" && r != "success" {
			j["last_result"] = "failed (" + r + ")"
		}
	}
	return j, true
}

func findTimers() (jobs []found) {
	names := timerNames(output("systemctl", "list-timers", "--all", "--no-legend", "--plain"))
	if len(names) == 0 {
		return nil
	}
	props := []string{"-p", "Id", "-p", "Description", "-p", "TimersCalendar", "-p", "TimersMonotonic", "-p", "LastTriggerUSec", "-p", "Unit"}
	timers := showBlocks(output("systemctl", append(append([]string{"show"}, props...), names...)...))
	services := make([]string, len(timers))
	for i, t := range timers {
		services[i] = t["Unit"]
	}
	sp := []string{"-p", "Id", "-p", "Result", "-p", "ExecStart"}
	byID := map[string]map[string]string{}
	for _, s := range showBlocks(output("systemctl", append(append([]string{"show"}, sp...), services...)...)) {
		byID[s["Id"]] = s
	}
	for _, t := range timers {
		if j, ok := timerJob(t, byID[t["Unit"]], zoneMinutes()); ok {
			jobs = append(jobs, j)
		}
	}
	return jobs
}

// launchd.

// parseLaunchd reads a launchd property list that plutil -convert json wrote.
func parseLaunchd(plist map[string]any, file string, offset int) (found, bool) {
	label, _ := plist["Label"].(string)
	if label == "" || strings.HasPrefix(label, "com.apple.") {
		return nil, false
	}
	j := found{"name": label, "source": "launchd", "record": byWrapper, "unit": label, "where": file}
	var argv []string
	if a, ok := plist["ProgramArguments"].([]any); ok {
		for _, w := range a {
			argv = append(argv, fmt.Sprint(w))
		}
	} else if p, ok := plist["Program"].(string); ok {
		argv = []string{p}
	}
	if len(argv) > 0 {
		j["command"] = shown(strings.Join(argv, " "))
	}
	number := func(m map[string]any, k string) (string, bool) {
		v, ok := m[k].(float64)
		return strconv.Itoa(int(v)), ok
	}
	switch cal := plist["StartCalendarInterval"].(type) {
	case map[string]any:
		get := func(k string) string {
			if v, ok := number(cal, k); ok {
				return v
			}
			return "*"
		}
		j["schedule"], j["schedule_note"] = shift(get("Minute"), get("Hour"), get("Day"), get("Month"), get("Weekday"), offset)
	case []any:
		j["schedule_note"] = "Has several calendar times, which one cron line cannot say."
	default:
		if s, ok := plist["StartInterval"].(float64); ok && s >= 60 {
			if int(s)%60 == 0 {
				j["schedule"], j["schedule_note"] = repeating(0, 0, int(s)/60, 0)
			} else {
				j["schedule_note"] = fmt.Sprintf("Runs every %d seconds, which a cron line cannot say.", int(s))
			}
		} else {
			return nil, false
		}
	}
	return j, true
}

func jsonFromPlist(file string, into any) error {
	out, err := exec.Command("plutil", "-convert", "json", "-o", "-", file).Output()
	if err != nil {
		return err
	}
	return json.Unmarshal(out, into)
}

func findLaunchd() (jobs []found) {
	home, _ := os.UserHomeDir()
	for _, dir := range []string{filepath.Join(home, "Library/LaunchAgents"), "/Library/LaunchAgents", "/Library/LaunchDaemons"} {
		files, _ := filepath.Glob(filepath.Join(dir, "*.plist"))
		for _, file := range files {
			var plist map[string]any
			if err := jsonFromPlist(file, &plist); err != nil {
				continue
			}
			if j, ok := parseLaunchd(plist, file, zoneMinutes()); ok {
				for _, l := range output("launchctl", "list", fmt.Sprint(plist["Label"])) {
					if strings.Contains(l, `"LastExitStatus"`) {
						code := strings.Trim(strings.TrimSpace(strings.SplitN(l, "=", 2)[1]), "; ")
						j["last_result"] = "ok"
						if code != "0" {
							j["last_result"] = "failed, status " + code
						}
					}
				}
				jobs = append(jobs, j)
			}
		}
	}
	return jobs
}
