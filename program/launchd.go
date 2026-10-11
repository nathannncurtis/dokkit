package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const (
	macLabel      = "dev.dokkit.service"
	macPlist      = "/Library/LaunchDaemons/" + macLabel + ".plist"
	macUser       = "_dokkit"
	macConfigDir  = "/Library/Application Support/Dokkit"
	macConfigFile = macConfigDir + "/config.json"
	macStateDir   = "/var/db/dokkit"
	macLog        = macStateDir + "/service.log"
)

var agentLabel = regexp.MustCompile(`<key>Label</key>\s*<string>([^<]+)</string>`)

// daemonPlistFor is the LaunchDaemon that runs watch from the installed copy at exe as the
// dokkit account, with the service's configuration and spool.
func daemonPlistFor(exe string) string {
	esc := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>` + macLabel + `</string>
  <key>ProgramArguments</key>
  <array><string>` + esc(exe) + `</string><string>watch</string></array>
  <key>UserName</key><string>` + macUser + `</string>
  <key>GroupName</key><string>` + macUser + `</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DOKKIT_CONFIG</key><string>` + esc(macConfigFile) + `</string>
    <key>DOKKIT_SPOOL</key><string>` + macStateDir + `</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>` + macLog + `</string>
  <key>StandardErrorPath</key><string>` + macLog + `</string>
</dict>
</plist>
`
}

// nextFreeID is the first number from 301 up that no user and no group has, from the output of
// dscl . -list /Users UniqueID and dscl . -list /Groups PrimaryGroupID.
func nextFreeID(lists ...string) int {
	taken := map[int]bool{}
	for _, l := range lists {
		for _, line := range strings.Split(l, "\n") {
			if f := strings.Fields(line); len(f) >= 2 {
				if n, err := strconv.Atoi(f[len(f)-1]); err == nil {
					taken[n] = true
				}
			}
		}
	}
	id := 301
	for taken[id] {
		id++
	}
	return id
}

// accountSteps are the dscl calls that make the group and the user nobody can sign in as.
func accountSteps(name string, id int) (steps [][]string) {
	n := strconv.Itoa(id)
	for _, kv := range [][2]string{{"", ""}, {"PrimaryGroupID", n}, {"RealName", "Dokkit"}, {"Password", "*"}} {
		steps = append(steps, append([]string{".", "-create", "/Groups/" + name}, nonEmpty(kv[:])...))
	}
	for _, kv := range [][2]string{{"", ""}, {"UserShell", "/usr/bin/false"}, {"RealName", "Dokkit"}, {"UniqueID", n}, {"PrimaryGroupID", n}, {"NFSHomeDirectory", "/var/empty"}, {"Password", "*"}, {"IsHidden", "1"}} {
		steps = append(steps, append([]string{".", "-create", "/Users/" + name}, nonEmpty(kv[:])...))
	}
	return
}

func nonEmpty(s []string) []string {
	if s[0] == "" {
		return nil
	}
	return s
}

// isWatchAgent is true for a LaunchAgent file that runs dokkit watch, and gives its label.
func isWatchAgent(plist string) (string, bool) {
	m := agentLabel.FindStringSubmatch(plist)
	if m == nil || !strings.Contains(plist, "<string>watch</string>") || !strings.Contains(plist, "dokkit") {
		return "", false
	}
	return m[1], true
}

// macEnrolments are the files that may hold the enrolment to move to the service: the account
// that ran sudo first, then the account running this.
func macEnrolments(own, sudoHome string) (paths []string) {
	if sudoHome != "" {
		paths = append(paths, filepath.Join(sudoHome, "Library", "Application Support", "dokkit", "config.json"))
	}
	return append(paths, own)
}

// firstEnrolment is the first file that holds an address and a key, or "".
func firstEnrolment(paths []string) string {
	for _, p := range paths {
		var s saved
		if b, err := os.ReadFile(p); err == nil && json.Unmarshal(b, &s) == nil && s.URL != "" && s.Key != "" {
			return p
		}
	}
	return ""
}

// spoolFiles are the names in a spool folder that carry on in the service's: reports waiting
// and where each log was read to.
var spoolFiles = []string{"*.ndjson", "*.rejected", "logs.json", "failures.json"}
