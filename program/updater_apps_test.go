package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type appRig struct {
	t        *testing.T
	dir      string
	apps     string
	srv      *httptest.Server
	health   *httptest.Server
	healthy  atomic.Bool
	mu       sync.Mutex
	items    []appItem
	files    map[string][]byte
	listCode int
	query    string
	hQuery   string
	hAuth    string
	hFetched []string
	postCode int
	auth     string
	fetched  []string
	results  []appResult
	failPost int
	calls    []string
	runFn    func(name string, args []string) (string, error)
	stopFn   func(name string) error
	startFn  func(name string) error
	signer   string
	valid    bool
	trustBad string
	ctxErrs  []error
}

func newAppRig(t *testing.T) *appRig {
	t.Helper()
	r := &appRig{t: t, dir: t.TempDir(), files: map[string][]byte{}, signer: "Example Software Ltd", valid: true}
	r.apps = filepath.Join(r.dir, "apps")
	os.MkdirAll(r.apps, 0o755)
	os.MkdirAll(filepath.Join(r.dir, "data"), 0o700)
	r.healthy.Store(true)
	r.health = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		if !r.healthy.Load() {
			w.WriteHeader(500)
		}
	}))
	r.srv = httptest.NewServer(http.HandlerFunc(r.handle))
	oldWhere, oldOps, oldRetry, oldOS, oldEvery, oldUnit := where, ops, retryFor, appOS, healthEvery, healthUnit
	oldTrusted, oldFile, oldAuth, oldRun, oldLimit := trusted, trustedFile, authenticode, runApp, extractLimit
	t.Cleanup(func() {
		r.srv.Close()
		r.health.Close()
		where, ops, retryFor, appOS, healthEvery, healthUnit = oldWhere, oldOps, oldRetry, oldOS, oldEvery, oldUnit
		trusted, trustedFile, authenticode, runApp, extractLimit = oldTrusted, oldFile, oldAuth, oldRun, oldLimit
	})
	where = layout{data: filepath.Join(r.dir, "data")}
	retryFor, healthEvery, healthUnit = -time.Second, time.Millisecond, 20*time.Millisecond
	ops = hostOps{
		stopService: func(n string) error {
			r.calls = append(r.calls, "stop "+n)
			if r.stopFn != nil {
				return r.stopFn(n)
			}
			return nil
		},
		startService: func(n string) error {
			r.calls = append(r.calls, "start "+n)
			if r.startFn != nil {
				return r.startFn(n)
			}
			return nil
		},
	}
	trustedFile = func(f *os.File, p string) error { return trusted(p) }
	trusted = func(p string) error {
		if r.trustBad != "" && strings.Contains(p, r.trustBad) {
			return errors.New("someone else can write it")
		}
		return nil
	}
	authenticode = func(p string) (string, bool, error) { return r.signer, r.valid, nil }
	runApp = func(ctx context.Context, name string, args ...string) (string, error) {
		r.calls = append(r.calls, strings.TrimSpace(filepath.Base(name)+" "+strings.Join(args, " ")))
		r.ctxErrs = append(r.ctxErrs, ctx.Err())
		if r.runFn != nil {
			return r.runFn(name, args)
		}
		return "", nil
	}
	return r
}

func (r *appRig) handle(w http.ResponseWriter, q *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.hAuth = q.Header.Get("Authorization")
	switch {
	case q.URL.Path == "/api/v1/update/apps" && q.Method == "GET":
		r.hQuery = q.URL.RawQuery
		if r.listCode != 0 {
			w.WriteHeader(r.listCode)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"items": r.items})
	case q.URL.Path == "/api/v1/update/apps/result" && q.Method == "POST":
		if r.postCode != 0 {
			w.WriteHeader(r.postCode)
			return
		}
		if r.failPost > 0 {
			r.failPost--
			w.WriteHeader(503)
			return
		}
		var o appResult
		if json.NewDecoder(q.Body).Decode(&o) != nil {
			w.WriteHeader(400)
			return
		}
		r.results = append(r.results, o)
	case strings.HasPrefix(q.URL.Path, "/api/v1/update/apps/"):
		r.hFetched = append(r.hFetched, strings.TrimPrefix(q.URL.EscapedPath(), "/api/v1/update/apps/"))
		if b, ok := r.files[filepath.Base(q.URL.Path)]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	default:
		w.WriteHeader(404)
	}
}

