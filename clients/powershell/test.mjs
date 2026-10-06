// Runs try.ps1 against a small local server.   node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import test from "node:test";

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
  const script = new URL("try.ps1", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  await new Promise((done, fail) =>
    execFile("pwsh", ["-NoProfile", "-File", script, "-Port", server.address().port], (e, out, err) =>
      e || err ? fail(e || new Error(err)) : done(),
    ),
  );
  server.close();

  assert.ok(got.every(([, auth]) => auth === "Bearer dka_test"));
  const lines = got.filter(([path]) => path === "/api/v1/report").map(([, , l]) => l);
  assert.deepStrictEqual(lines.map((l) => l.type), ["deploy", "beat", "custom", "log", "job", "job", "job"]);
  assert.strictEqual(lines[1].every_seconds, 30);
  assert.strictEqual(lines[2].note, 'oldest item is "14" minutes old');
  assert.deepStrictEqual(lines.slice(4).map((l) => l.event), ["start", "progress", "fail"]);
  assert.strictEqual(lines[5].total, 9000);
  assert.strictEqual(lines[4].run, lines[6].run);
  const [error] = got.filter(([path]) => path === "/api/v1/errors").map(([, , l]) => l);
  assert.strictEqual(error.type, "InvalidOperationException");
  assert.strictEqual(error.handled, false);
  assert.ok(error.frames.at(-1).own && error.frames.at(-1).line === 13);
  assert.ok(!JSON.stringify(got).includes("4411") && !JSON.stringify(got).includes("ignored"));
});
