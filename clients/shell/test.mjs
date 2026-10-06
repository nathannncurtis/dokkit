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

// Runs a snippet of shell with the library sourced, against a local server.
async function snippet(code, { url = (port) => `http://127.0.0.1:${port}/` } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      got.push(JSON.parse(body));
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const run = await new Promise((done) =>
    execFile("sh", ["-c", `cd "${dir}" && ${code}`], { env: { ...process.env, DOKKIT_URL: url(server.address().port), DOKKIT_KEY: "dka_test" } }, (error, stdout, stderr) =>
      done({ code: error ? error.code : 0, stdout, stderr }),
    ),
  );
  server.close();
  return { got, ...run };
}

test("unset variables are fine under set -u, and a failing job under set -e is still reported", async () => {
  const r = await snippet(`unset DOKKIT_URL DOKKIT_KEY; set -eu; . ./dokkit.sh; dokkit_beat x; echo off`);
  assert.strictEqual(r.stdout.trim(), "off");
  const f = await snippet(`set -e; . ./dokkit.sh; dokkit_job j false; echo not-reached`);
  assert.deepStrictEqual(f.got.map((l) => l.event), ["start", "fail"]);
  assert.strictEqual(f.stdout, "");
});

test("arguments cannot add fields to a line", async () => {
  const r = await snippet(`. ./dokkit.sh
    dokkit_check n ok '1,"x":2'
    dokkit_check n 'ok","x":"y' 1
    dokkit_metric n '7,"x":1'
    dokkit_beat n '5,"x":1'
    dokkit_log 'info","x":"y' hi
    dokkit_check 'a b' ok 2 "tab	here"`);
  assert.deepStrictEqual(r.got.map((l) => l.type), ["log", "custom"]);
  assert.strictEqual(r.got[0].level, 'info","x":"y');
  assert.strictEqual(r.got[0].x, undefined);
  assert.strictEqual(r.got[1].note, "tab here");
});

test("each run has its own id, also for jobs in parallel and nested", async () => {
  const r = await snippet(`. ./dokkit.sh; dokkit_job a true & dokkit_job a true & wait; dokkit_job outer dokkit_job inner true`);
  const runs = {};
  for (const l of r.got) (runs[l.run] ||= []).push(l.name + ":" + l.event);
  assert.strictEqual(Object.keys(runs).length, 4);
  assert.ok(Object.values(runs).every((e) => e.length === 2));
});

test("plain http to another host keeps it off", async () => {
  const r = await snippet(`. ./dokkit.sh; dokkit_beat x; dokkit_beat y`, { url: () => "http://example.com" });
  assert.strictEqual(r.got.length, 0);
  assert.strictEqual(r.stderr.trim().split("\n").length, 1);
  assert.match(r.stderr, /^dokkit: http:\/\//);
});
