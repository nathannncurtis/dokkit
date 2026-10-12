package main

import (
	"context"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	originSystem   = "system"
	originSoftware = "software"
	originYours    = "yours"
)

func mark(f found, origin, why string) found {
	f["origin"], f["why"] = origin, why
	return f
}

func rank(origin string) int {
	switch origin {
	case originYours:
		return 0
	case originSoftware:
		return 1
	}
	return 2
}

func isDokkit(parts ...string) bool {
	for _, p := range parts {
		if strings.Contains(strings.ToLower(p), "dokkit") {
			return true
		}
	}
	return false
}

// outputLoose keeps what a tool printed even when it exits with an error, as dpkg-query does for a path nobody owns.
func outputLoose(name string, args ...string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, _ := exec.CommandContext(ctx, name, args...).Output()
	return strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n")
}

// Windows.

var winVariable = regexp.MustCompile(`%([^%]+)%`)

var winDefaults = map[string]string{
	"systemroot": `C:\Windows`, "windir": `C:\Windows`, "programfiles": `C:\Program Files`,
	"programfiles(x86)": `C:\Program Files (x86)`, "programdata": `C:\ProgramData`,
}

func expandWin(s string) string {
	return winVariable.ReplaceAllStringFunc(s, func(m string) string {
		name := m[1 : len(m)-1]
		if v := os.Getenv(name); v != "" {
			return v
		}
		if v, ok := winDefaults[strings.ToLower(name)]; ok {
			return v
		}
		return m
	})
}

var programExt = regexp.MustCompile(`(?i)\.(exe|sys|bat|cmd|com|dll)$`)

// programOf is the program file at the start of a command line.
func programOf(cmd string) string {
	cmd = strings.TrimPrefix(strings.TrimSpace(cmd), `\??\`)
	if strings.HasPrefix(cmd, `"`) {
		if end := strings.Index(cmd[1:], `"`); end >= 0 {
			return expandWin(cmd[1 : 1+end])
		}
	}
	words := strings.Fields(strings.ReplaceAll(cmd, `"`, ""))
	for i := range words {
		if programExt.MatchString(words[i]) {
			return expandWin(strings.Join(words[:i+1], " "))
		}
		if i+1 < len(words) && strings.ContainsAny(words[i+1][:1], "-/") {
			break
		}
	}
	if len(words) == 0 {
		return ""
	}
	return expandWin(words[0])
}

