package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
)

// Tests replace these.
var (
	serviceConfig = installedServiceConfig
	ownService    = ownedByService
)

// folderConfig is the configuration file the watching program reads its folder list from: the
// installed service's when there is one, otherwise the signed-in person's own.
func folderConfig() (path string, service bool) {
	if p := os.Getenv("DOKKIT_CONFIG"); p != "" {
		return p, false
	}
	if p := serviceConfig(); p != "" {
		return p, true
	}
	p, _ := configPath()
	return p, false
}

// quoteArg quotes a word for the command line of this system when it needs it.
func quoteArg(s string) string {
	if !strings.ContainsAny(s, " \t'\"") {
		return s
	}
	if runtime.GOOS == "windows" {
		return `"` + s + `"`
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// elevated is the command line that runs this program with args as an administrator or root.
func elevated(args ...string) string {
	exe, err := os.Executable()
	if err != nil {
		exe = "dokkit"
	}
	words := []string{quoteArg(exe)}
	for _, a := range args {
		words = append(words, quoteArg(a))
	}
	if runtime.GOOS == "windows" {
		return "from an administrator prompt: " + strings.Join(words, " ")
	}
	return "sudo " + strings.Join(words, " ")
}

// folderAddLine is the line that adds dir to the folders the watching program reads.
func folderAddLine(dir string) string {
	if _, service := folderConfig(); service {
		return elevated("folder", "add", dir)
	}
	return "dokkit folder add " + quoteArg(dir)
}

func sameFolder(a, b string) bool {
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// readFolders reads a configuration file whole, so what else it holds is written back unchanged.
func readFolders(path string) (map[string]json.RawMessage, []string, error) {
	raw := map[string]json.RawMessage{}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return raw, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, nil, fmt.Errorf("%s is not a configuration file: %v", path, err)
	}
	var list []string
	if f, ok := raw["folders"]; ok {
		if err := json.Unmarshal(f, &list); err != nil {
			return nil, nil, fmt.Errorf("the folders in %s are not a list of paths", path)
		}
	}
	return raw, list, nil
}

func saveFolders(path string, raw map[string]json.RawMessage, list []string, service bool) error {
	if len(list) == 0 {
		delete(raw, "folders")
	} else {
		raw["folders"], _ = json.Marshal(list)
	}
	b, _ := json.Marshal(raw)
	if !service {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	if service {
		if err := ownService(tmp); err != nil {
			os.Remove(tmp)
			return err
		}
	}
	return os.Rename(tmp, path)
}

// folderCommand adds a folder to, removes one from, or lists the folders dokkit watch reads.
func folderCommand(args []string) int {
	ok := len(args) == 1 && args[0] == "list" || len(args) == 2 && (args[0] == "add" || args[0] == "remove")
	if !ok {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	path, service := folderConfig()
	whose := "dokkit watch run by you"
	if service {
		whose = "the installed service"
	}
	fail := func(err error) int {
		if errors.Is(err, fs.ErrPermission) && service {
			fmt.Fprintln(os.Stderr, "dokkit: only an administrator can change or read the installed service's folders. Run it "+elevated(append([]string{"folder"}, args...)...))
		} else {
			fmt.Fprintln(os.Stderr, "dokkit:", err)
		}
		return 1
	}
	raw, list, err := readFolders(path)
	if err != nil {
		return fail(err)
	}
	if args[0] == "list" {
		fmt.Printf("Folders read by %s (%s):\n", whose, path)
		for _, f := range list {
			why := unreadable(f)
			if service && runtime.GOOS == "linux" {
				why = othersCannotRead(f)
			}
			if why != "" {
				why = "   cannot be read: " + why
			}
			fmt.Println(" ", f+why)
		}
		if len(list) == 0 {
			fmt.Println("  none. Add one with: " + folderAddLine("<path>"))
		}
		if os.Getenv("DOKKIT_FOLDERS") != "" {
			fmt.Println("DOKKIT_FOLDERS is set in this window, and a watch started here reads that instead.")
		}
		return 0
	}
	abs, err := filepath.Abs(args[1])
	if err != nil {
		return fail(err)
	}
	here := func(f string) bool {
		a, err := filepath.Abs(f)
		return sameFolder(a, abs) || err != nil && sameFolder(f, abs)
	}
	if args[0] == "remove" {
		if !slices.ContainsFunc(list, here) {
			fmt.Printf("%s is not in the folders read by %s. Nothing changed.\n", abs, whose)
			return 0
		}
		list = slices.DeleteFunc(list, here)
		if err := saveFolders(path, raw, list, service); err != nil {
			return fail(err)
		}
		fmt.Printf("Removed %s. %s reads %d folder(s) now.\n", abs, strings.ToUpper(whose[:1])+whose[1:], len(list))
		return 0
	}
	if fi, err := os.Stat(abs); err != nil || !fi.IsDir() {
		fmt.Fprintf(os.Stderr, "dokkit: %s is not a folder that exists.\n", abs)
		return 1
	}
	if slices.ContainsFunc(list, here) {
		fmt.Printf("%s is already in the folders read by %s. Nothing changed.\n", abs, whose)
		return 0
	}
	if err := saveFolders(path, raw, append(list, abs), service); err != nil {
		return fail(err)
	}
	fmt.Printf("Added %s. %s reads it within a minute, with no restart.\n", abs, strings.ToUpper(whose[:1])+whose[1:])
	if service && runtime.GOOS == "linux" {
		if why := othersCannotRead(abs); why != "" {
			fmt.Fprintf(os.Stderr, "dokkit: the %s user may not be able to read that folder (%s). Open it to that user, or the service will find nothing there.\n", unitUser, why)
		}
	}
	return 0
}
