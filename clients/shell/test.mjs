// Runs try.sh against a small local server.   node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import test from "node:test";

test("off when blank, then one line per call", async () => {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      got.push([req.url, req.headers.authorization, JSON.parse(body)]);
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const script = new URL("try.sh", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const out = await new Promise((done, fail) =>
    execFile("sh", [script, server.address().port], (e, out) => (e ? fail(e) : done(out))),
  );
  server.close();

  assert.match(out, /code=3/);
  assert.ok(got.every(([path, auth]) => path === "/api/v1/report" && auth === "Bearer dka_test"));
  const lines = got.map(([, , l]) => l);
  assert.deepStrictEqual(lines.map((l) => l.type), ["beat", "custom", "metric", "log", "job", "job"]);
  assert.strictEqual(lines[0].every_seconds, 30);
  assert.strictEqual(lines[1].note, 'oldest item is "14" minutes \\ old');
  assert.strictEqual(lines[1].value, 14);
  assert.deepStrictEqual([lines[5].event, lines[5].exit_code], ["fail", 3]);
  assert.strictEqual(lines[4].run, lines[5].run);
  assert.ok(lines.every((l) => l.host));
});
