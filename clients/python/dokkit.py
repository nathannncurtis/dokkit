"""The Dokkit client library for Python. One file, standard library only.

    import dokkit
    dokkit.start(version="2.3.0")      # reads DOKKIT_URL and DOKKIT_KEY; blank means off
    dokkit.start(version="2.3.0", url=URL, key=KEY)   # given, even blank, the environment is not read

    dokkit.beat("worker")              # from the main loop
    with dokkit.job("nightly-purge") as run:
        run.progress(4000, 9000)
    dokkit.check("queue-age", "degraded", value=14, note="oldest item is 14 minutes old")
    dokkit.capture()                   # inside an except block
    logging.getLogger().addHandler(dokkit.handler())

Nothing here raises into the app or waits on the network. Lines wait in a queue of fixed
size and a background thread sends them. An error report carries the error's type and
stack, never its message. A log line carries the text and fields the app logs.
"""
import atexit
import collections
import datetime
import gzip
import json
import logging
import math
import os
import re
import socket
import sys
import threading
import traceback
import urllib.parse
import urllib.request
import uuid

QUEUE = 1000
MAX_BYTES = 4_000_000
FLUSH_SECONDS = 5
_state = None
_sending = threading.local()


class _State:
    def __init__(self, url, key, version, environment, root=None):
        self.url, self.key = url.rstrip("/"), key
        self.version, self.environment = version, environment
        self.host = socket.gethostname()
        self.lines = collections.deque()
        self.size = 0
        self.errors = collections.deque(maxlen=100)
        self.dropped = 0
        self.retry = None
        self.root = os.path.abspath(root or _root())
        self.restart()

    def restart(self, forked=False):
        """Also runs in a forked child, where the sender thread and any held lock are gone."""
        if forked:
            # The parent still owns what was queued at the fork.
            self.lines.clear()
            self.errors.clear()
            self.retry = None
            self.size = 0
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.waiting = []
        threading.Thread(target=self._run, name="dokkit", daemon=True).start()

    def add(self, line):
        line.setdefault("at", _now())
        line["host"] = self.host
        try:
            try:
                text = json.dumps(line, default=str, allow_nan=False)
            except Exception:
                text = json.dumps(_safe(line))
        except Exception:
            return self._count(1)
        if len(text) > MAX_BYTES:
            return self._count(1)
        with self.lock:
            while self.lines and (len(self.lines) >= QUEUE or self.size + len(text) > MAX_BYTES):
                self.size -= len(self.lines.popleft())
                self.dropped += 1
            self.lines.append(text)
            self.size += len(text)

    def _count(self, dropped):
        with self.lock:
            self.dropped += dropped

    def _run(self):
        while True:
            self.wake.wait(2)
            self.wake.clear()
            with self.lock:
                waiting, self.waiting = self.waiting, []
            self._flush()
            for done in waiting:
                done.set()

    def flush(self, timeout=None):
        """Has the sender thread make a pass now and waits for it, at most timeout seconds."""
        done = threading.Event()
        with self.lock:
            self.waiting.append(done)
        self.wake.set()
        done.wait(FLUSH_SECONDS if timeout is None else timeout)

    def _flush(self):
        # Lines go first: all of them fit in a few requests, and an error report is one request each.
        for send in (self._lines, self._errors):
            try:
                send()
            except Exception:
                pass

    def _lines(self):
        while self.retry or self.lines:
            if not self.retry:
                with self.lock:
                    batch = [self.lines.popleft() for _ in range(min(500, len(self.lines)))]
                    self.size -= sum(len(l) for l in batch)
                self.retry = [str(uuid.uuid4()), batch, 0]
            batch_id, batch, tries = self.retry
            try:
                body = gzip.compress("\n".join(batch).encode())
                self._post("/api/v1/report", body, "application/x-ndjson", {"Content-Encoding": "gzip", "Dokkit-Batch": batch_id})
                self.retry = None
            except Exception:
                # A failed batch gets one more try; after that it is dropped and counted.
                if tries:
                    self._count(len(batch))
                    self.retry = None
                else:
                    self.retry[2] = 1
                return

    def _errors(self):
        while self.errors:
            report = self.errors[0]
            try:
                self._post("/api/v1/errors", report, "application/json")
            except Exception as error:
                # A report the server refuses is dropped; one it did not answer for waits for the next pass.
                if not 400 <= getattr(error, "code", 0) < 500:
                    return
                self._count(1)
            with self.lock:
                if self.errors and self.errors[0] is report:
                    self.errors.popleft()

    def _post(self, path, body, kind, headers=None):
        request = urllib.request.Request(self.url + path, data=body, method="POST")
        request.add_header("Authorization", "Bearer " + self.key)
        request.add_header("Content-Type", kind)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        _sending.on = True
        try:
            urllib.request.urlopen(request, timeout=10).close()
        finally:
            _sending.on = False


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def start(version=None, environment=None, url=None, key=None, root=None):
    """Turns the library on. With no address or key it stays off and every call does nothing.

    url and key left out are read from DOKKIT_URL and DOKKIT_KEY. Given, even blank, they are
    used as they are. root is the folder of the app's own code, when that is not the program's.
    """
    global _state
    url = os.environ.get("DOKKIT_URL", "") if url is None else url
    key = os.environ.get("DOKKIT_KEY", "") if key is None else key
    if not url or not key or _state:
        return
    if _insecure(url):
        print("dokkit: http:// address to a non-local host; set DOKKIT_INSECURE=1 to allow it. Staying off.", file=sys.stderr)
        return
    try:
        _state = _State(url, key, version, environment or os.environ.get("DOKKIT_ENV"), root)
        atexit.register(flush)
        if version:
            _state.add({"type": "deploy", "version": str(version)})
    except Exception:
        _state = None


