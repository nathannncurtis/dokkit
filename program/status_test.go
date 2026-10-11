package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestAnHTTPCheckPassesOnlyTheStatusItExpects(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		code, _ := strconv.Atoi(r.URL.Path[1:])
		if code == 302 {
			w.Header().Set("Location", "/200")
		}
		w.WriteHeader(code)
	}))
	defer srv.Close()
	for _, c := range []struct {
		status string
		path   string
		ok     bool
	}{
		{"", "200", true},
		{"", "204", true},
		{"", "404", false},
		{"status = 200", "200", true},
		{"status = 200", "204", false},
		{"status = 200", "404", false},
		{`status = "200-299"`, "204", true},
		{`status = "200-299"`, "301", false},
		{`status = [200, 404]`, "404", true},
		{`status = [200, "400-403"]`, "402", true},
		{`status = [200, "400-403"]`, "500", false},
		{"status = 404", "404", true},
		{"status = 302", "302", true},
		{"status = 200", "302", true},
		{"status = 503", "503", true},
	} {
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"a\"\n[[check]]\ntype = \"http\"\nurl = \""+srv.URL+"/"+c.path+"\"\n"+c.status+"\n"), 0o600)
		d, err := readDeclaration(file)
		if err != nil {
			t.Fatal(c.status, err)
		}
		if r := d.Check[0].run(); r.ok != c.ok {
			t.Errorf("%q on %s: %+v", c.status, c.path, r)
		}
	}
}

func TestABadExpectedStatusIsRefused(t *testing.T) {
	for _, body := range []string{"status = 99", "status = 600", `status = "abc"`, `status = "300-200"`, "status = []", "status = 200.5", "status = true"} {
		file := filepath.Join(t.TempDir(), "dokkit.toml")
		os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"a\"\n[[check]]\ntype = \"http\"\nurl = \"http://x\"\n"+body+"\n"), 0o600)
		if _, err := readDeclaration(file); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
	file := filepath.Join(t.TempDir(), "dokkit.toml")
	os.WriteFile(file, []byte("schema = 1\n[service]\nid = \"a\"\n[[check]]\ntype = \"tcp\"\nport = 80\nstatus = 200\n"), 0o600)
	if _, err := readDeclaration(file); err == nil {
		t.Error("status on a tcp check was accepted")
	}
}