func sha(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// offer publishes a file and lists it as the release of a service.
func (r *appRig) offer(svc, ver, file string, body []byte) appItem {
	it := appItem{Service: svc, Version: ver, File: file, SHA256: sha(body), Size: int64(len(body)), Signer: "Example Software Ltd", HealthSeconds: 1}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.files[file] = body
	r.items = append(r.items, it)
	return it
}

// recipe writes a dokkit.toml with the [app] body and an http check on the rig's health server.
func (r *appRig) recipe(svc, app string, withCheck bool) string {
	dir := filepath.Join(r.apps, svc)
	os.MkdirAll(dir, 0o755)
	text := "schema = 1\n[service]\nid = \"" + svc + "\"\n[app]\n" + app
	if withCheck {
		text += "[[check]]\ntype = \"http\"\nurl = \"" + r.health.URL + "\"\n"
	}
	os.WriteFile(filepath.Join(dir, "dokkit.toml"), []byte(text), 0o644)
	return dir
}

func (r *appRig) edit(f func()) { r.mu.Lock(); f(); r.mu.Unlock() }

func (r *appRig) run() ([]appResult, int) {
	r.t.Helper()
	code := appsOnce(context.Background(), &client{url: r.srv.URL, key: "dkm_test", folders: []string{r.apps}})
	r.mu.Lock()
	defer r.mu.Unlock()
	r.query, r.auth, r.fetched = r.hQuery, r.hAuth, append([]string(nil), r.hFetched...)
	return append([]appResult(nil), r.results...), code
}

func (r *appRig) one() appResult {
	r.t.Helper()
	got, _ := r.run()
	if len(got) != 1 {
		r.t.Fatalf("want one result, got %v (calls %v)", got, r.calls)
	}
	return got[0]
}

func (r *appRig) write(rel, text string) string {
	p := filepath.Join(r.dir, rel)
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte(text), 0o644)
	return p
}

func (r *appRig) read(rel string) string {
	b, _ := os.ReadFile(filepath.Join(r.dir, rel))
	return string(b)
}

func (r *appRig) has(rel string) bool { return exists(filepath.Join(r.dir, rel)) }

func lit(p string) string { return "'" + p + "'" }

func zipOf(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var b bytes.Buffer
	w := zip.NewWriter(&b)
	for n, c := range files {
		f, _ := w.Create(n)
		f.Write([]byte(c))
	}
	w.Close()
	return b.Bytes()
}

type tarEntry struct {
	name, body, link string
	typ              byte
}

func tgzOf(t *testing.T, es ...tarEntry) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	for _, e := range es {
		if e.typ == 0 {
			e.typ = tar.TypeReg
		}
		if err := tw.WriteHeader(&tar.Header{Name: e.name, Typeflag: e.typ, Linkname: e.link, Mode: 0o644, Size: int64(len(e.body))}); err != nil {
			t.Fatal(err)
		}
		tw.Write([]byte(e.body))
	}
	tw.Close()
	gz.Close()
	return b.Bytes()
}

func has(calls []string, want string) bool {
	for _, c := range calls {
		if strings.Contains(c, want) {
			return true
		}
	}
	return false
}

func TestAppTableIsValidatedWithTheServersWords(t *testing.T) {
	head := "schema = 1\n[service]\nid = \"a\"\n"
	for body, want := range map[string]string{
		"[[app]]\nkind = \"installer\"\n":            "[app] is a table.",
		"[app]\nkind = \"msi\"\n":                    "app.kind is one of windows-service, installer, compose, systemd, launchd.",
		"[app]\nname = \"x\"\n":                      "app.kind is one of windows-service, installer, compose, systemd, launchd.",
		"[app]\nkind = \"systemd\"\nfile = \"/x\"\n": "app.name names the service, unit or label to restart.",
		"[app]\nkind = \"launchd\"\nname = \"x\"\n":  "app names a folder or a file to replace, one of the two.",
		"[app]\nkind = \"windows-service\"\nname = \"x\"\nfolder = \"/x\"\nfile = \"/y\"\n": "app names a folder or a file to replace, one of the two.",
		"[app]\nkind = \"compose\"\ncompose_file = \"/c.yml\"\n":                            "app.compose_file and app.compose_service name the Compose file and its service.",
		"[app]\nkind = \"installer\"\nhealth_wait = \"9s\"\n":                               "app.health_wait is a time such as 5m, from 10s to 1h.",
		"[app]\nkind = \"installer\"\nhealth_wait = \"61m\"\n":                              "app.health_wait is a time such as 5m, from 10s to 1h.",
		"[app]\nkind = \"installer\"\nhealth_wait = 30\n":                                   "app.health_wait is a time such as 5m, from 10s to 1h.",
		"[app]\nkind = \"installer\"\nargs = \"/S\"\n":                                      "app.args is a list of text.",
		"[app]\nkind = \"installer\"\nargs = [\"/S\", 4]\n":                                 "app.args is a list of text.",
	} {
		_, err := parseDeclaration("dokkit.toml", head+body)
		if err == nil || err.Error() != want {
			t.Errorf("%q: got %v, want %q", body, err, want)
		}
	}
	d, err := parseDeclaration("dokkit.toml", head+"[app]\nkind = \"installer\"\nargs = [\"/S\"]\nhealth_wait = \"2m\"\nasset = \"*.exe\"\n")
	if err != nil || d.App.Tag != "{version}" || len(d.App.Args) != 1 || !d.App.HasArgs || d.App.HealthWait != 2*time.Minute || d.App.Asset != "*.exe" {
		t.Fatalf("%+v %v", d.App, err)
	}
	if d, err := parseDeclaration("dokkit.toml", head); err != nil || d.App != nil {
		t.Fatalf("a file without [app] has none: %v %v", d.App, err)
	}
}

