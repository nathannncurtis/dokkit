package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestAProcessIsMatchedByAPieceOfItsText(t *testing.T) {
	ps := []proc{
		{"python.exe", `C:\envs\imageresizer\python.exe`},
		{"python.exe", `C:\envs\other\python.exe`},
		{"python.exe", ""},
	}
	if runtime.GOOS != "windows" {
		for i := range ps {
			ps[i].name = "python"
		}
	}
	name := ps[0].name
	for _, c := range []struct {
		has  string
		want bool
	}{
		{`\envs\imageresizer\`, true},
		{`/ENVS/ImageResizer/`, true},
		{`\envs\nothing\`, false},
		{"", true},
	} {
		if got := matchProcess(ps, name, c.has); got != c.want {
			t.Errorf("%q: got %v", c.has, got)
		}
	}
	if matchProcess(ps, "ruby", "") {
		t.Error("a different program matched")
	}
	if matchProcess(ps[2:], name, "envs") {
		t.Error("a process that could not be inspected matched")
	}
}

func TestCommandHasIsReadAndOnlyForAProcessCheck(t *testing.T) {
	read := func(check string) (*declaration, error) {
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"app\"\n"+check), 0o600)
		return readDeclaration(file)
	}
	d, err := read("[[check]]\ntype = \"process\"\nname = \"python.exe\"\ncommand_has = '\\envs\\imageresizer\\'\n")
	if err != nil || d.Check[0].CommandHas != `\envs\imageresizer\` {
		t.Fatalf("%v %+v", err, d)
	}
	if _, err := read("[[check]]\ntype = \"systemd\"\nname = \"x\"\ncommand_has = \"y\"\n"); err == nil {
		t.Fatal("command_has on a systemd check was accepted")
	}
}

func TestTheRunningTestProgramIsFoundByAPieceOfItsPath(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	name, piece := filepath.Base(exe), filepath.Base(filepath.Dir(exe))
	if _, err := processWithText(name, piece); err != nil {
		t.Fatalf("%s with %q: %v", name, piece, err)
	}
	if _, err := processWithText(name, strings.Repeat("no-such-piece", 3)); err == nil {
		t.Fatal("a piece that is nowhere in the path matched")
	}
}
