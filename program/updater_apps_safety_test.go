package main

import (
	"archive/tar"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func linkOrSkip(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("this system will not make links: %v", err)
	}
}

func readFile(p string) string { b, _ := os.ReadFile(p); return string(b) }

func TestATarWithDotEntriesIsUnpackedAndOneThatEscapesIsNot(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.tgz")
	os.WriteFile(good, tgzOf(t, tarEntry{name: "./", typ: tar.TypeDir}, tarEntry{name: "./bin/x", body: "x"}), 0o600)
	if err := untar(good, filepath.Join(dir, "out")); err != nil || readFile(filepath.Join(dir, "out", "bin", "x")) != "x" {
		t.Fatal(err)
	}
	bad := filepath.Join(dir, "bad.tgz")
	os.WriteFile(bad, tgzOf(t, tarEntry{name: "a/../../evil", body: "x"}), 0o600)
	if err := untar(bad, filepath.Join(dir, "out2")); err == nil || exists(filepath.Join(dir, "evil")) || exists(filepath.Join(dir, "out2")) {
		t.Fatalf("%v", err)
	}
}

func TestNothingIsWrittenThroughALink(t *testing.T) {
	r := newAppRig(t)
	appOS = "linux"
	folder := filepath.Join(r.dir, "opt", "acme")
	outside := filepath.Join(r.dir, "outside")
	os.MkdirAll(outside, 0o755)
	r.write("opt/acme/keep", "old")
	linkOrSkip(t, outside, filepath.Join(folder, "sub"))
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"x\"\nfolder = "+lit(folder)+"\n", false)
	r.offer("acme-intake", "v1.4.0", "x.tar.gz", tgzOf(t, tarEntry{name: "sub/", typ: tar.TypeDir}, tarEntry{name: "sub/x", body: "new"}))
	res := r.one()
	if res.OK || !strings.Contains(res.Note, "link or not a folder") || r.has("outside/x") || r.read("opt/acme/keep") != "old" {
		t.Fatalf("%+v", res)
	}
}

func TestAFolderOrFileThatIsALinkIsRefusedBeforeAnythingStops(t *testing.T) {
	r := newAppRig(t)
	appOS = "linux"
	real := filepath.Join(r.dir, "real")
	os.MkdirAll(real, 0o755)
	r.write("realfile", "old")
	linkOrSkip(t, real, filepath.Join(r.dir, "folderlink"))
	linkOrSkip(t, filepath.Join(r.dir, "realfile"), filepath.Join(r.dir, "filelink"))
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"x\"\nfolder = "+lit(filepath.Join(r.dir, "folderlink"))+"\n", false)
	r.offer("acme-intake", "v1.4.0", "x.tar.gz", tgzOf(t, tarEntry{name: "a", body: "new"}))
	if res := r.one(); res.OK || !strings.Contains(res.Note, "Nothing was changed") || len(r.calls) != 0 || r.has("real/a") {
		t.Fatalf("%+v %v", res, r.calls)
	}
	r.results = nil
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"x\"\nfile = "+lit(filepath.Join(r.dir, "filelink"))+"\n", false)
	body := tgzOf(t, tarEntry{name: "filelink", body: "new"})
	r.edit(func() { r.files["x.tar.gz"] = body; r.items[0].SHA256 = sha(body) })
	if res := r.one(); res.OK || !strings.Contains(res.Note, "Nothing was changed") || len(r.calls) != 0 || r.read("realfile") != "old" {
		t.Fatalf("%+v %v", res, r.calls)
	}
}

func TestComposeFileAndItsFolderMustBeTrusted(t *testing.T) {
	for _, bad := range []string{"compose.yml", "srv"} {
		r := newAppRig(t)
		file := r.write("srv/compose.yml", composeText)
		r.recipe("acme-intake", "kind = \"compose\"\ncompose_file = "+lit(file)+"\ncompose_service = \"intake\"\n", false)
		r.edit(func() { r.items = []appItem{{Service: "acme-intake", Version: "v1.4.0"}} })
		r.trustBad = bad
		res := r.one()
		if res.OK || !strings.HasSuffix(res.Note, "can be changed by accounts other than administrators, so it is not run") || len(r.calls) != 0 || r.read("srv/compose.yml") != composeText {
			t.Errorf("%s: %+v %v", bad, res, r.calls)
		}
	}
}