func TestWindowsServiceFolderIsReplacedAndStartedAgain(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	folder := filepath.Join(r.dir, "intake")
	r.write("intake/app.dll", "old")
	r.write("intake/keep.cfg", "mine")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"AcmeIntake\"\nfolder = "+lit(folder)+"\n", true)
	r.offer("acme-intake", "v1.4.0", "acme-intake-windows-amd64.zip", zipOf(t, map[string]string{"app.dll": "new", "lib/x.dll": "x"}))
	res := r.one()
	if !res.OK || !strings.HasPrefix(res.Note, "installed v1.4.0; checks ok after ") {
		t.Fatalf("%+v calls %v", res, r.calls)
	}
	if r.read("intake/app.dll") != "new" || r.read("intake/lib/x.dll") != "x" || r.read("intake/keep.cfg") != "mine" {
		t.Fatal("the files are not as an extract over the folder leaves them")
	}
	if r.read("intake.dokkit-previous/app.dll") != "old" {
		t.Fatal("the old folder was not kept")
	}
	if got := strings.Join(r.calls, ","); got != "stop AcmeIntake,start AcmeIntake" {
		t.Fatal(got)
	}
	if !strings.HasPrefix(r.auth, "Bearer dkm_test") || !strings.Contains(r.query, "os=") || !strings.Contains(r.query, "arch=") {
		t.Fatalf("%q %q", r.auth, r.query)
	}
	st, _ := readState()
	if st.Apps["acme-intake"].Version != "v1.4.0" || !st.Apps["acme-intake"].OK || len(st.UnsentApps) != 0 {
		t.Fatalf("%+v", st)
	}
	if has(r.fetched, "..") || r.fetched[0] != "acme-intake/v1.4.0/acme-intake-windows-amd64.zip" {
		t.Fatal(r.fetched)
	}
	if r.has("data/work/app-acme-intake") {
		t.Fatal("the download was left in work")
	}
}

func TestWindowsServiceFolderIsPutBackWhenChecksFail(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	folder := filepath.Join(r.dir, "intake")
	r.write("intake/app.dll", "old")
	r.write("intake/keep.cfg", "mine")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"AcmeIntake\"\nfolder = "+lit(folder)+"\n", true)
	r.offer("acme-intake", "v1.4.0", "pkg.zip", zipOf(t, map[string]string{"app.dll": "new", "lib/x.dll": "x"}))
	r.healthy.Store(false)
	res := r.one()
	if res.OK || !strings.Contains(res.Note, "checks did not pass within 20ms") || !strings.Contains(res.Note, "http: answered 500") || !strings.Contains(res.Note, "put back") {
		t.Fatalf("%+v", res)
	}
	if r.read("intake/app.dll") != "old" || r.read("intake/keep.cfg") != "mine" || r.has("intake/lib/x.dll") || r.has("intake.dokkit-previous") {
		t.Fatal("the folder is not as it was")
	}
	if got := strings.Join(r.calls, ","); got != "stop AcmeIntake,start AcmeIntake,stop AcmeIntake,start AcmeIntake" {
		t.Fatal(got)
	}
}

func TestWindowsServiceThatWillNotStartIsPutBackWithAFile(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	exe := r.write("bin/acme.exe", "old")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"AcmeIntake\"\nfile = "+lit(exe)+"\n", false)
	r.offer("acme-intake", "v1.4.0", "pkg.zip", zipOf(t, map[string]string{"pkg/acme.exe": "new", "pkg/readme.txt": "x"}))
	starts := 0
	r.startFn = func(string) error {
		starts++
		if starts == 1 {
			return errors.New("did not reach Running")
		}
		return nil
	}
	res := r.one()
	if res.OK || !strings.Contains(res.Note, "did not start") || !strings.Contains(res.Note, "AcmeIntake was started") {
		t.Fatalf("%+v", res)
	}
	if r.read("bin/acme.exe") != "old" || r.read("bin/acme.exe.dokkit-previous") != "old" {
		t.Fatal("the file is not as it was")
	}
}

