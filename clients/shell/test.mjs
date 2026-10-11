// Runs try.sh against a small local server.   node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import test from "node:test";
import zlib from "node:zlib";

test("off when blank, then one line per call", async () => {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      got.push([req.url, req.headers.authorization, JSON.parse(body), req.headers["dokkit-batch"]]);
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
  assert.ok(got.every(([path, auth]) => auth === "Bearer dka_test" && path === (path.endsWith("errors") ? "/api/v1/errors" : "/api/v1/report")));
  assert.strictEqual(got[4][0], "/api/v1/errors");
  const lines = got.map(([, , l]) => l);
  assert.deepStrictEqual(lines.map((l) => l.type), ["beat", "custom", "metric", "log", "UploadError", "job", "job"]);
  assert.deepStrictEqual([lines[4].handled, lines[4].frames, lines[4].message], [true, [], undefined]);
  assert.match(lines[4].at, /^\d{4}-\d\d-\d\dT[\d:]+Z$/);
  assert.ok(got.every((g) => /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(g[3])));
  assert.strictEqual(lines[0].every_seconds, 30);
  assert.strictEqual(lines[1].note, 'oldest item is "14" minutes \\ old');
  assert.strictEqual(lines[1].value, 14);
  assert.deepStrictEqual([lines[6].event, lines[6].exit_code], ["fail", 3]);
  assert.strictEqual(lines[5].run, lines[6].run);
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

test("a control character in the type or message still gives valid JSON", async () => {
  const r = await snippet(`. ./dokkit.sh; dokkit_capture "$(printf 'Up\\rload\\001Err')"; dokkit_log info "$(printf 'a\\rb\\037c\\013d')"`);
  assert.strictEqual(r.got.length, 2);
  assert.strictEqual(r.got[0].type, "UploadErr");
  assert.strictEqual(r.got[1].msg, "abcd");
});

test("an error report is sent once even when the answer is a failure; a log line is tried twice", async () => {
  let posts = [];
  const server = http.createServer((req, res) => {
    posts.push(req.url);
    req.resume();
    res.statusCode = 500;
    res.end();
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  await new Promise((done) =>
    execFile("sh", ["-c", `cd "${dir}" && . ./dokkit.sh; dokkit_capture UploadError; dokkit_log info x`], { env: { ...process.env, DOKKIT_URL: `http://127.0.0.1:${server.address().port}`, DOKKIT_KEY: "k" } }, done),
  );
  server.close();
  assert.deepStrictEqual(posts, ["/api/v1/errors", "/api/v1/report", "/api/v1/report"]);
});

// Runs a snippet against a server that keeps what it got: path, headers and the raw body.
async function raw(code, env = {}, status = 200) {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      got.push({ url: req.url, headers: req.headers, body: Buffer.concat(chunks) });
      res.statusCode = status;
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const run = await new Promise((done) =>
    execFile("sh", ["-c", `cd "${dir}" && . ./dokkit.sh; ${code}`], { env: { ...process.env, DOKKIT_URL: `http://127.0.0.1:${server.address().port}`, DOKKIT_KEY: "k", ...env }, maxBuffer: 1 << 26 }, (error, stdout, stderr) => done({ stdout, stderr })),
  );
  server.close();
  const bodies = got.map((g) => (g.headers["content-encoding"] === "gzip" ? zlib.gunzipSync(g.body) : g.body));
  const lines = bodies.flatMap((b) => b.toString().split("\n").map((l) => JSON.parse(l)));
  return { got, bodies, lines, ...run };
}

test("a log line over 64 KB is cut in bytes, never mid-character, with a marker", async () => {
  const r = await raw(`dokkit_log info "$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\\303\\251\\\\" }')"; dokkit_log info short`);
  assert.ok(r.bodies[0].length <= 65536);
  assert.ok(r.lines[0].msg.endsWith(" [cut]") && !r.lines[0].msg.includes("�"));
  assert.strictEqual(r.lines[1].msg, "short");
});

test("a large report body is gzipped, a small one is not", async () => {
  const r = await raw(`dokkit_log info "$(awk 'BEGIN { for (i = 0; i < 3000; i++) printf "abc " }')"; dokkit_log info small`);
  assert.deepStrictEqual(r.got.map((g) => g.headers["content-encoding"]), ["gzip", undefined]);
  assert.strictEqual(r.lines[0].msg.length, 12000);
});

test("DOKKIT_VERSION is announced once, first, unless DOKKIT_ANNOUNCE_VERSION=0; dokkit_deploy sends at once", async () => {
  const on = await raw(`dokkit_beat a; dokkit_beat b`, { DOKKIT_VERSION: "2.3.0" });
  assert.deepStrictEqual(on.lines.map((l) => l.type), ["deploy", "beat", "beat"]);
  assert.strictEqual(on.lines[0].version, "2.3.0");
  assert.strictEqual(on.got.length, 2);
  const off = await raw(`dokkit_beat a`, { DOKKIT_VERSION: "2.3.0", DOKKIT_ANNOUNCE_VERSION: "0" });
  assert.deepStrictEqual(off.lines.map((l) => l.type), ["beat"]);
  const d = await raw(`dokkit_deploy 9.1; dokkit_beat a`, { DOKKIT_VERSION: "2.3.0" });
  assert.deepStrictEqual(d.lines.map((l) => l.type + ":" + (l.version || "")), ["deploy:9.1", "beat:"]);
});

test("dokkit_stats sends a document from JSON or a file, and ignores anything else", async () => {
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const r = await raw(`dokkit_stats '{"queue": {"depth": 4}}'; dokkit_stats "${dir}test.mjs"; dokkit_stats nope; dokkit_stats ''`);
  assert.deepStrictEqual(r.lines.map((l) => [l.type, l.document]), [["stats", { queue: { depth: 4 } }]]);
});

test("an environment other than production goes on every line; production and blank add nothing", async () => {
  const dev = await raw(`dokkit_log info x; dokkit_beat b; dokkit_job j true`, { DOKKIT_ENV: "dev" });
  assert.ok(dev.lines.length === 4 && dev.lines.every((l) => l.environment === "dev"));
  for (const env of ["production", ""]) {
    const r = await raw(`dokkit_log info x; dokkit_beat b`, { DOKKIT_ENV: env });
    assert.ok(r.lines.every((l) => !("environment" in l)));
  }
});

test("an error report is tried again only when nothing could connect", async () => {
  const closed = http.createServer();
  await new Promise((done) => closed.listen(0, "127.0.0.1", done));
  const port = closed.address().port;
  await new Promise((done) => closed.close(done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  await new Promise((done) => execFile("sh", ["-c", `cd "${dir}" && . ./dokkit.sh; dokkit_capture E`], { env: { ...process.env, DOKKIT_URL: `http://127.0.0.1:${port}`, DOKKIT_KEY: "k" } }, done));
  const r = await raw(`dokkit_capture E`, {}, 429);
  assert.strictEqual(r.got.length, 1);
});
