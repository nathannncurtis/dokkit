package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCompareVersions(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{{"v1.2.3", "v1.2.3", 0}, {"v1.2.4", "v1.2.3", 1}, {"v1.10.0", "v1.9.9", 1}, {"v0.9.9", "v1.0.0", -1},
		{"v0.0.0-dev", "v0.0.1", -1}, {"v0.0.1", "", 1}, {"1.2.3", "v0.0.0", -1}} {
		if got, err := compareVersions(c.a, c.b); err != nil || got != c.want {
			t.Errorf("%q vs %q: %d %v, want %d", c.a, c.b, got, err, c.want)
		}
	}
	if _, err := compareVersions("v0.0.0-dev", "x"); err == nil {
		t.Error("two non-versions are not comparable")
	}
}

func testKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(nil)
	old := releaseKey
	releaseKey = base64.StdEncoding.EncodeToString(pub)
	t.Cleanup(func() { releaseKey = old })
	return priv
}

func sumsFor(ver string, files map[string][]byte, sep string) []byte {
	var b bytes.Buffer
	b.WriteString("version " + ver + "\n")
	for n, c := range files {
		h := sha256.Sum256(c)
		fmt.Fprintf(&b, "%x%s%s\n", h, sep, n)
	}
	return b.Bytes()
}

func sign(priv ed25519.PrivateKey, sums []byte) []byte {
	return []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, sums)) + "\n")
}

func TestVerifyRelease(t *testing.T) {
	priv := testKey(t)
	files := map[string][]byte{"a.exe": []byte("a"), "b.zip": []byte("b")}
	for _, sep := range []string{"  ", " *"} {
		sums := sumsFor("v1.2.3", files, sep)
		got, err := verifyRelease(sums, sign(priv, sums), "v1.2.3")
		h := sha256.Sum256([]byte("a"))
		if err != nil || len(got) != 2 || got["a.exe"] != hex.EncodeToString(h[:]) {
			t.Fatalf("separator %q: %v %v", sep, got, err)
		}
	}
	sums := sumsFor("v1.2.3", files, "  ")
	sig := sign(priv, sums)
	tampered := bytes.Replace(sums, []byte("a.exe"), []byte("c.exe"), 1)
	other := []byte(strings.Replace(string(sig), string(sig[:3]), "AAA", 1))
	for name, c := range map[string]struct {
		sums, sig []byte
		want, say string
	}{
		"tampered list":      {tampered, sig, "v1.2.3", "signature"},
		"tampered signature": {sums, other, "v1.2.3", "signature"},
		"not base64":         {sums, []byte("!!"), "v1.2.3", "base64"},
		"wrong version":      {sums, sig, "v1.2.4", "version v1.2.4"},
	} {
		if _, err := verifyRelease(c.sums, c.sig, c.want); err == nil || !strings.Contains(err.Error(), c.say) {
			t.Errorf("%s: %v", name, err)
		}
	}
	bad := []byte("version v1.2.3\nnothex  x\n")
	if _, err := verifyRelease(bad, sign(priv, bad), "v1.2.3"); err == nil {
		t.Error("a line that is not a hash is refused")
	}
}