func TestWindowsServiceReplacesASignedFileDirectly(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	exe := r.write("bin/acme.exe", "old")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"AcmeIntake\"\nfile = "+lit(exe)+"\n", false)
	r.offer("acme-intake", "v1.4.0", "acme.exe", []byte("new"))
	if res := r.one(); !res.OK || !strings.HasSuffix(res.Note, "no checks to wait on") || r.read("bin/acme.exe") != "new" {
		t.Fatalf("%+v", res)
	}
}

func TestWindowsServiceFolderNeedsAnArchive(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.write("intake/a", "old")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"X\"\nfolder = "+lit(filepath.Join(r.dir, "intake"))+"\n", false)
	r.offer("acme-intake", "v1.4.0", "acme.exe", []byte("new"))
	if res := r.one(); res.OK || !strings.Contains(res.Note, "needs an archive") || len(r.calls) != 0 {
		t.Fatalf("%+v %v", res, r.calls)
	}
}

func TestArchiveWithoutTheFileIsRefusedBeforeAnythingStops(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	exe := r.write("bin/acme.exe", "old")
	r.recipe("acme-intake", "kind = \"windows-service\"\nname = \"X\"\nfile = "+lit(exe)+"\n", false)
	r.offer("acme-intake", "v1.4.0", "pkg.zip", zipOf(t, map[string]string{"other.exe": "new"}))
	if res := r.one(); res.OK || !strings.Contains(res.Note, "has no file named acme.exe") || len(r.calls) != 0 || r.read("bin/acme.exe") != "old" {
		t.Fatalf("%+v %v", res, r.calls)
	}
}

func TestInstallerRunsWithItsArgumentsAndHasNothingToPutBack(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	if res := r.one(); !res.OK || !has(r.calls, "setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-") {
		t.Fatalf("%+v %v", res, r.calls)
	}

	r = newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\nargs = [\"/S\", \"/D=C:\\\\Acme\"]\n", false)
	r.offer("acme-intake", "v1.4.0", "setup.msi", []byte("msi"))
	if res := r.one(); !res.OK || !has(r.calls, "msiexec /i ") || !has(r.calls, "setup.msi /qn /norestart /S /D=C:\\Acme") {
		t.Fatalf("%+v %v", res, r.calls)
	}

	r = newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	r.runFn = func(string, []string) (string, error) {
		return strings.Repeat("x", 3000) + "THE END", errors.New("exit status 5")
	}
	res := r.one()
	if res.OK || !strings.Contains(res.Note, "exit status 5") || !strings.Contains(res.Note, "THE END") || !strings.Contains(res.Note, "Nothing was put back") || len(res.Note) > 2000 {
		t.Fatalf("%+v", res)
	}
}

func TestInstallerThatFailsItsChecksSaysNothingWasPutBack(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", true)
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	r.healthy.Store(false)
	if res := r.one(); res.OK || !strings.Contains(res.Note, "was installed but checks did not pass") || !strings.Contains(res.Note, "Nothing was put back") {
		t.Fatalf("%+v", res)
	}
}

func TestADownloadThatDoesNotMatchItsChecksumIsRefused(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	it := r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	r.edit(func() { r.items[0].SHA256 = sha([]byte("something else")) })
	res := r.one()
	if res.OK || !strings.Contains(res.Note, "does not match the checksum the server gave") || len(r.calls) != 0 {
		t.Fatalf("%+v %v", res, r.calls)
	}
	if r.has("data/work/app-acme-intake/" + it.File) {
		t.Fatal("the bad file was kept")
	}
	r.results = nil
	r.edit(func() { r.items[0].SHA256 = "" })
	if res := r.one(); res.OK || !strings.Contains(res.Note, "no file or checksum") {
		t.Fatalf("%+v", res)
	}
}

func TestSignatureIsPinnedOnWindows(t *testing.T) {
	on, off := true, false
	cases := []struct {
		name    string
		signer  string
		pin     string
		valid   bool
		require *bool
		want    string
	}{
		{"no pin takes any valid signature", "Someone Else Inc", "", true, &on, ""},
		{"no pin still needs a valid signature", "Someone Else Inc", "", false, &on, "does not have a valid signature"},
		{"another signer", "Someone Else Inc", "Example Software Ltd", true, &on, `is signed by "Someone Else Inc", not by the pinned signer "Example Software Ltd"`},
		{"invalid", "Example Software Ltd", "Example Software Ltd", false, &on, "does not have a valid signature"},
		{"same name, other case", "EXAMPLE software ltd", "Example Software Ltd", true, &on, ""},
		{"an older server sends nothing, so the check stays on", "Example Software Ltd", "", false, nil, "does not have a valid signature"},
		{"turned off, an unsigned installer runs", "", "Example Software Ltd", false, &off, ""},
	}
	for _, c := range cases {
		r := newAppRig(t)
		appOS = "windows"
		r.recipe("acme-intake", "kind = \"installer\"\n", false)
		r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
		r.edit(func() { r.items[0].Signer, r.items[0].RequireSignature = c.pin, c.require })
		r.signer, r.valid = c.signer, c.valid
		res := r.one()
		if c.want == "" && (!res.OK || !has(r.calls, "setup.exe")) {
			t.Errorf("%s: %+v", c.name, res)
		}
		if c.want != "" && (res.OK || !strings.Contains(res.Note, c.want) || has(r.calls, "setup.exe")) {
			t.Errorf("%s: %+v %v", c.name, res, r.calls)
		}
	}
}

