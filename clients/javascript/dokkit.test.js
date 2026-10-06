// node --test
import assert from "node:assert";
import http from "node:http";
import test from "node:test";
import * as dokkit from "./dokkit.js";

test("everything is off until started, then sends", async () => {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      for (const line of body.split("\n")) got.push([req.url, req.headers.authorization, JSON.parse(line)]);
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));

  dokkit.beat("ignored");
  dokkit.start({ version: "2.3.0", url: `http://127.0.0.1:${server.address().port}/`, key: "dka_test" });
  dokkit.beat("worker", 30);
  dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
  dokkit.log("error", "Upload failed");
  await assert.rejects(
    dokkit.job("nightly-purge", async (run) => {
      run.progress(4000, 9000);
      throw new RangeError("patient 4411");
    }),
  );
  await dokkit.flush();
  server.close();

  assert.ok(got.every(([, auth]) => auth === "Bearer dka_test"));
  const lines = got.filter(([path]) => path === "/api/v1/report").map(([, , l]) => l);
  assert.deepStrictEqual(lines.map((l) => l.type), ["deploy", "beat", "custom", "log", "job", "job", "job"]);
  assert.strictEqual(lines[1].every_seconds, 30);
  assert.deepStrictEqual(lines.slice(4).map((l) => l.event), ["start", "progress", "fail"]);
  assert.strictEqual(lines[4].run, lines[6].run);
  const [error] = got.filter(([path]) => path === "/api/v1/errors").map(([, , l]) => l);
  assert.strictEqual(error.type, "RangeError");
  assert.strictEqual(error.handled, false);
  assert.ok(error.frames.at(-1).own && error.frames.at(-1).line > 0);
  assert.ok(!JSON.stringify(got).includes("4411"));
});
