#!/usr/bin/env python3
import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PROGRAMS = os.path.join(HERE, "programs")
WORK = os.path.join(tempfile.gettempdir(), "dokkit_conformance")
LANGS = ["python", "javascript", "go", "rust", "dotnet", "java", "php", "powershell", "shell", "elixir"]
FIELDS = {"python", "javascript", "go", "rust", "php"}
KINDS = ["version", "beat", "job", "check", "metric", "log", "fields", "error", "isolation"]
PSQL = shutil.which("psql") or r"C:\Program Files\PostgreSQL\17\bin\psql.exe"


def tool(*names, extra=()):
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    for p in extra:
        if os.path.exists(p):
            return p


def elixir_path():
    dirs = [r"C:\Program Files\Elixir\bin"]
    otp = r"C:\Program Files\Erlang OTP\bin"
    if os.path.isdir(otp):
        dirs.append(otp)
    return os.pathsep.join(d for d in dirs if os.path.isdir(d))


def with_elixir(path):
    return os.pathsep.join(x for x in (elixir_path(), path) if x)


def sql(a, query):
    env = dict(os.environ, PGPASSWORD=a.pgpass)
    r = subprocess.run([PSQL, "-U", a.pguser, "-h", a.pghost, "-d", a.db, "-X", "-A", "-t", "-c", query],
                       capture_output=True, text=True, env=env)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def utc_now(a):
    return sql(a, "select now() at time zone 'utc'")


def listener_pid(port):
    out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True).stdout
    for row in out.splitlines():
        p = row.split()
        if len(p) >= 5 and p[1].endswith(":%d" % port) and p[3] == "LISTENING":
            return int(p[4])


def start_server(a):
    os.makedirs(WORK, exist_ok=True)
    keyfile = os.path.join(WORK, "key-%s.txt" % uuid.uuid4().hex[:8])
    env = dict(os.environ, CONF_DB=a.db, CONF_PORT=str(a.port), CONF_KEY_FILE=keyfile,
               MIX_BUILD_PATH=a.build_path or os.path.join(WORK, "build"))
    if a.deps_path:
        env["MIX_DEPS_PATH"] = a.deps_path
    env["PATH"] = with_elixir(env["PATH"])
    mix = shutil.which("mix", path=env["PATH"])
    if not mix:
        sys.exit("mix not found")
    log = open(os.path.join(WORK, "server.log"), "w")
    proc = subprocess.Popen([mix, "run", "--no-start", os.path.join(HERE, "server.exs")],
                            cwd=a.server_dir, env=env, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=os.name != "nt")
    for _ in range(600):
        if proc.poll() is not None:
            sys.exit("server exited; see %s" % log.name)
        if os.path.exists(keyfile) and os.path.getsize(keyfile):
            time.sleep(0.5)
            return proc, open(keyfile).read().strip()
        time.sleep(1)
    sys.exit("server did not start; see %s" % log.name)


def stop_server(a, proc):
    if os.name != "nt":
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        return
    pids = {proc.pid}
    pid = listener_pid(a.port)
    if pid:
        pids.add(pid)
    for p in pids:
        subprocess.run(["taskkill", "/PID", str(p), "/T", "/F"], capture_output=True)