func TestSignatureOutputIsRead(t *testing.T) {
	for out, want := range map[string][2]any{
		"Valid\r\nExample Software Ltd\r\n": {"Example Software Ltd", true},
		"NotSigned\r\n":                     {"", false},
		"HashMismatch\nExample\n":           {"Example", false},
		"":                                  {"", false},
	} {
		if s, v := parseSignature(out); s != want[0] || v != want[1] {
			t.Errorf("%q: %q %v", out, s, v)
		}
	}
}

func TestOnlyAnAdministratorsRecipeIsUsed(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	if res := r.one(); res.OK || res.Note != "no dokkit.toml in this machine's folders declares [app] for acme-intake" {
		t.Fatalf("%+v", res)
	}

	r.results = nil
	dir := r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.trustBad = "dokkit.toml"
	if res := r.one(); res.OK || res.Note != filepath.Join(dir, "dokkit.toml")+" can be changed by accounts other than administrators, so its [app] is not used" {
		t.Fatalf("%+v", res)
	}

	r.results, r.trustBad = nil, "acme-intake"
	if res := r.one(); res.OK || !strings.Contains(res.Note, "its [app] is not used") || len(r.calls) != 0 {
		t.Fatalf("the folder counts as well: %+v", res)
	}
}

func TestAKindIsRefusedOnTheWrongSystem(t *testing.T) {
	for _, c := range []struct{ os, kind, extra, say string }{
		{"linux", "windows-service", "name = \"X\"\nfolder = \"/x\"\n", "Windows only"},
		{"linux", "installer", "", "Windows only"},
		{"windows", "systemd", "name = \"x\"\nfile = \"/x\"\n", "Linux only"},
		{"linux", "launchd", "name = \"x\"\nfile = \"/x\"\n", "macOS only"},
	} {
		r := newAppRig(t)
		appOS = c.os
		r.recipe("acme-intake", "kind = \""+c.kind+"\"\n"+c.extra, false)
		r.offer("acme-intake", "v1.4.0", "x.zip", []byte("z"))
		if res := r.one(); res.OK || !strings.Contains(res.Note, c.say) || len(r.fetched) != 0 {
			t.Errorf("%s on %s: %+v", c.kind, c.os, res)
		}
	}
}

const composeText = "name: acme\n# the services\nservices:\n  intake:\n    image: \"registry.example.com:5000/acme/intake:1.3.0\" # pinned\n    ports:\n      - \"80:80\"\n  worker:\n    image: acme/worker:2\nvolumes:\n  intake:\n"

func TestComposeTagIsSetOnOneServiceOnly(t *testing.T) {
	got, err := retag(composeText, "intake", "1.4.0")
	want := strings.Replace(composeText, "intake:1.3.0\"", "intake:1.4.0\"", 1)
	if err != nil || got != want {
		t.Fatalf("%v\n%s", err, got)
	}
	crlf := strings.ReplaceAll(composeText, "\n", "\r\n")
	if got, err := retag(crlf, "worker", "v9"); err != nil || got != strings.Replace(crlf, "worker:2", "worker:v9", 1) {
		t.Fatalf("%v %q", err, got)
	}
	for text, tag := range map[string]string{"services:\n  a:\n    image: x/y\n": "x/y:t", "services:\n  a:\n    image: x/y@sha256:abc\n": "x/y:t", "services:\n  a:\n    image: x/y:1\n": "x/y:t"} {
		if got, err := retag(text, "a", "t"); err != nil || !strings.Contains(got, "image: "+tag+"\n") {
			t.Errorf("%q: %q %v", text, got, err)
		}
	}
	for text, say := range map[string]string{
		"services:\n  a:\n    image: x\n":                      "no service named b",
		"volumes:\n  b:\n":                                     "no service named b",
		"services:\n  a:\n    image: x\n  b:\n    ports: []\n": "no image line",
		"services:\n  b:\n    build: .\n  c:\n    image: y\n":  "no image line",
	} {
		if _, err := retag(text, "b", "t"); err == nil || !strings.Contains(err.Error(), say) {
			t.Errorf("%q: %v", text, err)
		}
	}
	if composeTag("v{number}-{version}", "v1.4.0") != "v1.4.0-v1.4.0" || composeTag("{number}", "v1.4.0") != "1.4.0" {
		t.Fatal("tag placeholders")
	}
}

