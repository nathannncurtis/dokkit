package main

import (
	"errors"
	"strings"
	"testing"
)

func TestProgramOfACommandLine(t *testing.T) {
	for in, want := range map[string]string{
		`"C:\Program Files\Contoso\agent.exe" -k run`:          `C:\Program Files\Contoso\agent.exe`,
		`C:\Program Files\Contoso\agent.exe -k run`:            `C:\Program Files\Contoso\agent.exe`,
		`C:\Windows\system32\svchost.exe -k netsvcs -p`:        `C:\Windows\system32\svchost.exe`,
		`\??\C:\Windows\system32\drivers\thing.sys`:            `C:\Windows\system32\drivers\thing.sys`,
		`cmd /c C:\Tools\nightly.bat`:                          `cmd`,
		`C:\Tools\nssm\nssm.exe`:                               `C:\Tools\nssm\nssm.exe`,
		`C:\Users\sam\AppData\Local\Fabrikam\updater.exe" /ua`: `C:\Users\sam\AppData\Local\Fabrikam\updater.exe`,
		"": "",
	} {
		if got := programOf(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestWhereAWindowsProgramLives(t *testing.T) {
	for in, want := range map[string]string{
		`C:\Windows\System32\svchost.exe`:                                          "windows",
		`\SystemRoot\System32\drivers\disk.sys`:                                    "windows",
		`System32\drivers\3ware.sys`:                                               "windows",
		`C:\Windows\System32\DriverStore\FileRepository\audio.inf_amd64_1\svc.exe`: "driver",
		`C:\Program Files\Contoso\agent.exe`:                                       "program",
		`D:\Program Files (x86)\Fabrikam\x.exe`:                                    "program",
		`C:\ProgramData\Contoso\Updater\u.exe`:                                     "program",
		`C:\ProgramData\Microsoft\Windows Defender\Platform\4.18\MsMpEng.exe`:      "windows",
		`C:\ProgramData\Microsoft\Microsoft Defender\Platform\4.18\MsMpEng.exe`:    "windows",
		`C:\Program Files\WSL\wslservice.exe`:                                      "windows",
		`C:\Users\sam\AppData\Local\Fabrikam\Update\updater.exe`:                   "appdata",
		`C:\Users\sam\AppData\Local\Temp\setup.exe`:                                "other",
		`C:\Tools\runner\run.exe`:                                                  "other",
		`C:\Users\sam\scripts\run.exe`:                                             "other",
		`cmd`:                                                                      "",
		``:                                                                         "",
	} {
		if got := winKind(in); got != want {
			t.Errorf("%s: %q, want %q", in, got, want)
		}
	}
}

func TestWindowsServiceOrigins(t *testing.T) {
	for _, c := range []struct{ name, image, real, origin, why string }{
		{"Dnscache", `C:\Windows\system32\svchost.exe -k NetworkService -p`, `C:\Windows\System32\dnsrslvr.dll`, "system", "Windows component"},
		{"Spooler", `%SystemRoot%\System32\spoolsv.exe`, "", "system", "Windows component"},
		{"BluetoothUserService_14586e4", `C:\Windows\system32\svchost.exe -k BthAppGroup -p`, "", "system", "Windows component"},
		{"AgentInstance_1a2b3c", "", "", "system", "Per-user instance"},
		{"sshd", `C:\Windows\System32\OpenSSH\sshd.exe`, "", "system", "Windows component"},
		{"WinDefend", `"C:\ProgramData\Microsoft\Windows Defender\Platform\4.18\MsMpEng.exe"`, "", "system", "Windows component"},
		{"Fabrikam Audio", `C:\Windows\System32\DriverStore\FileRepository\fab.inf_amd64_1\FabSvc.exe`, "", "software", "Driver utility"},
		{"ClickToRunSvc", `"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe" /service`, "", "software", "Installed under C:\\Program Files\\Common Files"},
		{"edgeupdate", `"C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe" /svc`, "", "software", "Installed under"},
		{"MSSQLSERVER", `"C:\Program Files\Microsoft SQL Server\MSSQL16\Binn\sqlservr.exe" -sMSSQLSERVER`, "", "software", "Installed under"},
		{"ThirdPartyHost", `C:\Windows\system32\svchost.exe -k thirdparty`, `C:\Program Files\Contoso\hosted.dll`, "software", "Installed under C:\\Program Files\\Contoso"},
		{"ContosoAgent", `"C:\ProgramData\Contoso\agent\agent.exe"`, "", "software", "Installed under C:\\ProgramData\\Contoso"},
		{"OrderSync", `C:\Tools\nssm\nssm.exe`, `C:\Apps\ordersync\sync.exe`, "yours", "Set up with NSSM (C:\\Tools\\nssm\\nssm.exe), runs C:\\Apps\\ordersync\\sync.exe"},
		{"Inventory", `"C:\Program Files\nssm-2.24\win64\nssm.exe"`, "", "yours", "Set up with NSSM"},
		{"actions.runner.org-repo.build1", `C:\actions-runner\bin\RunnerService.exe`, "", "yours", "GitHub Actions runner"},
		{"LabelPrinter", `C:\Apps\labels\printer-service.exe`, "", "yours", "outside Windows, Program Files and ProgramData"},
		{"dokkit", `"C:\Program Files\DokkitProgram\dokkit.exe" service run`, "", "dokkit", "Dokkit itself"},
		{"dokkit-postgres", `C:\Program Files\Dokkit\pg\bin\pg_ctl.exe`, "", "dokkit", "Dokkit itself"},
		{"dokkit0123456789abcdef", `"C:\Program Files\Dokkit\erts-15.2\bin\erlsrv.exe"`, "", "dokkit", "Dokkit itself"},
		{"dokkit_dokkit", "", "", "dokkit", "Dokkit itself"},
		{"dokkit-server", `"C:\Program Files\Dokkit\erts-15.2\bin\erlsrv.exe"`, "", "dokkit", "Dokkit itself"},
		{"dokkit-lookalike", `C:\Apps\lookalike\svc.exe`, "", "yours", "outside Windows"},
		{"ErlangApp", `"C:\Program Files\Contoso\erts-15.2\bin\erlsrv.exe"`, "", "software", "Installed under"},
		{"Mystery", "", "", "yours", "not known"},
	} {
		o, w := winServiceOrigin(c.name, c.image, c.real)
		if o != c.origin || !strings.Contains(w, c.why) {
			t.Errorf("%s: %s, %q; want %s containing %q", c.name, o, w, c.origin, c.why)
		}
	}
}

func TestWindowsTaskOrigins(t *testing.T) {
	for _, c := range []struct{ task, command, author, origin string }{
		{`\Microsoft\Windows\Defrag\ScheduledDefrag`, `%windir%\system32\defrag.exe -c -h -o -$`, "Microsoft Corporation", "system"},
		{`\Microsoft\Windows\Work Folders\Logon`, "COM handler", "N/A", "system"},
		{`\Microsoft\Office\Office Automatic Updates 2.0`, `"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe" /update`, "Microsoft Corporation", "software"},
		{`\CleanupTemp`, `C:\Windows\System32\cleanmgr.exe /autoclean`, "N/A", "system"},
		{`\FabrikamUpdateCore`, `"C:\Users\sam\AppData\Local\Fabrikam\Update\FabUpdate.exe" /c`, "N/A", "software"},
		{`\ContosoSync`, `"C:\Users\sam\AppData\Local\Contoso\Sync.exe"`, `PC1\sam`, "software"},
		{`\FabrikamAutoUpdate`, `"C:\Program Files\Fabrikam\Updater\up.exe" -check`, "Fabrikam", "software"},
		{`\Mozilla\Background Update`, `C:\Program Files\Mozilla Firefox\firefox.exe --backgroundtask`, "Mozilla", "software"},
		{`\ContosoVendorTask`, `C:\Tools\vendor.exe`, "Contoso Ltd", "software"},
		{`\nightly-copy`, `C:\Tools\copy.bat`, `PC1\sam`, "yours"},
		{`\nightly-report`, `powershell.exe -File C:\Scripts\report.ps1`, `PC1\sam`, "yours"},
		{`\report-cmd`, `cmd /c C:\Scripts\report.bat`, `PC1\sam`, "yours"},
		{`\report-cmd-vendor-author`, `cmd /c C:\Scripts\report.bat`, "Fabrikam IT", "software"},
		{`\Somebody\Backup`, `C:\Windows\System32\robocopy.exe C:\a D:\b`, `PC1\sam`, "system"},
		{`\Odd`, "Multiple actions", "N/A", "yours"},
		{`\SoftLanding\S-1-5-21-1\SoftLandingTask`, "COM handler", "N/A", "yours"},
		{`\DokkitUpdater`, `"C:\Program Files\DokkitProgram\dokkit.exe" updater run`, "N/A", "dokkit"},
		{`\Dokkit updater`, `C:\Windows\System32\cmd.exe /c x`, "N/A", "dokkit"},
	} {
		if o, w := winTaskOrigin(c.task, c.command, c.author); o != c.origin || w == "" {
			t.Errorf("%s: %s, %q; want %s", c.task, o, w, c.origin)
		}
	}
}

func TestWindowsPortOrigins(t *testing.T) {
	for _, c := range []struct {
		name, process, file, service, svcOrigin, svcWhy, origin, why string
		inSystem32                                                   bool
	}{
		{"service", "svchost.exe", "", "Dnscache", "system", "Windows component", "system", "Port of service Dnscache", false},
		{"nssm child", "python.exe", "", "OrderSync", "yours", "Set up with NSSM", "yours", "Set up with NSSM", false},
		{"third party service", "contoso.exe", "", "ContosoAgent", "software", "Installed under C:\\Program Files\\Contoso", "software", "ContosoAgent", false},
		{"system process", "System", "", "", "", "", "system", "System process", false},
		{"windows folder", "lsass.exe", `C:\Windows\System32\lsass.exe`, "", "", "", "system", "Windows component", true},
		{"protected windows process", "wininit.exe", "", "", "", "", "system", "Windows component", true},
		{"program files", "contoso.exe", `C:\Program Files\Contoso\contoso.exe`, "", "", "", "software", "Installed under", false},
		{"person's python", "python.exe", `C:\Users\sam\AppData\Local\Programs\Python\Python312\python.exe`, "", "", "", "yours", "Script engine", false},
		{"person's tool", "tool.exe", `C:\work\tool.exe`, "", "", "", "yours", "outside Windows", false},
		{"nobody can say", "tool.exe", "", "", "", "", "yours", "owner not known", false},
	} {
		o, w := winPortOrigin(c.process, c.file, c.service, c.svcOrigin, c.svcWhy, c.inSystem32)
		if o != c.origin || !strings.Contains(w, c.why) {
			t.Errorf("%s: %s, %q", c.name, o, w)
		}
	}
}

func TestTasklistGivesProgramsAndServices(t *testing.T) {
	programs, services := parseTasklist([][]string{
		{"System", "4", "N/A"},
		{"svchost.exe", "1280", "Dnscache,RpcEptMapper"},
		{"nssm.exe", "5000", "OrderSync"},
		{"bad"},
	})
	if programs["1280"] != "svchost.exe" || len(services["1280"]) != 2 || services["4"] != nil || services["5000"][0] != "OrderSync" {
		t.Fatalf("%v %v", programs, services)
	}
}

func TestLinuxUnitOrigins(t *testing.T) {
	for _, c := range []struct {
		unit string
		f    unitFacts
		want string
		why  string
	}{
		{"cron.service", unitFacts{"/usr/lib/systemd/system/cron.service", "/usr/lib/systemd/system/cron.service", "cron", "important"}, "system", "base package cron"},
		{"ssh.service", unitFacts{"/usr/lib/systemd/system/ssh.service", "/usr/lib/systemd/system/ssh.service", "openssh-server", "optional"}, "software", "Unit shipped by package openssh-server"},
		{"NetworkManager.service", unitFacts{"/usr/lib/systemd/system/NetworkManager.service", "/usr/lib/systemd/system/NetworkManager.service", "network-manager", "auto"}, "system", "base package"},
		{"docker.service", unitFacts{"/usr/lib/systemd/system/docker.service", "/usr/lib/systemd/system/docker.service", "docker-ce", "optional"}, "software", "package docker-ce"},
		{"old.service", unitFacts{"/lib/systemd/system/old.service", "/lib/systemd/system/old.service", "", ""}, "system", "distribution's folder"},
		{"sshd.service", unitFacts{"/etc/systemd/system/sshd.service", "/usr/lib/systemd/system/ssh.service", "openssh-server", "optional"}, "software", "ssh.service"},
		{"getty@tty1.service", unitFacts{"/etc/systemd/system/getty.target.wants/x", "/usr/lib/systemd/system/getty@.service", "util-linux", "required"}, "system", "base package util-linux"},
		{"vendor.service", unitFacts{"/etc/systemd/system/vendor.service", "/etc/systemd/system/vendor.service", "vendor-agent", "optional"}, "software", "package vendor-agent"},
		{"orders.service", unitFacts{"/etc/systemd/system/orders.service", "/etc/systemd/system/orders.service", "", ""}, "yours", "Unit added in /etc/systemd/system"},
		{"tool.service", unitFacts{"/etc/systemd/system/tool.service", "/opt/tool/tool.service", "", ""}, "yours", "Unit added in /opt/tool"},
		{"mine.service", unitFacts{"/usr/local/lib/systemd/system/mine.service", "/usr/local/lib/systemd/system/mine.service", "", ""}, "yours", "/usr/local/lib/systemd/system"},
		{"home.service", unitFacts{"/home/sam/.config/home.service", "/home/sam/.config/home.service", "", ""}, "yours", "/home/sam/.config"},
		{"var-lib.mount", unitFacts{"/run/systemd/generator/var-lib.mount", "/run/systemd/generator/var-lib.mount", "", ""}, "system", "Generated by systemd"},
		{"dokkit.service", unitFacts{"/etc/systemd/system/dokkit.service", "/etc/systemd/system/dokkit.service", "", ""}, "dokkit", "Dokkit itself"},
		{"dokkit-updater.timer", unitFacts{}, "dokkit", "Dokkit itself"},
		{"dokkit-updater.service", unitFacts{}, "dokkit", "Dokkit itself"},
		{"dokkit-lookalike.service", unitFacts{"/etc/systemd/system/dokkit-lookalike.service", "/etc/systemd/system/dokkit-lookalike.service", "", ""}, "yours", "Unit added in /etc/systemd/system"},
		{"gone.service", unitFacts{}, "yours", "not known"},
	} {
		o, w := unitOrigin(c.unit, c.f)
		if o != c.want || !strings.Contains(w, c.why) {
			t.Errorf("%s: %s, %q", c.unit, o, w)
		}
	}
}

func TestPackageFactsFromDpkg(t *testing.T) {
	owners := parseDpkgOwners([]string{
		"openssh-server: /usr/lib/systemd/system/ssh.service",
		"dpkg-query: no path found matching pattern /lib/systemd/system/ssh.service",
		"cron, anacron: /etc/cron.d/anacron",
		"diversion by dash from: /bin/sh",
		"",
	})
	if len(owners) != 2 || owners["/usr/lib/systemd/system/ssh.service"] != "openssh-server" || owners["/etc/cron.d/anacron"] != "cron" {
		t.Fatalf("%v", owners)
	}
	p := parseDpkgPriorities([]string{"openssh-server\toptional", "systemd\timportant", ""})
	if p["systemd"] != "important" || p["openssh-server"] != "optional" || len(p) != 2 {
		t.Fatalf("%v", p)
	}
	if altUsrPath("/usr/lib/systemd/system/a.service") != "/lib/systemd/system/a.service" || altUsrPath("/etc/x") != "/etc/x" {
		t.Fatal("alt path")
	}
}

func TestAPortFollowsItsProcessToAUnit(t *testing.T) {
	for in, want := range map[string]string{
		"0::/system.slice/ssh.service\n":                                             "ssh.service",
		"0::/system.slice/docker.service\n":                                          "docker.service",
		"0::/user.slice/user-1000.slice/user@1000.service/app.slice/tool.service\n":  "tool.service",
		"1:name=systemd:/system.slice/cron.service\n0::/system.slice/cron.service\n": "cron.service",
		"0::/system.slice/docker-abc.scope\n":                                        "",
		"":                                                                           "",
	} {
		if unit, _ := cgroupUnit(in); unit != want {
			t.Errorf("%q: %q", in, unit)
		}
	}
	if unit, session := cgroupUnit("0::/user.slice/user-1000.slice/session-3.scope\n"); unit != "" || !session {
		t.Fatalf("a login session: %q %v", unit, session)
	}
	if o, w := portUnitOrigin("ssh.service", false, "software", "Unit shipped by package openssh-server"); o != "software" || !strings.Contains(w, "ssh.service") {
		t.Fatalf("%s %s", o, w)
	}
	if o, _ := portUnitOrigin("", true, "", ""); o != "yours" {
		t.Fatal("session")
	}
	if o, w := portUnitOrigin("", false, "", ""); o != "yours" || w != "owner not known" {
		t.Fatalf("%s %s", o, w)
	}
}

func TestCronOrigins(t *testing.T) {
	for _, c := range []struct {
		name, where, command, pkg, priority string
		qnap                                bool
		want                                string
	}{
		{"user crontab", "this account's crontab", "/home/sam/bin/backup.sh", "", "", false, "yours"},
		{"root crontab", "/var/spool/cron/crontabs/root", "/usr/local/bin/clean", "", "", false, "yours"},
		{"run-parts", "/etc/crontab", "root cd / && run-parts --report /etc/cron.hourly", "", "", false, "system"},
		{"line added to crontab", "/etc/crontab", "root /opt/app/job.sh", "", "", false, "yours"},
		{"base package file", "/etc/cron.d/e2scrub_all", "root /usr/lib/e2fsprogs/e2scrub_all_cron", "e2fsprogs", "required", false, "system"},
		{"add-on package file", "/etc/cron.d/sysstat", "root /usr/lib/sysstat/debian-sa1", "sysstat", "optional", false, "software"},
		{"auto package file", "/etc/cron.d/anacron", "root test -x /usr/sbin/anacron", "anacron", "auto", false, "system"},
		{"own cron.d file", "/etc/cron.d/nightly-restart", "root systemctl restart app", "", "", false, "yours"},
		{"dokkit", "this account's crontab", "/opt/dokkit/dokkit updater run # dokkit-updater", "", "", false, "dokkit"},
		{"qnap firmware", "this account's crontab", "/sbin/hwclock -s", "", "", true, "system"},
		{"qnap init script", "this account's crontab", "/bin/sh /etc/init.d/flush_memory.sh >/dev/null 2>&1", "", "", true, "system"},
		{"qnap sourced script", "this account's crontab", "(source /etc/init.d/qulog.sh dummy; check_db) >/dev/null", "", "", true, "system"},
		{"qnap local sbin", "this account's crontab", "/usr/local/sbin/qulog-archive local retention 0", "", "", true, "system"},
		{"qnap add-on", "this account's crontab", "/share/CACHEDEV1_DATA/.qpkg/Tool/run.sh -all", "", "", true, "software"},
		{"qnap ext opt", "this account's crontab", "/mnt/ext/opt/License/bin/check local", "", "", true, "software"},
		{"qnap tagged line", "this account's crontab", "bash /usr/local/sbin/sa_checker.sh;#_SA_Counselor_task", "", "", true, "software"},
		{"qnap person's script", "this account's crontab", "/share/CACHEDEV1_DATA/scripts/copy.sh", "", "", true, "yours"},
		{"qnap cd then script", "this account's crontab", `cd "/share/CACHEDEV1_DATA/Web/tool"; ./run.sh`, "", "", true, "yours"},
		{"qnap home", "this account's crontab", "/home/admin/job.sh", "", "", true, "yours"},
		{"qnap dokkit", "this account's crontab", "/bin/sh /share/CACHEDEV1_DATA/dokkit/start-watch.sh", "", "", true, "yours"},
	} {
		if o, w := cronOrigin(c.where, c.command, c.pkg, c.priority, c.qnap); o != c.want || w == "" {
			t.Errorf("%s: %s, %q", c.name, o, w)
		}
	}
}

func TestFirstPathOfACommand(t *testing.T) {
	look := func(n string) (string, error) {
		if n == "qsh" {
			return "/sbin/qsh", nil
		}
		return "", errors.New("no")
	}
	for in, want := range map[string]string{
		"/sbin/hwclock -s":                          "/sbin/hwclock",
		"/bin/sh /etc/init.d/a.sh":                  "/etc/init.d/a.sh",
		"(source /etc/init.d/a.sh x; f) >/dev/null": "/etc/init.d/a.sh",
		`cd "/share/x"; ./run.sh`:                   "/share/x",
		"qsh qvpn.Refresh":                          "/sbin/qsh",
		"unknown-tool run":                          "",
		"":                                          "",
	} {
		if got := firstCommandPath(in, look); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestMacOrigins(t *testing.T) {
	home := "/Users/sam"
	for _, c := range []struct{ label, file, program, want string }{
		{"com.apple.metadata", "/System/Library/LaunchDaemons/com.apple.metadata.plist", "/usr/libexec/mds", "system"},
		{"com.example.helper", "/Library/LaunchDaemons/com.example.helper.plist", "/System/Library/CoreServices/helper", "system"},
		{"com.vendor.sync", "/Library/LaunchDaemons/com.vendor.sync.plist", "/Library/PrivilegedHelperTools/com.vendor.sync", "software"},
		{"com.vendor.agent", "/Library/LaunchAgents/com.vendor.agent.plist", "/Applications/Vendor.app/Contents/MacOS/agent", "software"},
		{"com.vendor.login", "/Users/sam/Library/LaunchAgents/com.vendor.login.plist", "/Applications/Vendor.app/Contents/MacOS/login", "software"},
		{"local.backup", "/Users/sam/Library/LaunchAgents/local.backup.plist", "/Users/sam/bin/backup.sh", "yours"},
		{"org.site.report", "/Library/LaunchDaemons/org.site.report.plist", "/usr/local/sbin/report.sh", "yours"},
		{"com.dokkit.updater", "/Library/LaunchDaemons/com.dokkit.updater.plist", "/Library/Application Support/DokkitUpdater/dokkit", "dokkit"},
		{"dev.dokkit.service", "/Library/LaunchDaemons/dev.dokkit.service.plist", "/usr/local/bin/dokkit", "dokkit"},
		{"org.site.plain", "/etc/odd.plist", "/opt/x", "yours"},
	} {
		if o, w := macOrigin(c.label, c.file, c.program, home); o != c.want || w == "" {
			t.Errorf("%s: %s, %q", c.label, o, w)
		}
	}
}

func TestEveryJobTheScanReadsCarriesAnOrigin(t *testing.T) {
	for _, j := range parseSchtasks(lines(t, "testdata/schtasks.csv"), 0) {
		if j["origin"] == "" || j["why"] == "" {
			t.Errorf("no origin: %v", j)
		}
	}
	for _, j := range parseSchtasks(lines(t, "testdata/schtasks.csv"), 0) {
		if strings.HasPrefix(j["name"], "Brave") && j["origin"] != "software" {
			t.Errorf("%v", j)
		}
	}
	j, _ := parseLaunchd(map[string]any{"Label": "local.backup", "Program": "/usr/local/bin/backup", "StartInterval": 3600.0}, "/Library/LaunchDaemons/local.backup.plist", 0)
	if j["origin"] != "yours" || j["why"] == "" {
		t.Fatalf("%v", j)
	}
}

func TestOwnContainers(t *testing.T) {
	for _, c := range []struct {
		image, project string
		want           bool
	}{
		{"ghcr.io/example/dokkit:latest", "", true},
		{"dokkit", "", true},
		{"postgres:17", "dokkit", true},
		{"postgres:17", "shop", false},
		{"ghcr.io/example/dokkit-tools:1", "", false},
	} {
		if got := ownContainer(c.image, c.project); got != c.want {
			t.Errorf("%s %s: %v", c.image, c.project, got)
		}
	}
}

func TestOwnPiecesAreNotSent(t *testing.T) {
	list := []found{
		mark(found{"name": "dokkit01dd59e0d4f44eb0"}, originDokkit, dokkitWhy),
		mark(found{"name": "Spooler"}, originSystem, "Windows component"),
		{"name": "no origin"},
	}
	if got := withoutOwn(list); len(got) != 2 || got[0]["name"] != "Spooler" {
		t.Errorf("%v", got)
	}
}
