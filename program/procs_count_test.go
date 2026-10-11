package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProcessesAreCountedAndFewerThanWantedIsDegraded(t *testing.T) {
	ps := []proc{{"app", "app --worker 1"}, {"app", "app --worker 2"}, {"app", "app --main"}, {"other", "app"}}
	if n := countProcesses(ps, "app", "--worker"); n != 2 {
		t.Fatalf("counted %d", n)
	}
	if n := countProcesses(ps, "app", ""); n != 3 {
		t.Fatalf("counted %d", n)
	}
	if r := processResult(41, 30); !r.ok || r.value != 41 {
		t.Fatalf("%+v", r)
	}
	if r := processResult(12, 30); r.ok || r.state != "degraded" || r.value != 12 {
		t.Fatalf("%+v", r)
	}
	if r := processResult(3, 0); !r.ok || r.value != 3 {
		t.Fatalf("without at_least any count is fine: %+v", r)
	}
}

func TestAtLeastIsOnlyForAProcessCheck(t *testing.T) {
	read := func(body string) error {
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"app\"\n[[check]]\n"+body), 0o600)
		_, err := readDeclaration(file)
		return err
	}
	if err := read("type = \"process\"\nname = \"app\"\nat_least = 30\n"); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"type = \"process\"\nname = \"app\"\nat_least = -2\n", "type = \"tcp\"\nport = 80\nat_least = 2\n"} {
		if read(bad) == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}