func TestComposeIsPulledThenStarted(t *testing.T) {
	r := newAppRig(t)
	file := r.write("srv/compose.yml", composeText)
	r.recipe("acme-intake", "kind = \"compose\"\ncompose_file = "+lit(file)+"\ncompose_service = \"intake\"\ntag = \"{number}\"\n", true)
	it := r.offer("acme-intake", "v1.4.0", "", nil)
	it.File, it.SHA256 = "", ""
	r.edit(func() { r.items[0] = it })
	res := r.one()
	if !res.OK || len(r.fetched) != 0 {
		t.Fatalf("%+v %v", res, r.fetched)
	}
	if got := r.read("srv/compose.yml"); got != strings.Replace(composeText, "intake:1.3.0\"", "intake:1.4.0\"", 1) {
		t.Fatal(got)
	}
	if r.read("srv/compose.yml.dokkit-previous") != composeText {
		t.Fatal("the old file was not kept")
	}
	pull, up := "docker compose -f "+file+" pull intake", "docker compose -f "+file+" up -d intake"
	if got := strings.Join(r.calls, ","); got != pull+","+up {
		t.Fatal(got)
	}
}

func TestComposeBytesAreRestoredAndStartedAgain(t *testing.T) {
	for _, failing := range []string{"health", "up", "pull"} {
		r := newAppRig(t)
		file := r.write("srv/compose.yml", composeText)
		r.recipe("acme-intake", "kind = \"compose\"\ncompose_file = "+lit(file)+"\ncompose_service = \"intake\"\n", true)
		r.edit(func() { r.items = []appItem{{Service: "acme-intake", Version: "v1.4.0", HealthSeconds: 1}} })
		switch failing {
		case "health":
			r.healthy.Store(false)
		default:
			r.runFn = func(name string, args []string) (string, error) {
				if slices.Contains(args, failing) {
					return "no such image", errors.New("exit status 1")
				}
				return "", nil
			}
		}
		res := r.one()
		if res.OK || r.read("srv/compose.yml") != composeText {
			t.Fatalf("%s: %+v %q", failing, res, r.read("srv/compose.yml"))
		}
		ups := 0
		for _, c := range r.calls {
			if strings.HasSuffix(c, "up -d intake") {
				ups++
			}
		}
		wantUps := map[string]int{"health": 2, "up": 2, "pull": 0}[failing]
		if ups != wantUps {
			t.Errorf("%s: up -d ran %d times: %v", failing, ups, r.calls)
		}
	}
}

func TestComposeServiceNotFoundChangesNothing(t *testing.T) {
	r := newAppRig(t)
	file := r.write("srv/compose.yml", composeText)
	r.recipe("acme-intake", "kind = \"compose\"\ncompose_file = "+lit(file)+"\ncompose_service = \"nope\"\n", false)
	r.edit(func() { r.items = []appItem{{Service: "acme-intake", Version: "v1.4.0"}} })
	if res := r.one(); res.OK || !strings.Contains(res.Note, "no service named nope") || len(r.calls) != 0 || r.read("srv/compose.yml") != composeText {
		t.Fatalf("%+v", res)
	}
}

func TestSystemdFileFromATarballIsReplacedAndRestartedThenRestored(t *testing.T) {
	r := newAppRig(t)
	appOS = "linux"
	bin := r.write("usr/acme-intake", "old")
	r.recipe("acme-intake", "kind = \"systemd\"\nname = \"acme-intake\"\nfile = "+lit(bin)+"\n", true)
	r.offer("acme-intake", "v1.4.0", "acme.tar.gz", tgzOf(t, tarEntry{name: "acme/", typ: tar.TypeDir}, tarEntry{name: "acme/acme-intake", body: "new"}, tarEntry{name: "acme/README", body: "r"}))
	res := r.one()
	if !res.OK || r.read("usr/acme-intake") != "new" || r.has("usr/acme-intake.new") || r.read("usr/acme-intake.dokkit-previous") != "old" {
		t.Fatalf("%+v", res)
	}
	if got := strings.Join(r.calls, ","); got != "systemctl restart acme-intake" {
		t.Fatal(got)
	}

	r.results, r.calls = nil, nil
	r.write("usr/acme-intake", "old")
	r.healthy.Store(false)
	res = r.one()
	if res.OK || r.read("usr/acme-intake") != "old" || !strings.Contains(res.Note, "put back") {
		t.Fatalf("%+v", res)
	}
	if got := strings.Join(r.calls, ","); got != "systemctl restart acme-intake,systemctl restart acme-intake" {
		t.Fatal(got)
	}
}