def runners(a, tmp):
    p = lambda *x: os.path.join(PROGRAMS, *x)
    r = {}
    py = sys.executable
    r["python"] = (py, lambda t: ([py, "main.py", t], p("python"), {}))
    node = tool("node")
    r["javascript"] = (node, lambda t: ([node, "main.mjs", t], p("javascript"), {}))
    go = tool("go", extra=[r"C:\Program Files\Go\bin\go.exe"])
    r["go"] = (go, lambda t: ([go, "run", ".", t], p("go"), {}))
    cargo = tool("cargo")
    r["rust"] = (cargo, lambda t: ([cargo, "run", "-q", "--", t], p("rust"), {"CARGO_TARGET_DIR": os.path.join(tmp, "rust")}))
    dn = tool("dotnet")
    r["dotnet"] = (dn, lambda t: ([dn, "run", "--project", "Conformance.csproj", "--artifacts-path", os.path.join(tmp, "dotnet"), "--", t], p("dotnet"), {}))
    javac, java = tool("javac"), tool("java")
    r["java"] = (javac and java, lambda t: ([java, "-cp", os.path.join(tmp, "java"), "Conformance", t], p("java"), {}))
    php = tool("php")
    r["php"] = (php, lambda t: ([php, "main.php", t], p("php"), {}))
    ps = tool("pwsh", "powershell")
    r["powershell"] = (ps, lambda t: ([ps, "-NoProfile", "-File", "main.ps1", "-Tag", t], p("powershell"), {}))
    sh = tool("bash", extra=[r"C:\Program Files\Git\bin\bash.exe"])
    r["shell"] = (sh and tool("curl") and sh, lambda t: ([sh, "main.sh", t], p("shell"), {}))
    ex = tool("elixir", extra=[r"C:\Program Files\Elixir\bin\elixir.bat"])
    r["elixir"] = (ex, lambda t: ([ex, "main.exs", t], p("elixir"), {"PATH": with_elixir(os.environ["PATH"])}))
    return r


