package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// The program's Windows folders. The server's installer uses Program Files\Dokkit and
// ProgramData\Dokkit, which are the same folders as the program's old ones.
const programFolder = "DokkitProgram"

// What the program itself keeps in its data folder, and the one folder it makes for an update.
var ownItems = []string{"config.json", "spool", "dokkit.log"}

func newExe(filesRoot string) string { return filepath.Join(filesRoot, programFolder, "dokkit.exe") }
func newData(dataRoot string) string { return filepath.Join(dataRoot, programFolder) }
func oldExe(filesRoot string) string { return filepath.Join(filesRoot, "Dokkit", "dokkit.exe") }
func oldData(dataRoot string) string { return filepath.Join(dataRoot, "dokkit") }

func isOwnItem(name string) bool {
	for _, o := range ownItems {
		if strings.EqualFold(name, o) {
			return true
		}
	}
	return false
}

// strangers are the names in the folder that the program did not put there.
func strangers(names []string) (out []string) {
	for _, n := range names {
		if !isOwnItem(n) && !strings.EqualFold(n, "update") && !strings.EqualFold(n, taskListFile) {
			out = append(out, n)
		}
	}
	return
}

func refusal(dir string, names []string) error {
	s := strangers(names)
	if len(s) == 0 {
		return nil
	}
	return fmt.Errorf("%s holds %s, which dokkit did not put there. It keeps only config.json, spool, dokkit.log, tasks.json and update in that folder. Nothing was changed. Move those out, then install again", dir, strings.Join(s, ", "))
}

// Local Service, the account Windows keeps for services that need no rights of their own.
const localService = "*S-1-5-19"

// permissionSteps is the icacls arguments for secure, with the account that owns everything given.
// The service, as Local Service, may read the folder and write only its spool and its log.
func permissionSteps(dir, admins string) [][]string {
	return [][]string{
		{dir, "/setowner", admins, "/T", "/C"},
		{dir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", admins + ":(OI)(CI)F", localService + ":(OI)(CI)RX"},
		{filepath.Join(dir, "*"), "/reset", "/T", "/C"},
		{filepath.Join(dir, "spool"), "/grant", localService + ":(OI)(CI)M"},
		{filepath.Join(dir, "dokkit.log"), "/grant", localService + ":M"},
	}
}