func TestZipEntriesOutsideTheFolderAreRefused(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "server")
	for _, n := range []string{"../evil.txt", `..\evil.txt`, "a/../../evil.txt"} {
		if _, err := safeJoin(dest, n); err == nil && runtime.GOOS == "windows" || err == nil && !strings.Contains(n, `\`) {
			t.Errorf("%q was accepted", n)
		}
	}
	if p, err := safeJoin(dest, "bin/x.ps1"); err != nil || p != filepath.Join(dest, "bin", "x.ps1") {
		t.Errorf("%q %v", p, err)
	}
	z := filepath.Join(t.TempDir(), "s.zip")
	writeZip(t, z, map[string]string{"install.ps1": "ok", "../evil.txt": "no"})
	if err := unzip(z, dest); err == nil {
		t.Error("a zip with an escaping entry was unpacked")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dest), "evil.txt")); err == nil {
		t.Error("wrote outside")
	}
	if _, err := os.Stat(dest); err == nil {
		t.Error("wrote part of a refused zip")
	}
}

func writeZip(t *testing.T, path string, files map[string]string) []byte {
	t.Helper()
	var b bytes.Buffer
	w := zip.NewWriter(&b)
	for n, c := range files {
		f, _ := w.Create(n)
		f.Write([]byte(c))
	}
	w.Close()
	os.WriteFile(path, b.Bytes(), 0o600)
	return b.Bytes()
}

// rig is a machine with a fake Windows and a fake Dokkit server.
type rig struct {
	t        *testing.T
	priv     ed25519.PrivateKey
	dir      string
	srv      *httptest.Server
	mu       sync.Mutex
	wanted   string // the version the server asks for; "" for 204
	query    string
	files    map[string]map[string][]byte // version -> file -> bytes
	sums     map[string][]byte            // overrides the list served for a version
	results  []outcome
	failPost bool
	failPosts int
	cutFiles  int
	failPS   bool
	noStart  string // a program file content that will not start
	calls    []string
	port     bool
	server   bool
}

func newRig(t *testing.T, hostsServer bool) *rig {
	r := &rig{t: t, priv: testKey(t), dir: t.TempDir(), files: map[string]map[string][]byte{}, sums: map[string][]byte{}, port: true, server: hostsServer}
	data := filepath.Join(r.dir, "data")
	os.MkdirAll(data, 0o700)
	os.MkdirAll(filepath.Join(r.dir, "up"), 0o700)
	os.MkdirAll(filepath.Join(r.dir, "prog"), 0o700)
	os.WriteFile(filepath.Join(r.dir, "up", "u.exe"), []byte("v1.0.0"), 0o700)
	os.WriteFile(filepath.Join(r.dir, "prog", "dokkit.exe"), []byte("v1.0.0"), 0o700)
	oldWhere, oldOps, oldLoad, oldVer, oldRetry, oldGap := where, ops, loadClient, version, retryFor, minGap
	where = layout{data: data, updaterExe: filepath.Join(r.dir, "up", "u.exe"), programExe: filepath.Join(r.dir, "prog", "dokkit.exe"),
		serverBin: filepath.Join(r.dir, "nosuch", "dokkit.bat"), serverEnv: filepath.Join(r.dir, "settings.env")}
	if hostsServer {
		where.serverBin = filepath.Join(r.dir, "dokkit.bat")
		os.WriteFile(where.serverBin, nil, 0o600)
		os.WriteFile(where.serverEnv, []byte("A=1\nPORT=8443\n"), 0o600)
	}
	version, retryFor, minGap = "v1.0.0", 0, 0
	ops = hostOps{
		admin: func() bool { return true },
		lock:  func(string) (func(), error) { return func() {}, nil },
		stopService: func(string) error {
			r.calls = append(r.calls, "stop")
			return nil
		},
		startService: func(string) error {
			b, _ := os.ReadFile(where.programExe)
			r.calls = append(r.calls, "start "+string(b))
			if string(b) == r.noStart {
				return errors.New("did not reach Running")
			}
			return nil
		},
		installer: func(_ context.Context, script string) (string, error) {
			r.calls = append(r.calls, "install.ps1")
			if _, err := os.Stat(script); err != nil {
				t.Errorf("installer script missing: %v", err)
			}
			if r.failPS {
				return strings.Repeat("x", 3000) + "THE END", errors.New("exit status 1")
			}
			return "installed", nil
		},
		portUp: func(p string) bool { r.calls = append(r.calls, "port "+p); return r.port },
		versionOf: func(exe string) string {
			b, _ := os.ReadFile(exe)
			if _, ok := parseVersion(string(b)); ok {
				return string(b)
			}
			return devVersion
		},
	}
	t.Cleanup(func() {
		where, ops, loadClient, version, retryFor, minGap = oldWhere, oldOps, oldLoad, oldVer, oldRetry, oldGap
	})
	r.srv = httptest.NewServer(http.HandlerFunc(r.handle))
	t.Cleanup(r.srv.Close)
	loadClient = func() (*client, error) { return &client{url: r.srv.URL, key: "dkm_test"}, nil }
	return r
}

func (r *rig) handle(w http.ResponseWriter, q *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch {
	case q.URL.Path == "/api/v1/update":
		r.query = q.URL.RawQuery
		if r.wanted == "" {
			w.WriteHeader(204)
			return
		}
		fmt.Fprintf(w, `{"version":%q}`, r.wanted)
	case q.URL.Path == "/api/v1/update/result":
		if r.failPost || r.failPosts > 0 {
			r.failPosts--
			w.WriteHeader(503)
			return
		}
		var o outcome
		var b bytes.Buffer
		b.ReadFrom(q.Body)
		if err := json.Unmarshal(b.Bytes(), &o); err != nil {
			w.WriteHeader(400)
			return
		}
		r.results = append(r.results, o)
	case strings.HasPrefix(q.URL.Path, "/api/v1/releases/"):
		parts := strings.Split(strings.TrimPrefix(q.URL.Path, "/api/v1/releases/"), "/")
		ver, name := parts[0], parts[1]
		if s, ok := r.sums[ver]; ok && name == "SHA256SUMS" {
			w.Write(s)
			return
		}
		if c, ok := r.files[ver][name]; ok {
			if r.cutFiles > 0 && strings.HasPrefix(name, "dokkit-") {
				r.cutFiles--
				w.Header().Set("Content-Length", strconv.Itoa(len(c)+100))
				w.Write(c)
				w.(http.Flusher).Flush()
				conn, _, _ := w.(http.Hijacker).Hijack()
				conn.Close()
				return
			}
			w.Write(c)
			return
		}
		w.WriteHeader(404)
	}
}

// publish holds a release the way the release workflow writes it.
func (r *rig) publish(ver string, files map[string][]byte) {
	programFile := fmt.Sprintf("dokkit-%s-%s", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "windows" {
		programFile += ".exe"
	}
	all := map[string][]byte{programFile: []byte(ver)}
	for k, v := range files {
		all[k] = v
	}
	sums := sumsFor(ver, all, "  ")
	all["SHA256SUMS"], all["SHA256SUMS.sig"] = sums, sign(r.priv, sums)
	r.files[ver] = all
}

func (r *rig) serverZip() []byte {
	return writeZip(r.t, filepath.Join(r.dir, "z.zip"), map[string]string{"install.ps1": "x", "bin/dokkit.bat": "y"})
}

func (r *rig) read(p string) string { b, _ := os.ReadFile(p); return string(b) }

func TestNothingWanted(t *testing.T) {
	r := newRig(t, false)
	if code := updaterRun(); code != 0 || len(r.results) != 0 {
		t.Fatalf("%d %v", code, r.results)
	}
	if !strings.Contains(r.query, "program=v1.0.0") || !strings.Contains(r.query, "updater=v1.0.0") || strings.Contains(r.query, "server=") {
		t.Fatalf("a machine with no server asks without it: %s", r.query)
	}
	if !strings.Contains(r.read(filepath.Join(where.data, "updater.log")), "nothing wanted") {
		t.Fatal("the outcome is not in the log")
	}
}

func TestARunRightAfterAnotherWaitsOutTheGapThenChecks(t *testing.T) {
	r := newRig(t, false)
	minGap = 300 * time.Millisecond
	scheduled := 0
	ops.schedule = func() { scheduled++ }
	if updaterRun() != 0 || r.query == "" || scheduled != 1 {
		t.Fatalf("the first run did not ask or refresh the schedule: %q %d", r.query, scheduled)
	}
	r.query = ""
	start := time.Now()
	if updaterRun() != 0 || r.query == "" || scheduled != 2 {
		t.Fatalf("a run right after another was dropped: %q %d", r.query, scheduled)
	}
	if waited := time.Since(start); waited < 200*time.Millisecond {
		t.Fatalf("it asked after %v, inside the %v gap", waited, minGap)
	}
}

func TestAResultIsRetriedWhileTheServerRestarts(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.wanted, r.failPosts, retryFor = "v1.1.0", 1, 10*time.Second
	if code := updaterRun(); code != 0 || len(r.results) != 1 || !r.results[0].OK {
		t.Fatalf("%d %+v", code, r.results)
	}
}

func TestADownloadCutByAServerRestartStartsAgain(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.wanted, r.cutFiles, retryFor = "v1.1.0", 1, 10*time.Second
	if code := updaterRun(); code != 0 || len(r.results) != 1 || !r.results[0].OK {
		t.Fatalf("%d %+v", code, r.results)
	}
	if r.cutFiles != 0 {
		t.Fatal("the download was never cut")
	}
}

func TestProgramOnly(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.wanted = "v1.1.0"
	if code := updaterRun(); code != 0 {
		t.Fatalf("%d %v", code, r.results)
	}
	if len(r.results) != 1 || !r.results[0].OK || r.results[0].Note != "program, updater" || r.results[0].Version != "v1.1.0" {
		t.Fatalf("%+v", r.results)
	}
	if r.read(where.programExe) != "v1.1.0" || r.read(where.programExe+".previous") != "v1.0.0" {
		t.Fatal("program not swapped or old one not kept")
	}
	if r.read(where.updaterExe) != "v1.1.0" || r.read(where.updaterExe+".previous") != "v1.0.0" {
		t.Fatal("updater not swapped")
	}
	if got := strings.Join(r.calls, ","); got != "stop,start v1.1.0" {
		t.Fatal(got)
	}
	st, _ := readState()
	if st.Unsent != nil || st.Last == nil || !st.Last.OK {
		t.Fatalf("%+v", st)
	}
}

func TestServerAndProgram(t *testing.T) {
	r := newRig(t, true)
	r.publish("v1.1.0", map[string][]byte{serverZip: r.serverZip()})
	r.wanted = "v1.1.0"
	if code := updaterRun(); code != 0 {
		t.Fatalf("%d %v", code, r.results)
	}
	if !strings.Contains(r.query, "server=v0.0.0-dev") {
		t.Fatal(r.query)
	}
	if got := strings.Join(r.calls, ","); got != "install.ps1,port 8443,stop,start v1.1.0" {
		t.Fatal(got)
	}
	if r.results[0].Note != "server, program, updater" {
		t.Fatalf("%+v", r.results)
	}
	if st, _ := readState(); st.Server != "v1.1.0" {
		t.Fatal("the server's version is not kept")
	}
	if !exists(filepath.Join(where.work(), "server-v1.1.0", "bin", "dokkit.bat")) {
		t.Fatal("not unpacked")
	}
	r.wanted = ""
	updaterRun()
	if !strings.Contains(r.query, "server=v1.1.0") {
		t.Fatal(r.query)
	}
}

func TestServerInstallerFailureStopsEverything(t *testing.T) {
	r := newRig(t, true)
	r.publish("v1.1.0", map[string][]byte{serverZip: r.serverZip()})
	r.wanted, r.failPS = "v1.1.0", true
	if code := updaterRun(); code != 1 {
		t.Fatal(code)
	}
	o := r.results[0]
	if o.OK || !strings.HasSuffix(o.Note, "THE END") || len(o.Note) > 2000 || strings.Contains(o.Note, strings.Repeat("x", 1600)) {
		t.Fatalf("%d %.80s", len(o.Note), o.Note)
	}
	if r.read(where.programExe) != "v1.0.0" {
		t.Fatal("the program went on after the server failed")
	}
	if st, _ := readState(); st.Server != "" {
		t.Fatal("a failed server install was recorded")
	}
}

func TestServerThatDoesNotAnswerIsAFailure(t *testing.T) {
	r := newRig(t, true)
	r.publish("v1.1.0", map[string][]byte{serverZip: r.serverZip()})
	r.wanted, r.port = "v1.1.0", false
	updaterRun()
	if r.results[0].OK || !strings.Contains(r.results[0].Note, "does not answer on port 8443") {
		t.Fatalf("%+v", r.results)
	}
}

func TestBadSignatureInstallsNothing(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.files["v1.1.0"]["SHA256SUMS"] = append(r.files["v1.1.0"]["SHA256SUMS"], "\n"...)
	r.wanted = "v1.1.0"
	if code := updaterRun(); code != 1 {
		t.Fatal(code)
	}
	if o := r.results[0]; o.OK || !strings.Contains(o.Note, "signature") {
		t.Fatalf("%+v", o)
	}
	if r.read(where.programExe) != "v1.0.0" || len(r.calls) != 0 {
		t.Fatal("something was installed")
	}
}

func TestHashMismatchInstallsNothing(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	for n := range r.files["v1.1.0"] {
		if strings.HasPrefix(n, "dokkit-") {
			r.files["v1.1.0"][n] = []byte("swapped")
		}
	}
	r.wanted = "v1.1.0"
	updaterRun()
	if o := r.results[0]; o.OK || !strings.Contains(o.Note, "does not match the signed list") {
		t.Fatalf("%+v", o)
	}
	if r.read(where.programExe) != "v1.0.0" || len(r.calls) != 0 {
		t.Fatal("something was installed")
	}
}

func TestProgramThatDoesNotStartIsPutBack(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.wanted, r.noStart = "v1.1.0", "v1.1.0"
	if code := updaterRun(); code != 1 {
		t.Fatal(code)
	}
	if r.read(where.programExe) != "v1.0.0" {
		t.Fatal("the previous file was not put back")
	}
	if got := strings.Join(r.calls, ","); got != "stop,start v1.1.0,stop,start v1.0.0" {
		t.Fatal(got)
	}
	if o := r.results[0]; o.OK || !strings.Contains(o.Note, "did not reach Running") || !strings.Contains(o.Note, "put back and is running") {
		t.Fatalf("%+v", o)
	}
	if r.read(where.updaterExe) != "v1.0.0" {
		t.Fatal("the updater went on after the program failed")
	}
}

func TestResultThatCannotBePostedGoesNextRun(t *testing.T) {
	r := newRig(t, false)
	r.publish("v1.1.0", nil)
	r.wanted, r.failPost = "v1.1.0", true
	updaterRun()
	if st, _ := readState(); st.Unsent == nil || !st.Unsent.OK || len(r.results) != 0 {
		t.Fatalf("%+v", st)
	}
	r.failPost, r.wanted = false, ""
	if updaterRun() != 0 || len(r.results) != 1 || r.results[0].Version != "v1.1.0" || !r.results[0].OK {
		t.Fatalf("%+v", r.results)
	}
	if st, _ := readState(); st.Unsent != nil {
		t.Fatal("still unsent")
	}
}

func TestOlderVersionIsNeverInstalled(t *testing.T) {
	r := newRig(t, false)
	os.WriteFile(where.programExe, []byte("v1.5.0"), 0o700)
	version = "v1.5.0"
	r.publish("v1.2.0", nil)
	r.wanted = "v1.2.0"
	updaterRun()
	if o := r.results[0]; o.OK || !strings.Contains(o.Note, "newer than v1.2.0") {
		t.Fatalf("%+v", o)
	}
	if r.read(where.programExe) != "v1.5.0" || len(r.calls) != 0 {
		t.Fatal("went backwards")
	}
	// A part that is already newer is skipped; the others still go.
	r.results = nil
	r.publish("v1.2.0", nil)
	os.WriteFile(where.updaterExe, []byte("v1.0.0"), 0o700)
	version = "v1.0.0"
	updaterRun()
	if o := r.results[0]; !o.OK || !strings.HasPrefix(o.Note, "updater; program is on v1.5.0") {
		t.Fatalf("%+v", o)
	}
	if r.read(where.programExe) != "v1.5.0" {
		t.Fatal("went backwards")
	}
}

func TestOnlyAnAdministratorRunsIt(t *testing.T) {
	r := newRig(t, false)
	ops.admin = func() bool { return false }
	r.wanted = "v1.1.0"
	if updaterRun() != 1 || r.query != "" {
		t.Fatal("ran without administrator rights")
	}
}