func winBase(p string) string { return strings.ToLower(p[strings.LastIndex(p, `\`)+1:]) }

var appData = regexp.MustCompile(`^\\users\\[^\\]+\\appdata\\(local|roaming)\\[^\\]+\\`)

// winKind says where a program file lives: windows, driver (a vendor's file in the Windows driver store), program (Program Files, ProgramData), appdata (an installer's folder in a user's app data) or other. Empty when the place is not known.
func winKind(p string) string {
	l := strings.ToLower(strings.ReplaceAll(p, "/", `\`))
	if !strings.Contains(l, `\`) {
		return ""
	}
	if len(l) > 1 && l[1] == ':' {
		l = l[2:]
	}
	l = strings.TrimPrefix(l, `\??`)
	switch {
	case strings.HasPrefix(l, `\systemroot\`), strings.HasPrefix(l, `system32\`), strings.HasPrefix(l, `\windows\`):
		if strings.Contains(l, `\driverstore\`) {
			return "driver"
		}
		return "windows"
	case strings.HasPrefix(l, `\program files\`), strings.HasPrefix(l, `\program files (x86)\`), strings.HasPrefix(l, `\programdata\`):
		if strings.Contains(l, `\windows defender\`) || strings.Contains(l, `\microsoft defender\`) || strings.Contains(l, `\windows defender advanced threat protection\`) || strings.HasPrefix(l, `\program files\wsl\`) {
			return "windows"
		}
		return "program"
	case appData.MatchString(l) && !strings.Contains(l, `\temp\`):
		return "appdata"
	}
	return "other"
}

func installedUnder(p string) string {
	parts, n := strings.Split(p, `\`), 3
	if winKind(p) == "appdata" {
		n = 6
	}
	if len(parts) > n {
		parts = parts[:n]
	}
	return strings.Join(parts, `\`)
}

func winExeOrigin(p string) (string, string) {
	switch winKind(p) {
	case "windows":
		return originSystem, "Windows component (" + p + ")"
	case "driver":
		return originSoftware, "Driver utility installed by a hardware vendor (" + p + ")"
	case "program":
		return originSoftware, "Installed under " + installedUnder(p)
	case "appdata":
		if winInterpreters[winBase(p)] {
			return originYours, "Script engine run from a user's app data folder (" + p + ")"
		}
		return originSoftware, "Installed under " + installedUnder(p)
	case "other":
		return originYours, "Program outside Windows, Program Files and ProgramData (" + p + ")"
	}
	return originYours, "Program file not known"
}

var userServiceInstance = regexp.MustCompile(`_[0-9a-fA-F]{4,}$`)

// winServiceOrigin decides from the service's executable (image) and the real program it stands for: the NSSM application, or the DLL a Windows service host loads.
func winServiceOrigin(name, image, real string) (string, string) {
	exe, lower := programOf(image), strings.ToLower(name)
	switch {
	case strings.HasPrefix(lower, "dokkit") || isDokkit(exe):
		return originSoftware, "Dokkit itself"
	case exe != "" && winBase(exe) == "nssm.exe":
		why := "Set up with NSSM (" + exe + ")"
		if real != "" {
			why += ", runs " + programOf(real)
		}
		return originYours, why
	case strings.Contains(strings.ToLower(exe), `\actions-runner\`) || strings.HasPrefix(lower, "actions.runner"):
		return originYours, "GitHub Actions runner (" + exe + ")"
	case exe == "" && userServiceInstance.MatchString(name):
		return originSystem, "Per-user instance of a Windows service"
	}
	if winBase(exe) == "svchost.exe" && real != "" {
		return winExeOrigin(programOf(real))
	}
	return winExeOrigin(exe)
}

var winInterpreters = map[string]bool{"cmd.exe": true, "powershell.exe": true, "pwsh.exe": true, "wscript.exe": true, "cscript.exe": true, "python.exe": true, "pythonw.exe": true, "cmd": true, "powershell": true, "pwsh": true}

var scriptPath = regexp.MustCompile(`(?i)"?([a-z]:\\[^"]*?\.(?:exe|bat|cmd|ps1|vbs|py|js))`)

// taskTarget is the program a task runs; for a shell or script engine, the script it was given.
func taskTarget(command string) string {
	exe := programOf(command)
	if !winInterpreters[winBase(exe)] {
		return exe
	}
	if m := scriptPath.FindStringSubmatch(expandWin(command)); m != nil && !strings.EqualFold(m[1], exe) {
		return m[1]
	}
	return ""
}

func winTaskOrigin(task, command, author string) (string, string) {
	if isDokkit(task, command) {
		return originSoftware, "Dokkit itself"
	}
	target := taskTarget(command)
	kind := winKind(target)
	vendor := author != "" && author != "N/A" && (!strings.Contains(author, `\`) || strings.HasPrefix(author, "$(") || strings.HasPrefix(author, "@"))
	switch {
	case kind == "program" || kind == "driver" || (kind == "appdata" && !winInterpreters[winBase(target)]):
		_, why := winExeOrigin(target)
		return originSoftware, why
	case strings.HasPrefix(strings.ToLower(task), `\microsoft\`):
		return originSystem, "Windows task (" + task + ")"
	case kind == "windows":
		return originSystem, "Runs a Windows program (" + target + ")"
	case vendor:
		return originSoftware, "Task added by " + author
	case kind == "other":
		return originYours, "Runs a program outside Windows, Program Files and ProgramData (" + target + ")"
	}
	return originYours, "Task program not known"
}

// winPortOrigin decides for the process that owns a port. A service that owns it (the process's own, or the one that started it, as NSSM does) decides; otherwise the program file's place does.
func winPortOrigin(process, file, service, svcOrigin, svcWhy string, inSystem32 bool) (string, string) {
	switch {
	case service != "":
		return svcOrigin, "Port of service " + service + ": " + svcWhy
	case strings.EqualFold(process, "System"):
		return originSystem, "Windows kernel (System process)"
	case file != "":
		return winExeOrigin(file)
	case inSystem32:
		return originSystem, "Windows component (" + process + ")"
	}
	return originYours, "owner not known"
}

// parseTasklist reads tasklist /svc /fo csv /nh rows into the program name and the services of each process id.
func parseTasklist(rows [][]string) (programs map[string]string, services map[string][]string) {
	programs, services = map[string]string{}, map[string][]string{}
	for _, row := range rows {
		if len(row) > 1 {
			programs[row[1]] = row[0]
		}
		if len(row) > 2 && row[2] != "N/A" {
			services[row[1]] = strings.Split(row[2], ",")
		}
	}
	return
}

// Linux.

type unitFacts struct{ Path, Real, Pkg, Priority string }

// auto is a package nobody chose by name: it came in as a dependency of the base system, which is how the distribution's own parts arrive.
var baseSystem = map[string]bool{"required": true, "important": true, "standard": true, "auto": true}

func under(p string, dirs ...string) bool {
	for _, d := range dirs {
		if strings.HasPrefix(p, d) {
			return true
		}
	}
	return false
}

func shippedBy(pkg, priority, file string) (string, string) {
	if baseSystem[priority] {
		return originSystem, "Unit shipped by base package " + pkg + " (" + file + ")"
	}
	return originSoftware, "Unit shipped by package " + pkg + " (" + file + ")"
}

func unitOrigin(unit string, f unitFacts) (string, string) {
	loc := f.Real
	if loc == "" {
		loc = f.Path
	}
	switch {
	case strings.HasPrefix(unit, "dokkit"):
		return originSoftware, "Dokkit itself"
	case loc == "":
		return originYours, "Unit file not known"
	case under(loc, "/usr/lib/systemd/system/", "/lib/systemd/system/"):
		if f.Pkg == "" {
			return originSystem, "Unit in the distribution's folder (" + loc + ")"
		}
		return shippedBy(f.Pkg, f.Priority, loc)
	case under(loc, "/run/systemd/generator"):
		return originSystem, "Generated by systemd (" + loc + ")"
	case under(loc, "/etc/systemd/system/") && f.Pkg != "":
		return shippedBy(f.Pkg, f.Priority, loc)
	}
	return originYours, "Unit added in " + path.Dir(loc)
}

// cgroupUnit is the innermost service a process runs in, from /proc/<pid>/cgroup, and whether it runs in a login session instead.
func cgroupUnit(cgroup string) (unit string, session bool) {
	for _, l := range strings.Split(cgroup, "\n") {
		if i := strings.LastIndex(l, ":"); i >= 0 && (strings.HasPrefix(l, "0::") || strings.Contains(l, "name=systemd")) {
			for _, seg := range strings.Split(l[i+1:], "/") {
				if strings.HasSuffix(seg, ".service") {
					unit = seg
				}
				if strings.HasPrefix(seg, "session-") || seg == "user.slice" {
					session = true
				}
			}
		}
	}
	return unit, session && unit == ""
}

func portUnitOrigin(unit string, session bool, unitO, unitW string) (string, string) {
	switch {
	case unit != "":
		return unitO, "Port of " + unit + ": " + unitW
	case session:
		return originYours, "Started from a login session"
	}
	return originYours, "owner not known"
}

func altUsrPath(p string) string {
	if strings.HasPrefix(p, "/usr/lib/systemd/") {
		return p[4:]
	}
	return p
}

// parseDpkgOwners reads dpkg-query -S output: "pkg[, pkg]: /path".
func parseDpkgOwners(lines []string) map[string]string {
	owners := map[string]string{}
	for _, l := range lines {
		pkgs, file, ok := strings.Cut(l, ": ")
		if !ok || strings.HasPrefix(l, "dpkg-query:") || strings.HasPrefix(l, "diversion ") || !strings.HasPrefix(file, "/") {
			continue
		}
		owners[strings.TrimSpace(file)], _, _ = strings.Cut(pkgs, ",")
	}
	return owners
}

// parseDpkgPriorities reads dpkg-query -W -f '${Package}\t${Priority}\n' output.
func parseDpkgPriorities(lines []string) map[string]string {
	prio := map[string]string{}
	for _, l := range lines {
		if pkg, p, ok := strings.Cut(l, "\t"); ok {
			prio[pkg] = strings.TrimSpace(p)
		}
	}
	return prio
}

// packagesOf says which package owns each file, and that package's priority. rpm has no priority, so its packages count as standard.
func packagesOf(files []string) (pkg, priority map[string]string) {
	pkg, priority = map[string]string{}, map[string]string{}
	if len(files) == 0 {
		return
	}
	if _, err := exec.LookPath("dpkg-query"); err == nil {
		var ask []string
		for _, f := range files {
			ask = append(ask, f)
			if alt := altUsrPath(f); alt != f {
				ask = append(ask, alt)
			}
		}
		owners := parseDpkgOwners(outputLoose("dpkg-query", append([]string{"-S"}, ask...)...))
		var names []string
		for _, f := range files {
			if p := owners[f]; p != "" {
				pkg[f] = p
			} else if p := owners[altUsrPath(f)]; p != "" {
				pkg[f] = p
			}
		}
		for _, p := range pkg {
			names = append(names, p)
		}
		if len(names) > 0 {
			priority = parseDpkgPriorities(outputLoose("dpkg-query", append([]string{"-W", "-f", "${Package}\t${Priority}\n"}, names...)...))
			auto := map[string]bool{}
			for _, l := range output("apt-mark", "showauto") {
				auto[l] = true
			}
			for p, pr := range priority {
				if auto[p] && !baseSystem[pr] {
					priority[p] = "auto"
				}
			}
		}
		return
	}
	if _, err := exec.LookPath("rpm"); err == nil {
		for i, l := range outputLoose("rpm", append([]string{"-qf", "--qf", "%{NAME}\n"}, files...)...) {
			if i < len(files) && l != "" && !strings.HasPrefix(l, "file ") {
				pkg[files[i]], priority[l] = l, "standard"
			}
		}
	}
	return
}

// linuxOrigins decides for systemd units (names with their .service or .timer ending) from where systemd found the unit file and which package owns it.
func linuxOrigins(units []string) map[string][2]string {
	out := map[string][2]string{}
	if len(units) == 0 {
		return out
	}
	facts := map[string]unitFacts{}
	var files []string
	for _, b := range showBlocks(output("systemctl", append([]string{"show", "-p", "Id", "-p", "FragmentPath"}, units...)...)) {
		f := unitFacts{Path: b["FragmentPath"]}
		if f.Path != "" {
			if f.Real, _ = filepath.EvalSymlinks(f.Path); f.Real == "" {
				f.Real = f.Path
			}
			files = append(files, f.Real)
		}
		facts[b["Id"]] = f
	}
	pkg, priority := packagesOf(files)
	for _, u := range units {
		f := facts[u]
		f.Pkg = pkg[f.Real]
		f.Priority = priority[f.Pkg]
		o, w := unitOrigin(u, f)
		out[u] = [2]string{o, w}
	}
	return out
}

// Cron.

func cronOrigin(where, command, pkg, priority string, qnap bool) (string, string) {
	switch {
	case isDokkit(command):
		return originSoftware, "Dokkit itself"
	case qnap:
		return qnapOrigin(command)
	case where == "/etc/crontab":
		if strings.Contains(command, "run-parts") {
			return originSystem, "Run-parts line of /etc/crontab"
		}
		return originYours, "Line added to /etc/crontab"
	case strings.HasPrefix(where, "/etc/cron.d/") && pkg != "":
		if baseSystem[priority] {
			return originSystem, "Cron file shipped by base package " + pkg + " (" + where + ")"
		}
		return originSoftware, "Cron file shipped by package " + pkg + " (" + where + ")"
	case strings.HasPrefix(where, "/etc/cron.d/"):
		return originYours, "Cron file added in /etc/cron.d (" + where + ")"
	}
	return originYours, "Crontab of a person (" + where + ")"
}

var shellWords = map[string]bool{"/bin/sh": true, "sh": true, "/bin/bash": true, "bash": true, "-c": true, "source": true, ".": true, "env": true, "exec": true, "nice": true, "cd": true, "&&": true, ";": true}

// firstCommandPath is the program a cron command starts, with bare names found on the path.
func firstCommandPath(command string, look func(string) (string, error)) string {
	for _, w := range strings.Fields(strings.NewReplacer("(", " ", ")", " ", `"`, " ", "'", " ").Replace(command)) {
		if shellWords[w] || strings.HasPrefix(w, "-") || strings.Contains(w, "=") {
			continue
		}
		if strings.Contains(w, "/") {
			return w
		}
		if p, err := look(w); err == nil {
			return p
		}
		return ""
	}
	return ""
}

