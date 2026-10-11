package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/BurntSushi/toml"
)

func integers(v any) any {
	switch x := v.(type) {
	case json.Number:
		if n, err := x.Int64(); err == nil {
			return n
		}
		f, _ := x.Float64()
		return f
	case map[string]any:
		for k, e := range x {
			x[k] = integers(e)
		}
	case []any:
		for i, e := range x {
			x[i] = integers(e)
		}
	}
	return v
}

func TestTheSameBadFilesAreRefusedHereAndOnTheServer(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "spec", "declare-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name string
		Ok   bool
		Doc  map[string]any
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		var b bytes.Buffer
		if err := toml.NewEncoder(&b).Encode(integers(c.Doc)); err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, b.Bytes(), 0o600)
		_, err := readDeclaration(file)
		if (err == nil) != c.Ok {
			t.Errorf("%s: ok is %v, got %v\n%s", c.Name, c.Ok, err, b.String())
		}
	}
}

func TestFilesThisProgramReadsItselfAreChecked(t *testing.T) {
	head := "schema = 1\n[service]\nid = \"a\"\n"
	for body, ok := range map[string]bool{
		"[stats]\nurl = \"http://localhost/s\"\nkey_env = \"DOKKIT_STATS_KEY\"\n": true,
		"[stats]\nurl = \"http://localhost/s\"\nkey_env = \"HOME\"\n":             false,
		"[stats]\nurl = \"localhost/s\"\n":                                        false,
		"[stats]\nurl = \"ftp://localhost/s\"\n":                                  false,
		"[logs]\npath = \"logs/*.jsonl\"\n":                                       true,
		"[logs]\npath = \"../other/*.log\"\n":                                     false,
		"[logs]\npath = \"logs/../../x.log\"\n":                                   false,
		"[logs]\npath = \"" + filepath.ToSlash(os.TempDir()) + "/x/*.log\"\n":     false,
		"[logs]\npath = \"logs/../app.log\"\n":                                    true,
	} {
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, []byte(head+body), 0o600)
		d, err := readDeclaration(file)
		if err != nil {
			t.Errorf("%q: the file itself is kept: %v", body, err)
			continue
		}
		if err := d.misplaced(); (err == nil) != ok {
			t.Errorf("%q: ok is %v, got %v", body, ok, err)
		}
	}
}