func TestOnlyTheFileThatWasReadIsTrusted(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	os.WriteFile(a, []byte("a"), 0o600)
	os.WriteFile(b, []byte("b"), 0o600)
	f, _ := os.Open(a)
	defer f.Close()
	if err := stillTheFile(f, a); err != nil {
		t.Fatal(err)
	}
	if err := stillTheFile(f, b); err == nil {
		t.Fatal("another file at the path was accepted")
	}
	if err := stillTheFile(f, filepath.Join(dir, "gone")); err == nil {
		t.Fatal("a missing path was accepted")
	}
}

func TestAReleaseWhoseResultIsUnsentIsNotInstalledAgain(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	r.edit(func() { r.failPost = 100 })
	r.run()
	r.run()
	installs := 0
	for _, c := range r.calls {
		if strings.HasPrefix(c, "setup.exe") {
			installs++
		}
	}
	st, _ := readState()
	if installs != 1 || len(st.UnsentApps) != 1 {
		t.Fatalf("%d installs, %+v", installs, st.UnsentApps)
	}
	r.edit(func() { r.failPost, r.items = 0, nil })
	got, _ := r.run()
	st, _ = readState()
	if len(got) != 1 || len(st.UnsentApps) != 0 || len(r.calls) != 1 {
		t.Fatalf("%v %+v %v", got, st.UnsentApps, r.calls)
	}
}

func TestAMissingVersionFileIsUnhealthyButACommandIsNotAFile(t *testing.T) {
	r := newAppRig(t)
	dir := r.recipe("acme-intake", "kind = \"installer\"\n", false)
	load := func(from string) *declaration {
		d, err := parseDeclaration(filepath.Join(dir, "dokkit.toml"), "schema = 1\n[service]\nid = \"acme-intake\"\nversion_from = \""+from+"\"\n")
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	_, err := waitHealthy(context.Background(), load("VERSION"), "v1.4.0", 10*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "the version file says") {
		t.Fatalf("a missing file is unhealthy: %v", err)
	}
	if note, err := waitHealthy(context.Background(), load("git describe --tags"), "v1.4.0", 10*time.Millisecond); err != nil || note != "no checks to wait on" {
		t.Fatalf("%q %v", note, err)
	}
}

func TestRollbackRunsAfterTheRunHasBeenCancelled(t *testing.T) {
	r := newAppRig(t)
	appOS = "linux"
	bin := r.write("usr/acme-intake", "old")
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"acme-intake\"\nfile = "+lit(bin)+"\n", true)
	it := r.offer("acme-intake", "v1.4.0", "acme-intake", []byte("new"))
	r.healthy.Store(false)
	ctx, cancel := context.WithCancel(context.Background())
	r.runFn = func(string, []string) (string, error) { cancel(); return "", nil }
	res := installApp(ctx, &client{url: r.srv.URL, key: "k", folders: []string{r.apps}}, it)
	if res.OK || r.read("usr/acme-intake") != "old" || len(r.calls) != 2 {
		t.Fatalf("%+v %v", res, r.calls)
	}
	if len(r.ctxErrs) != 2 || r.ctxErrs[1] != nil {
		t.Fatalf("the restart that puts the old version back saw %v", r.ctxErrs)
	}
}

func TestAnArchiveOverTheLimitIsRefusedAndNothingIsLeft(t *testing.T) {
	r := newAppRig(t)
	extractLimit = 10
	dir := t.TempDir()
	z, g := filepath.Join(dir, "a.zip"), filepath.Join(dir, "a.tgz")
	os.WriteFile(z, zipOf(t, map[string]string{"a": "123456", "b": "123456"}), 0o600)
	os.WriteFile(g, tgzOf(t, tarEntry{name: "a", body: "123456"}, tarEntry{name: "b", body: "123456"}), 0o600)
	for _, c := range []struct {
		name string
		f    func(string, string) error
		file string
	}{{"zip", unzip, z}, {"tar", untar, g}} {
		out := filepath.Join(dir, "out-"+c.name)
		if err := c.f(c.file, out); !errors.Is(err, errTooBig) || exists(out) {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	os.WriteFile(z, zipOf(t, map[string]string{"a": "123456"}), 0o600)
	if err := unzip(z, filepath.Join(dir, "fits")); err != nil {
		t.Fatal(err)
	}
	r.write("opt/acme/keep", "old")
	appOS = "linux"
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"x\"\nfolder = "+lit(filepath.Join(r.dir, "opt", "acme"))+"\n", false)
	r.offer("acme-intake", "v1.4.0", "x.tar.gz", tgzOf(t, tarEntry{name: "a", body: "123456789012"}))
	if res := r.one(); res.OK || !strings.Contains(res.Note, "unpacks to more than the limit") || len(r.calls) != 0 || r.has("data/work/app-acme-intake") {
		t.Fatalf("%+v %v", res, r.calls)
	}
}