// Add-ons run from .qpkg or /mnt/ext/opt, and the QNAP app center tags the cron lines it writes with #_QSC_ or #_SA_.
var qnapAddon = regexp.MustCompile(`\.qpkg|/mnt/ext/opt|#_(QSC|SA)_`)

func qnapOrigin(command string) (string, string) {
	p := firstCommandPath(command, lookPath)
	switch {
	case qnapAddon.MatchString(command):
		return originSoftware, "QNAP add-on (" + p + ")"
	case p == "":
		return originYours, "Command not known"
	case under(p, "/share/", "/home/", "/root/", "/tmp/"):
		return originYours, "Script outside the firmware (" + p + ")"
	}
	return originSystem, "Firmware job (" + p + ")"
}

func qnapNAS() bool {
	_, err := os.Stat("/etc/config/uLinux.conf")
	return err == nil
}

// cronOrigins marks the jobs of findCron.
func cronOrigins(jobs []found) {
	nas := qnapNAS()
	var files []string
	for _, j := range jobs {
		if strings.HasPrefix(j["where"], "/etc/cron.d/") {
			files = append(files, j["where"])
		}
	}
	pkg, priority := packagesOf(files)
	for _, j := range jobs {
		o, w := cronOrigin(j["where"], j["command"], pkg[j["where"]], priority[pkg[j["where"]]], nas)
		mark(j, o, w)
	}
}

// macOS.

func macOrigin(label, file, program, home string) (string, string) {
	switch {
	case isDokkit(label):
		return originSoftware, "Dokkit itself"
	case strings.HasPrefix(label, "com.apple.") || under(program, "/System/", "/usr/libexec/", "/Library/Apple/"):
		return originSystem, "macOS job (" + label + ")"
	case under(program, "/Applications/"):
		return originSoftware, "Installed with an application (" + program + ")"
	case under(program, "/usr/local/") || (home != "" && (under(program, home+"/") || under(file, home+"/"))):
		return originYours, "Added by a person (" + file + ")"
	case under(file, "/Library/LaunchDaemons/", "/Library/LaunchAgents/"):
		return originSoftware, "Installed by another vendor (" + file + ")"
	}
	return originYours, "Added by a person (" + file + ")"
}

func serviceOrigin(name string) (string, string) {
	image, real := winServiceFacts(name)
	return winServiceOrigin(name, image, real)
}

var lookPath = exec.LookPath