def prepare_java(tmp):
    out = os.path.join(tmp, "java")
    os.makedirs(out, exist_ok=True)
    src = os.path.join(HERE, "..", "java", "src", "main", "java", "dev", "dokkit", "Dokkit.java")
    r = subprocess.run([tool("javac"), "-d", out, src, os.path.join(PROGRAMS, "java", "Conformance.java")], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def execute(a, spec, tag, dev):
    argv, cwd, extra = spec(tag)
    env = dict(os.environ, DOKKIT_URL=a.url, DOKKIT_KEY=a.key, **extra)
    env.pop("DOKKIT_ENV", None)
    if dev:
        env["DOKKIT_ENV"] = "dev"
    r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=a.timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


def verify(a, lang, tag, since, slug, dev_run):
    res = {}
    svc = "(select id from services where slug = '%s')" % slug
    other = "(select id from services where slug = '%s')" % a.app
    q = lambda s: sql(a, s)
    exists = lambda s: q("select exists(%s)" % s) == "t"
    res["version"] = exists("select 1 from installs where service_id = %s and version = '9.9.9' and seen_at >= '%s'" % (svc, since))
    res["beat"] = exists("select 1 from checks where service_id = %s and name like 'conf-beat%%' and updated_at >= '%s'" % (svc, since))
    res["job"] = exists("select 1 from job_runs j join checks c on c.id = j.check_id where c.service_id = %s and c.name like 'conf-job%%' and j.result = 'ok' and j.updated_at >= '%s'" % (svc, since))
    res["check"] = exists("select 1 from checks where service_id = %s and name = 'conf-check' and state = 'ok' and updated_at >= '%s'" % (svc, since))
    res["metric"] = exists("select 1 from metrics where service_id = %s and name = 'conf.metric' and at >= '%s'" % (svc, since))
    res["log"] = exists("select 1 from logs where service_id = %s and msg = 'conformance %s'" % (svc, tag))
    if lang in FIELDS:
        res["fields"] = exists("select 1 from logs where service_id = %s and msg = 'conformance %s' and fields->>'tag' = '%s' and fields->>'n' = '1'" % (svc, tag, tag))
    res["error"] = exists("select 1 from error_events e join error_groups g on g.id = e.group_id where g.service_id = %s and g.type like '%%ConformanceError' and e.at >= '%s'" % (svc, since))
    if dev_run:
        res["isolation"] = not any([
            exists("select 1 from logs where service_id = %s and msg = 'conformance %s'" % (other, tag)),
            exists("select 1 from checks where service_id = %s and updated_at >= '%s'" % (other, since)),
            exists("select 1 from metrics where service_id = %s and at >= '%s'" % (other, since)),
            exists("select 1 from error_events e join error_groups g on g.id = e.group_id where g.service_id = %s and e.at >= '%s'" % (other, since)),
        ])
    return res


def check_run(a, lang, spec, dev):
    tag = "%s-%s-%s" % (lang, "dev" if dev else "prod", uuid.uuid4().hex[:6])
    since = utc_now(a)
    code, out = execute(a, spec, tag, dev)
    if code:
        return None, "program exited %d: %s" % (code, out[-600:])
    slug = a.app + "~dev" if dev else a.app
    res = {}
    for _ in range(20):
        res = verify(a, lang, tag, since, slug, dev)
        if all(v is True for v in res.values()):
            break
        time.sleep(1)
    return res, ""


def main():
    ap = argparse.ArgumentParser(description="Runs each library's smallest program against a real Dokkit server and checks what it stored.")
    ap.add_argument("--server-dir", default=os.path.join(HERE, "..", "..", "server"))
    ap.add_argument("--port", type=int, default=4491)
    ap.add_argument("--only", default="")
    ap.add_argument("--no-server", action="store_true", help="use an already running server: needs --url and --key")
    ap.add_argument("--url")
    ap.add_argument("--key")
    ap.add_argument("--app", default="conformance", help="slug of the app the key belongs to")
    ap.add_argument("--db", default="dokkit_conformance")
    ap.add_argument("--pghost", default="localhost")
    ap.add_argument("--pguser", default="postgres")
    ap.add_argument("--pgpass", default="postgres")
    ap.add_argument("--build-path")
    ap.add_argument("--deps-path")
    ap.add_argument("--timeout", type=int, default=600)
    a = ap.parse_args()
    a.server_dir = os.path.abspath(a.server_dir)
    if a.no_server and not (a.url and a.key):
        sys.exit("--no-server needs --url and --key")
    only = [x for x in a.only.split(",") if x] or LANGS
    tmp = os.path.join(WORK, "programs")
    os.makedirs(tmp, exist_ok=True)

    proc = None
    if not a.no_server:
        proc, a.key = start_server(a)
        a.url = "http://127.0.0.1:%d" % a.port
    table, skipped, failures = {}, [], []
    try:
        avail = runners(a, tmp)
        for lang in only:
            if lang not in avail:
                skipped.append((lang, "unknown language"))
                continue
            exe, spec = avail[lang]
            if not exe:
                skipped.append((lang, "toolchain missing"))
                continue
            if lang == "java":
                code, out = prepare_java(tmp)
                if code:
                    failures.append((lang, "compile", out[-600:]))
                    table[lang] = {"prod": None, "dev": None}
                    continue
            table[lang] = {}
            for dev in (False, True):
                res, err = check_run(a, lang, spec, dev)
                table[lang]["dev" if dev else "prod"] = res
                if res is None:
                    failures.append((lang, "dev" if dev else "prod", err))
                else:
                    for k, v in res.items():
                        if v is not True:
                            failures.append((lang, ("dev " if dev else "prod ") + k, "not found"))
    finally:
        if proc:
            stop_server(a, proc)

    print("%-11s %-5s " % ("lang", "env") + " ".join("%-9s" % k for k in KINDS))
    for lang in only:
        if lang not in table:
            print("%-11s skipped (%s)" % (lang, dict(skipped).get(lang)))
            continue
        for env in ("prod", "dev"):
            res = table[lang][env]
            cells = []
            for k in KINDS:
                if res is None:
                    cells.append("FAIL")
                elif k not in res:
                    cells.append("skip")
                else:
                    cells.append("pass" if res[k] is True else "FAIL")
            print("%-11s %-5s " % (lang, env) + " ".join("%-9s" % c for c in cells))
    for lang, why in skipped:
        print("skipped %s: %s" % (lang, why))
    for lang, what, why in failures:
        print("FAIL %s %s: %s" % (lang, what, why))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