func TestLaunchdFolderFromATgzIsKickstartedAndRestoredWhenItWillNotStart(t *testing.T) {
	r := newAppRig(t)
	appOS = "darwin"
	r.write("opt/acme/bin/run", "old")
	r.write("opt/acme/data.db", "data")
	r.recipe("acme-intake", "kind = \"launchd\"\nname = \"com.example.intake\"\nfolder = "+lit(filepath.Join(r.dir, "opt", "acme"))+"\n", false)
	r.offer("acme-intake", "v1.4.0", "acme.tgz", tgzOf(t, tarEntry{name: "bin/run", body: "new"}))
	kicks := 0
	r.runFn = func(name string, args []string) (string, error) {
		if kicks++; kicks == 1 {
			return "service not found", errors.New("exit status 113")
		}
		return "", nil
	}
	res := r.one()
	if res.OK || r.read("opt/acme/bin/run") != "old" || r.read("opt/acme/data.db") != "data" || !strings.Contains(res.Note, "com.example.intake was started") {
		t.Fatalf("%+v", res)
	}
	kick := "launchctl kickstart -k system/com.example.intake"
	if got := strings.Join(r.calls, ","); got != kick+","+kick {
		t.Fatal(got)
	}
}

func TestArchivesThatEscapeOrLinkAreRefusedBeforeAnythingChanges(t *testing.T) {
	bad := map[string][]byte{
		"zip with ..": zipOf(t, map[string]string{"../evil": "x"}),
		"tar with ..": tgzOf(t, tarEntry{name: "../evil", body: "x"}),
		"tar link":    tgzOf(t, tarEntry{name: "a", typ: tar.TypeSymlink, link: "/etc/passwd"}),
		"tar hard":    tgzOf(t, tarEntry{name: "a", typ: tar.TypeLink, link: "b"}),
	}
	var zl bytes.Buffer
	zw := zip.NewWriter(&zl)
	h := &zip.FileHeader{Name: "link"}
	h.SetMode(os.ModeSymlink | 0o777)
	w, _ := zw.CreateHeader(h)
	w.Write([]byte("/etc/passwd"))
	zw.Close()
	bad["zip link"] = zl.Bytes()
	for name, body := range bad {
		r := newAppRig(t)
		appOS = "linux"
		r.write("opt/acme/keep", "old")
		file := "x.zip"
		if strings.HasPrefix(name, "tar") {
			file = "x.tar.gz"
		}
		r.recipe("acme-intake", "kind = \"systemd\"\nname = \"x\"\nfolder = "+lit(filepath.Join(r.dir, "opt", "acme"))+"\n", false)
		r.offer("acme-intake", "v1.4.0", file, body)
		res := r.one()
		if res.OK || len(r.calls) != 0 || r.read("opt/acme/keep") != "old" || r.has("opt/acme.dokkit-previous") || r.has("evil") {
			t.Errorf("%s: %+v %v", name, res, r.calls)
		}
	}
}

func TestHealthWait(t *testing.T) {
	r := newAppRig(t)
	dir := r.recipe("acme-intake", "kind = \"installer\"\n", false)
	ctx := context.Background()
	load := func(extra string) *declaration {
		text := "schema = 1\n[service]\nid = \"acme-intake\"\n" + extra + "[app]\nkind = \"installer\"\n"
		d, err := parseDeclaration(filepath.Join(dir, "dokkit.toml"), text)
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	if note, err := waitHealthy(ctx, load(""), "v1.4.0", time.Second); err != nil || note != "no checks to wait on" {
		t.Fatalf("%q %v", note, err)
	}

	d := load("version_from = \"VERSION\"\n")
	os.WriteFile(filepath.Join(dir, "VERSION"), []byte("1.3.0\nbuild 9\n"), 0o644)
	_, err := waitHealthy(ctx, d, "v1.4.0", 10*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), `the version file says "1.3.0", not v1.4.0`) {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "VERSION"), []byte("1.4.0\n"), 0o644)
	if note, err := waitHealthy(ctx, d, "v1.4.0", time.Second); err != nil || !strings.HasPrefix(note, "checks ok after ") {
		t.Fatalf("%q %v", note, err)
	}

	r.healthy.Store(false)
	d = load("")
	d.Check = []check{{Type: "http", URL: r.health.URL, name: "front-door"}, {Type: "tcp", Port: 0, name: "skipped"}}
	if _, err := waitHealthy(ctx, d, "v1", 10*time.Millisecond); err == nil || !strings.Contains(err.Error(), "front-door: answered 500") {
		t.Fatalf("the failing check is named: %v", err)
	}
	r.healthy.Store(true)
	if _, err := waitHealthy(ctx, d, "v1", 10*time.Millisecond); err != nil {
		t.Fatal(err)
	}

	a := &appRecipe{}
	if healthWait(a, appItem{}) != 5*time.Minute || healthWait(a, appItem{HealthSeconds: 90}) != 90*healthUnit || healthWait(&appRecipe{HealthWait: time.Minute}, appItem{HealthSeconds: 90}) != time.Minute {
		t.Fatal("health wait order is the recipe, the release, then five minutes")
	}
}