def _insecure(url):
    u = urllib.parse.urlparse(url)
    local = re.fullmatch(r"localhost|127(\.\d+){3}|::1", u.hostname or "")
    return u.scheme == "http" and not local and os.environ.get("DOKKIT_INSECURE") != "1"


def _after_fork():
    if _state:
        _state.restart(forked=True)


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_after_fork)


def flush(timeout=None):
    """Sends what is waiting and returns after at most timeout seconds, FLUSH_SECONDS when not given.

    Called for you when the app exits.
    """
    if _state:
        _state.flush(timeout)


def dropped():
    """How many lines and error reports were dropped: the queue was full, or they could not be sent."""
    return _state.dropped if _state else 0


def _safe(value, depth=0):
    """The value as json can write it: what it cannot write is sent as its repr."""
    if isinstance(value, dict) and depth < 4:
        return {str(k): _safe(v, depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple)) and depth < 4:
        return [_safe(v, depth + 1) for v in value]
    if value is None or isinstance(value, (str, int)) or (isinstance(value, float) and math.isfinite(value)):
        return value
    return repr(value)


def _add(line):
    try:
        # Nothing logged while this thread is sending is fed back in.
        if _state and not getattr(_sending, "on", False):
            _state.add(line)
    except Exception:
        pass


def beat(name, every_seconds=60):
    _add({"type": "beat", "name": name, "every_seconds": every_seconds})


def check(name, state, value=None, note=None):
    """state is "ok", "degraded" or "down"."""
    line = {"type": "custom", "check": name, "state": state}
    if value is not None:
        line["value"] = value
    if note:
        line["note"] = note
    _add(line)


def metric(name, value, unit=None):
    _add({"type": "metric", "name": name, "value": value, "unit": unit})


def log(level, msg, fields=None):
    """level is trace, debug, info, warn, error or fatal."""
    try:
        if _state:
            _add({"type": "log", "t": _now(), "level": level, "msg": str(msg), "fields": fields})
    except Exception:
        pass


def stats(document):
    """Sends a stats document, for an app dokkit cannot reach."""
    _add({"type": "stats", "document": document})


