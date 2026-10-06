"""The Dokkit client library for Python. One file, standard library only.

    import dokkit
    dokkit.start(version="2.3.0")      # reads DOKKIT_URL and DOKKIT_KEY; blank means off

    dokkit.beat("worker")              # from the main loop
    with dokkit.job("nightly-purge") as run:
        run.progress(4000, 9000)
    dokkit.check("queue-age", "degraded", value=14, note="oldest item is 14 minutes old")
    dokkit.capture()                   # inside an except block
    logging.getLogger().addHandler(dokkit.handler())

Nothing here raises into the app or waits on the network. Lines wait in a queue of fixed
size and a background thread sends them. Error message text is never sent.
"""
import atexit
import collections
import datetime
import gzip
import json
import logging
import os
import socket
import sys
import threading
import traceback
import urllib.request
import uuid

QUEUE = 1000
_state = None


class _State:
    def __init__(self, url, key, version, environment):
        self.url, self.key = url.rstrip("/"), key
        self.version, self.environment = version, environment
        self.host = socket.gethostname()
        self.lines = collections.deque(maxlen=QUEUE)
        self.errors = collections.deque(maxlen=100)
        self.dropped = 0
        self.wake = threading.Event()
        # The folder the app was started from: frames under it are the app's own.
        self.root = os.path.abspath(os.getcwd())
        threading.Thread(target=self._run, name="dokkit", daemon=True).start()

    def add(self, line):
        if len(self.lines) == self.lines.maxlen:
            self.dropped += 1
        line.setdefault("at", _now())
        line["host"] = self.host
        self.lines.append(line)

    def _run(self):
        while True:
            self.wake.wait(2)
            self.wake.clear()
            self.flush()

    def flush(self):
        try:
            while self.errors:
                self._post("/api/v1/errors", json.dumps(self.errors.popleft()).encode(), "application/json")
            batch = []
            while self.lines and len(batch) < 500:
                batch.append(self.lines.popleft())
            if batch:
                body = gzip.compress("\n".join(json.dumps(l, default=str) for l in batch).encode())
                self._post("/api/v1/report", body, "application/x-ndjson", {"Content-Encoding": "gzip", "Dokkit-Batch": str(uuid.uuid4())})
        except Exception:
            # What could not be sent is dropped. The app is never told.
            pass

    def _post(self, path, body, kind, headers=None):
        request = urllib.request.Request(self.url + path, data=body, method="POST")
        request.add_header("Authorization", "Bearer " + self.key)
        request.add_header("Content-Type", kind)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        urllib.request.urlopen(request, timeout=10).close()


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def start(version=None, environment=None, url=None, key=None):
    """Turns the library on. With no address or key it stays off and every call does nothing."""
    global _state
    url = url or os.environ.get("DOKKIT_URL", "")
    key = key or os.environ.get("DOKKIT_KEY", "")
    if not url or not key or _state:
        return
    try:
        _state = _State(url, key, version, environment or os.environ.get("DOKKIT_ENV"))
        atexit.register(flush)
        if version:
            _state.add({"type": "deploy", "version": str(version)})
    except Exception:
        _state = None


def flush():
    """Sends what is waiting. Called for you when the app exits."""
    if _state:
        _state.flush()


def _add(line):
    try:
        if _state:
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
                "file": os.path.relpath(f.filename, _state.root) if _own(f.filename) else f.filename,
                "function": f.name,
                "line": f.lineno,
                "own": _own(f.filename),
            }
            for f in traceback.extract_tb(error.__traceback__)
        ]
        _state.errors.append(
            {
                "at": _now(),
                "type": type(error).__name__,
                "handled": handled,
                "release": _state.version,
                "environment": _state.environment,
                "host": _state.host,
                "frames": frames,
                "tags": {str(k): str(v) for k, v in (tags or {}).items()},
            }
        )
        _state.wake.set()
    except Exception:
        pass


def _own(filename):
    path = os.path.abspath(filename)
    return path.startswith(_state.root) and "site-packages" not in path


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

    def emit(self, record):
        level = self.LEVELS.get(record.levelno // 10 * 10, "info")
        _add({"type": "log", "t": _now(), "level": level, "msg": record.getMessage(), "fields": {"logger": record.name}})


def handler(level=logging.INFO):
    """A handler for the logging module. Its lines go to the Logs page."""
    h = _Handler()
    h.setLevel(level)
    return h
