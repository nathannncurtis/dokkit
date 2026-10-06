import gzip
import http.server
import json
import logging
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


if __name__ == "__main__":
    unittest.main()
