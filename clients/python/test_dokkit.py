import gzip
import http.server
import json
import logging
import os
import threading
import unittest

import dokkit

got = []


class Server(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        for line in body.decode().split("\n"):
            got.append((self.path, self.headers["Authorization"], json.loads(line)))
        self.send_response(200)
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

    def test_a_line_that_cannot_be_serialized_is_dropped_alone(self):
        dokkit.beat("a")
        circular = {}
        circular["self"] = circular
        dokkit.stats(circular)
        dokkit.stats({(1, 2): "tuple key"})
        dokkit.beat("b")
        self.assertEqual(len(dokkit._state.lines), 2)

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

    @unittest.skipUnless(hasattr(os, "fork"), "needs fork")
    def test_the_sender_thread_is_back_after_a_fork(self):
        dokkit._state.add({"type": "beat"})
        dokkit._state.lines.append("x")
        pid = os.fork()
        if pid == 0:
            os._exit(0 if any(t.name == "dokkit" for t in threading.enumerate()) and not dokkit._state.lines else 1)
        self.assertEqual(os.waitpid(pid, 0)[1], 0)


if __name__ == "__main__":
    unittest.main()