class job:
    """Reports a run of a job: its start, its progress, and how it ended."""

    def __init__(self, name):
        self.name, self.run = name, str(uuid.uuid4())

    def _send(self, event, **more):
        _add({"type": "job", "name": self.name, "run": self.run, "event": event, **more})

    def __enter__(self):
        self.started = datetime.datetime.now()
        self._send("start")
        return self

    def progress(self, done, total=None):
        self._send("progress", done=done, total=total)

    def __exit__(self, kind, error, trace):
        took = int((datetime.datetime.now() - self.started).total_seconds() * 1000)
        if kind is None:
            self._send("ok", exit_code=0, duration_ms=took)
        else:
            self._send("fail", exit_code=1, duration_ms=took, tail=kind.__name__)
            capture(error, handled=False)
        if _state:
            _state.wake.set()
        return False


def capture(error=None, handled=True, tags=None):
    """Sends an error: its type and stack, never its message. With no argument, the one being handled."""
    try:
        if not _state:
            return
        error = error or sys.exc_info()[1]
        if error is None:
            return
        frames = [
            {
                "file": _path(f.filename),
                "function": f.name,
                "line": f.lineno,
                "own": _own(f.filename),
            }
            for f in traceback.extract_tb(error.__traceback__)
        ]
        report = json.dumps(
            {
                "at": _now(),
                "type": type(error).__name__,
                "handled": handled,
                "release": _state.version,
                "environment": _state.environment,
                "host": _state.host,
                "frames": frames,
                "tags": {str(k): str(v) for k, v in (tags or {}).items()},
            },
            default=str,
        ).encode()
        with _state.lock:
            # The queue holds the newest hundred.
            _state.dropped += len(_state.errors) == _state.errors.maxlen
            _state.errors.append(report)
        _state.wake.set()
    except Exception:
        pass


def _root():
    """The program's folder: the executable's when frozen, else the main script's."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    main = getattr(sys.modules.get("__main__"), "__file__", None)
    # A runner inside the Python install (python -m unittest, gunicorn) is not the app; there the working directory is.
    if main and not any(_under(main, prefix) for prefix in (sys.prefix, sys.base_prefix)):
        return os.path.dirname(os.path.abspath(main))
    return os.getcwd()


def _under(filename, folder):
    path, folder = (os.path.normcase(os.path.abspath(p)) for p in (filename, folder))
    return path.startswith(folder.rstrip(os.sep) + os.sep)


def _own(filename):
    return _under(filename, _state.root) and "site-packages" not in os.path.abspath(filename)


def _path(filename):
    """Relative to the app's folder; other files keep only what follows site-packages, or their name."""
    if _own(filename):
        return os.path.relpath(filename, _state.root)
    path = os.path.abspath(filename).replace(os.sep, "/")
    return path.split("/site-packages/", 1)[1] if "/site-packages/" in path else os.path.basename(path)


def catch_unhandled():
    """Also reports errors nothing caught, then lets Python handle them as before."""
    before = sys.excepthook

    def hook(kind, error, trace):
        capture(error, handled=False)
        flush()
        before(kind, error, trace)

    sys.excepthook = hook


class _Handler(logging.Handler):
    LEVELS = {10: "debug", 20: "info", 30: "warn", 40: "error", 50: "fatal"}
    STANDARD = set(vars(logging.makeLogRecord({}))) | {"message", "asctime"}

    def emit(self, record):
        try:
            level = self.LEVELS.get(record.levelno // 10 * 10, "info")
            fields = {k: v for k, v in vars(record).items() if k not in self.STANDARD}
            fields["logger"] = record.name
            _add({"type": "log", "t": _now(), "level": level, "msg": record.getMessage(), "fields": fields})
        except Exception:
            pass


def handler(level=logging.INFO):
    """A handler for the logging module. Its lines go to the Logs page, with what was passed as extra= as their fields."""
    h = _Handler()
    h.setLevel(level)
    return h
