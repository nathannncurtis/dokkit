package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDaemonPlistRunsWatchAsTheDokkitUserWithItsOwnFiles(t *testing.T) {
	p := daemonPlistFor("/usr/local/bin/dokkit")
	for _, want := range []string{
		"<key>Label</key><string>dev.dokkit.service</string>",
		"<string>/usr/local/bin/dokkit</string><string>watch</string>",
		"<key>UserName</key><string>_dokkit</string>",
		"<key>DOKKIT_CONFIG</key><string>/Library/Application Support/Dokkit/config.json</string>",
		"<key>DOKKIT_SPOOL</key><string>/var/db/dokkit</string>",
		"<key>KeepAlive</key><true/>",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("the plist lacks %s", want)
		}
	}
}

func TestNextFreeIDSkipsUsersAndGroups(t *testing.T) {
	users := "root 0\n_www 70\n_a 301\n_b 302\n"
	groups := "wheel 0\n_c 303\n"
	if id := nextFreeID(users, groups); id != 304 {
		t.Fatalf("want 304, got %d", id)
	}
	if id := nextFreeID("", ""); id != 301 {
		t.Fatalf("want 301, got %d", id)
	}
}

func TestAccountSteps(t *testing.T) {
	steps := accountSteps("_dokkit", 304)
	var flat []string
	for _, s := range steps {
		flat = append(flat, strings.Join(s, " "))
	}
	all := strings.Join(flat, "\n")
	for _, want := range []string{
		". -create /Groups/_dokkit PrimaryGroupID 304",
		". -create /Users/_dokkit UniqueID 304",
		". -create /Users/_dokkit UserShell /usr/bin/false",
		". -create /Users/_dokkit Password *",
		". -create /Users/_dokkit NFSHomeDirectory /var/empty",
	} {
		if !strings.Contains(all, want+"\n") && !strings.HasSuffix(all, want) {
			t.Errorf("missing step %q in\n%s", want, all)
		}
	}
	if flat[0] != ". -create /Groups/_dokkit" {
		t.Errorf("the group is made first, got %q", flat[0])
	}
}

func TestWatchAgentIsRecognisedByItsArguments(t *testing.T) {
	agent := `<dict><key>Label</key><string>dev.dokkit.watch</string><key>ProgramArguments</key><array><string>/usr/local/bin/dokkit</string><string>watch</string></array></dict>`
	if label, ok := isWatchAgent(agent); !ok || label != "dev.dokkit.watch" {
		t.Fatalf("got %q %v", label, ok)
	}
	other := `<dict><key>Label</key><string>com.x.backup</string><key>ProgramArguments</key><array><string>/bin/backup</string></array></dict>`
	if _, ok := isWatchAgent(other); ok {
		t.Fatal("another job is not a dokkit agent")
	}
	if _, ok := isWatchAgent(strings.Replace(agent, "<string>watch</string>", "<string>version</string>", 1)); ok {
		t.Fatal("dokkit run another way is not the watch")
	}
}

func TestFirstEnrolmentPrefersTheSudoAccount(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "me")
	own := filepath.Join(dir, "root", "config.json")
	paths := macEnrolments(own, home)
	if want := filepath.Join(home, "Library", "Application Support", "dokkit", "config.json"); paths[0] != want || paths[1] != own {
		t.Fatalf("got %v", paths)
	}
	os.MkdirAll(filepath.Dir(own), 0o755)
	os.WriteFile(own, []byte(`{"url":"https://a","key":"k"}`), 0o600)
	if got := firstEnrolment(paths); got != own {
		t.Fatalf("root's is the only one: %q", got)
	}
	os.MkdirAll(filepath.Dir(paths[0]), 0o755)
	os.WriteFile(paths[0], []byte(`{"url":"https://b","key":"k"}`), 0o600)
	if got := firstEnrolment(paths); got != paths[0] {
		t.Fatalf("the sudo account's wins: %q", got)
	}
}