func TestAResultTheServerDidNotTakeIsSentFirstOnTheNextRun(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	r.edit(func() { r.failPost = 1 })
	got, code := r.run()
	st, _ := readState()
	if len(got) != 0 || code != 0 || len(st.UnsentApps) != 1 || st.UnsentApps[0].Version != "v1.4.0" {
		t.Fatalf("%v %d %+v", got, code, st)
	}
	r.edit(func() { r.items = nil })
	got, _ = r.run()
	st, _ = readState()
	if len(got) != 1 || got[0].Service != "acme-intake" || !got[0].OK || len(st.UnsentApps) != 0 {
		t.Fatalf("%v %+v", got, st)
	}
}

func TestARefusedResultIsDroppedAndFailuresMakeTheRunFail(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.offer("acme-intake", "v1.4.0", "setup.exe", []byte("exe"))
	_, code := r.run()
	st, _ := readState()
	if code != 1 || len(st.UnsentApps) != 0 || st.Apps["acme-intake"].OK {
		t.Fatalf("%d %+v", code, st)
	}
	r.edit(func() { r.postCode = 403 })
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	got, _ := r.run()
	st, _ = readState()
	if len(got) != 1 || len(st.UnsentApps) != 0 {
		t.Fatalf("a refused result is not kept to send again: %v %+v", got, st)
	}
}

func TestTheListIsAskedForAndItsAnswersAreHandled(t *testing.T) {
	r := newAppRig(t)
	r.edit(func() { r.listCode = 500 })
	if _, code := r.run(); code != 1 {
		t.Fatalf("a failing server fails the run: %d", code)
	}
	r.edit(func() { r.listCode = 404 })
	if _, code := r.run(); code != 0 {
		t.Fatalf("a server that knows no app releases is not an error: %d", code)
	}
	r.edit(func() { r.listCode = 0 })
	if got, code := r.run(); code != 0 || len(got) != 0 {
		t.Fatalf("an empty list does nothing: %v %d", got, code)
	}
	r.srv.Close()
	if _, code := r.run(); code != 1 {
		t.Fatalf("an unreachable server fails the run: %d", code)
	}
}

func TestAnAppFileIsFetchedWithEachPartEscaped(t *testing.T) {
	r := newAppRig(t)
	appOS = "windows"
	r.recipe("acme-intake", "kind = \"installer\"\n", false)
	r.offer("acme-intake", "v1.4.0", "my setup.exe", []byte("exe"))
	if res := r.one(); !res.OK || r.fetched[0] != "acme-intake/v1.4.0/my%20setup.exe" {
		t.Fatalf("%+v %v", res, r.fetched)
	}
	r.results = nil
	r.edit(func() {
		r.items = []appItem{{Service: "acme-intake", Version: "v1.4.0", File: "../x.exe", SHA256: "aa", Signer: "s"}}
	})
	if res := r.one(); res.OK || !strings.Contains(res.Note, "not a service, version and file") {
		t.Fatalf("%+v", res)
	}
}

func TestFilesAreCopiedWithEverythingInThem(t *testing.T) {
	r := newAppRig(t)
	r.write("from/a/b.txt", "b")
	r.write("from/c.txt", "c")
	os.MkdirAll(filepath.Join(r.dir, "from", "empty"), 0o755)
	to := filepath.Join(r.dir, "to")
	if err := copyAll(filepath.Join(r.dir, "from"), to); err != nil {
		t.Fatal(err)
	}
	if r.read("to/a/b.txt") != "b" || r.read("to/c.txt") != "c" || !r.has("to/empty") {
		t.Fatal("the copy is not whole")
	}
	r.write("src/new.txt", "n")
	r.write("src/sub/deep.txt", "d")
	if err := putTree(filepath.Join(r.dir, "src"), to); err != nil {
		t.Fatal(err)
	}
	if r.read("to/new.txt") != "n" || r.read("to/sub/deep.txt") != "d" || r.read("to/c.txt") != "c" {
		t.Fatal("put over did not add and keep")
	}
	if had, err := backup(filepath.Join(r.dir, "nothing"), true); err != nil || had {
		t.Fatalf("%v %v", had, err)
	}
	if err := restore(filepath.Join(r.dir, "to"), true, false); err != nil || r.has("to") {
		t.Fatalf("a folder that was not there is removed again: %v", err)
	}
}
