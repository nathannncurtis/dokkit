import gzip
import http.server
import json
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import dokkit

got = []


class Server(http.server.BaseHTTPRequestHandler):
    got = got
    status = {}
    hold = None

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        if self.hold:
            self.hold.wait(30)
        code = self.status.get(self.path, 200)
        if code == 200:
            for line in body.decode().split("\n"):
                self.got.append((self.path, self.headers["Authorization"], json.loads(line)))
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


class Test(unittest.TestCase):
    def test_everything_is_off_until_started_then_sends(self):
        dokkit.beat("worker")
        dokkit.capture(ValueError("nothing happens"))
        self.assertIsNone(dokkit._state)

        server = http.server.HTTPServer(("127.0.0.1", 0), Server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        dokkit.start(version="2.3.0", url="http://127.0.0.1:%d" % server.server_port, key="dka_test")

        dokkit.beat("worker", every_seconds=30)
        dokkit.check("queue-age", "degraded", value=14, note="oldest item is 14 minutes old")
        log = logging.getLogger("app")
        log.addHandler(dokkit.handler())
        log.error("Upload failed")
        with self.assertRaises(KeyError):
            with dokkit.job("nightly-purge") as run:
                run.progress(4000, 9000)
                raise KeyError("patient 4411")
        dokkit.flush()
        server.shutdown()
        server.server_close()

        self.assertTrue(all(auth == "Bearer dka_test" for _, auth, _ in got))
        lines = [l for path, _, l in got if path == "/api/v1/report"]
        self.assertEqual(
            [l["type"] for l in lines], ["deploy", "beat", "custom", "log", "job", "job", "job"]
        )
        self.assertEqual(lines[1]["every_seconds"], 30)
        self.assertEqual([l["event"] for l in lines[4:]], ["start", "progress", "fail"])
        self.assertEqual(lines[4]["run"], lines[6]["run"])
        [error] = [l for path, _, l in got if path == "/api/v1/errors"]
        self.assertEqual(error["type"], "KeyError")
        self.assertFalse(error["handled"])
        self.assertTrue(error["frames"][-1]["own"])
        self.assertNotIn("4411", json.dumps(got))


class Library(unittest.TestCase):
    def setUp(self):
        self.old = dokkit._state
        dokkit._state = dokkit._State("http://127.0.0.1:9", "k", None, None)

    def tearDown(self):
        dokkit._state = self.old

    def test_a_value_json_cannot_write_is_sent_as_its_repr(self):
        circular = {}
        circular["self"] = circular
        dokkit.log("info", "a", {"loop": circular, (1, 2): "tuple key", "nan": float("nan"), "n": 3})
        [line] = [json.loads(l) for l in dokkit._state.lines]
        self.assertEqual(line["msg"], "a")
        self.assertEqual(line["fields"]["n"], 3)
        self.assertEqual(line["fields"]["(1, 2)"], "tuple key")
        self.assertEqual(line["fields"]["nan"], "nan")
        self.assertIn("...", json.dumps(line["fields"]["loop"]))
        self.assertEqual(dokkit.dropped(), 0)

    def test_a_line_that_cannot_be_written_at_all_is_dropped_alone_and_counted(self):
        class Bad:
            def __repr__(self):
                raise ValueError("no")

            __str__ = __repr__

        dokkit.beat("a")
        dokkit.stats({"x": Bad()})
        dokkit.beat("b")
        self.assertEqual(len(dokkit._state.lines), 2)
        self.assertEqual(dokkit.dropped(), 1)

    def test_the_handler_sends_what_was_passed_as_extra(self):
        log = logging.getLogger("fields")
        log.propagate = False
        log.addHandler(dokkit.handler())
        log.warning("Upload failed", extra={"order": 4411, "path": os})
        line = json.loads(dokkit._state.lines[-1])
        self.assertEqual(line["fields"]["logger"], "fields")
        self.assertEqual(line["fields"]["order"], 4411)
        self.assertEqual(line["fields"]["path"], str(os))
        self.assertNotIn("levelname", line["fields"])

    def test_the_apps_folder_is_the_programs_not_the_working_directory(self):
        with tempfile.TemporaryDirectory() as app, tempfile.TemporaryDirectory() as elsewhere:
            app, before = os.path.realpath(app), os.getcwd()
            os.chdir(elsewhere)
            try:
                with mock.patch.object(sys.modules["__main__"], "__file__", os.path.join(app, "main.py"), create=True):
                    self.assertEqual(dokkit._root(), app)
                with mock.patch.object(sys, "frozen", True, create=True), mock.patch.object(sys, "executable", os.path.join(app, "app.exe")):
                    self.assertEqual(dokkit._root(), app)
                    dokkit._state.root = dokkit._root()
                    self.assertTrue(dokkit._own(os.path.join(app, "_internal", "app", "main.py")))
                    self.assertFalse(dokkit._own(os.path.join(elsewhere, "main.py")))
                runner = os.path.join(sys.base_prefix, "Lib", "unittest", "__main__.py")
                with mock.patch.object(sys.modules["__main__"], "__file__", runner, create=True):
                    self.assertEqual(os.path.realpath(dokkit._root()), os.path.realpath(elsewhere))
                self.assertEqual(dokkit._State("http://127.0.0.1:9", "k", None, None, root=app).root, app)
            finally:
                os.chdir(before)

    def test_log_sends_a_line(self):
        dokkit.log("warn", "slow query")
        self.assertIn('"level":"warn"', dokkit._state.lines[-1].replace(" ", ""))

    def test_log_never_raises_when_str_of_the_message_does(self):
        class Bad:
            def __str__(self):
                raise ValueError("no")

        dokkit.log("info", Bad())
        self.assertEqual(len(dokkit._state.lines), 0)

    def test_nothing_logged_while_sending_is_queued(self):
        dokkit._sending.on = True
        try:
            dokkit.log("debug", "from the sender")
            dokkit.handler().emit(logging.LogRecord("urllib", logging.ERROR, "f", 1, "x", (), None))
        finally:
            dokkit._sending.on = False
        self.assertEqual(len(dokkit._state.lines), 0)

    def test_a_bad_format_string_does_not_raise_into_the_app(self):
        record = logging.LogRecord("app", logging.ERROR, "f", 1, "%d items", ("x",), None)
        dokkit.handler().emit(record)

    def test_own_frames_need_a_path_separator(self):
        root = dokkit._state.root
        self.assertTrue(dokkit._own(root + os.sep + "app.py"))
        self.assertFalse(dokkit._own(root + "-other" + os.sep + "app.py"))
        self.assertEqual(dokkit._path(os.path.join(os.sep, "home", "bob", "x", "site-packages", "lib", "m.py")), "lib/m.py")
        self.assertEqual(dokkit._path(os.path.join(os.sep, "home", "bob", "stdlib.py")), "stdlib.py")

    def test_a_non_local_http_address_keeps_it_off(self):
        self.assertTrue(dokkit._insecure("http://example.com"))
        self.assertFalse(dokkit._insecure("https://example.com"))
        self.assertFalse(dokkit._insecure("http://localhost:4000"))
        self.assertFalse(dokkit._insecure("http://127.0.0.1:4000"))

    def test_the_queue_is_bounded_by_bytes_and_a_failed_batch_is_retried_once(self):
        state = dokkit._state
        for _ in range(3):
            dokkit.stats({"x": "y" * 2_000_000})
        self.assertEqual(len(state.lines), 1)
        self.assertEqual(state.dropped, 2)
        state.flush()
        self.assertEqual(state.retry[2], 1)
        state.flush()
        self.assertIsNone(state.retry)
        self.assertEqual(state.dropped, 3)

    def test_dropped_is_counted_under_the_lock_and_can_be_read(self):
        state = dokkit._state
        threads = [threading.Thread(target=lambda: [state._count(1) for _ in range(2000)]) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(dokkit.dropped(), 16000)

    @unittest.skipUnless(hasattr(os, "fork"), "needs fork")
    def test_the_sender_thread_is_back_after_a_fork(self):
        dokkit._state.add({"type": "beat"})
        dokkit._state.lines.append("x")
        pid = os.fork()
        if pid == 0:
            os._exit(0 if any(t.name == "dokkit" for t in threading.enumerate()) and not dokkit._state.lines else 1)
        self.assertEqual(os.waitpid(pid, 0)[1], 0)


class Sending(unittest.TestCase):
    def setUp(self):
        self.fake = type("Fake", (Server,), {"got": [], "status": {}})
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.fake)
        self.server.daemon_threads = True
        self.server.handle_error = lambda *args: None
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_port
        self.old = dokkit._state
        dokkit._state = dokkit._State(self.url, "k", None, None)

    def tearDown(self):
        if self.fake.hold:
            self.fake.hold.set()
        dokkit._state = self.old
        self.server.shutdown()
        self.server.server_close()

    def paths(self):
        return [path for path, _, _ in self.fake.got]

    def test_an_error_report_that_fails_is_kept_and_the_lines_still_go(self):
        self.fake.status["/api/v1/errors"] = 503
        dokkit.capture(ValueError("x"))
        dokkit.beat("worker")
        dokkit.flush()
        self.assertEqual(self.paths(), ["/api/v1/report"])
        self.assertEqual(len(dokkit._state.errors), 1)
        self.assertEqual(dokkit.dropped(), 0)
        self.fake.status.clear()
        dokkit.flush()
        self.assertEqual(self.paths(), ["/api/v1/report", "/api/v1/errors"])
        self.assertEqual(len(dokkit._state.errors), 0)

    def test_lines_that_fail_do_not_stop_the_error_reports(self):
        self.fake.status["/api/v1/report"] = 503
        dokkit.beat("worker")
        dokkit.capture(ValueError("x"))
        dokkit.flush()
        self.assertEqual(self.paths(), ["/api/v1/errors"])

    def test_an_error_report_the_server_refuses_is_dropped_and_counted(self):
        self.fake.status["/api/v1/errors"] = 400
        dokkit.capture(ValueError("x"))
        dokkit.flush()
        self.assertEqual(len(dokkit._state.errors), 0)
        self.assertEqual(dokkit.dropped(), 1)

    def test_kept_error_reports_are_bounded_to_the_newest_hundred(self):
        self.fake.status["/api/v1/errors"] = 503
        for n in range(130):
            dokkit.capture(ValueError("x"), tags={"n": n})
        dokkit.flush()
        self.assertEqual(len(dokkit._state.errors), 100)
        self.assertEqual(json.loads(dokkit._state.errors[-1])["tags"]["n"], "129")
        self.assertEqual(dokkit.dropped(), 30)

    def test_lines_are_sent_before_error_reports(self):
        dokkit.log("error", "the line before the crash")
        dokkit.capture(ValueError("x"))
        dokkit.flush()
        self.assertEqual(self.paths(), ["/api/v1/report", "/api/v1/errors"])

    def test_flush_gives_up_after_its_time_limit(self):
        self.fake.hold = threading.Event()
        dokkit.beat("worker")
        began = time.monotonic()
        dokkit.flush(timeout=0.3)
        self.assertLess(time.monotonic() - began, 2)
        with mock.patch.object(dokkit, "FLUSH_SECONDS", 0.3):
            began = time.monotonic()
            dokkit.flush()
            self.assertLess(time.monotonic() - began, 2)
        self.assertEqual(self.paths(), [])

    def run_app(self, *lines):
        with tempfile.TemporaryDirectory() as app, tempfile.TemporaryDirectory() as elsewhere:
            script = os.path.join(app, "main.py")
            with open(script, "w") as f:
                f.write("\n".join(("import sys, dokkit", "dokkit.start(url=sys.argv[1], key='k')") + lines))
            env = dict(os.environ, PYTHONPATH=os.path.dirname(os.path.abspath(dokkit.__file__)))
            began = time.monotonic()
            subprocess.run([sys.executable, script, self.url], cwd=elsewhere, env=env, check=True, timeout=60)
            return time.monotonic() - began

    def test_at_exit_what_waits_is_sent_and_a_script_started_from_elsewhere_owns_its_frames(self):
        self.run_app("dokkit.log('info', 'last line')", "try:", "    1 / 0", "except Exception:", "    dokkit.capture()")
        self.assertEqual(self.paths(), ["/api/v1/report", "/api/v1/errors"])
        frame = self.fake.got[-1][2]["frames"][-1]
        self.assertEqual((frame["file"], frame["own"]), ("main.py", True))

    def test_a_server_that_does_not_answer_holds_the_exit_only_for_the_time_limit(self):
        self.fake.hold = threading.Event()
        self.assertLess(self.run_app("dokkit.FLUSH_SECONDS = 0.5", "dokkit.beat('worker')"), 6)

    def test_a_blank_address_or_key_is_off_and_only_none_reads_the_environment(self):
        dokkit._state = None
        with mock.patch.dict(os.environ, {"DOKKIT_URL": self.url, "DOKKIT_KEY": "dka_env"}):
            dokkit.start(url="", key="")
            self.assertIsNone(dokkit._state)
            dokkit.start(url=self.url, key="")
            self.assertIsNone(dokkit._state)
            dokkit.start(url="", key="dka_given")
            self.assertIsNone(dokkit._state)
            dokkit.start(root=os.sep + "app")
            self.assertEqual((dokkit._state.url, dokkit._state.key), (self.url, "dka_env"))
            self.assertEqual(dokkit._state.root, os.path.abspath(os.sep + "app"))


if __name__ == "__main__":
    unittest.main()
