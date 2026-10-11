// node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import os from "node:os";
import zlib from "node:zlib";
import test from "node:test";
import * as dokkit from "./dokkit.js";

test("everything is off until started, then sends", async () => {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks);
      const body = (req.headers["content-encoding"] === "gzip" ? zlib.gunzipSync(raw) : raw).toString();
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

// Each case runs in its own process because the library keeps one global state.
async function scenario(code, { status = 200, statuses = {}, env = {} } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks);
      const zipped = req.headers["content-encoding"] === "gzip";
      const body = (zipped ? zlib.gunzipSync(raw) : raw).toString();
      got.push({ url: req.url, batch: req.headers["dokkit-batch"], zipped, lines: body.split("\n").map((l) => JSON.parse(l)) });
      res.statusCode = statuses[req.url] ?? status;
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const url = `http://127.0.0.1:${server.address().port}`;
  const clean = { ...process.env };
  delete clean.HOSTNAME;
  delete clean.COMPUTERNAME;
  const run = await new Promise((done) =>
    execFile(
      process.execPath,
      ["--input-type=module", "-e", `import * as dokkit from "./dokkit.js"; const url = ${JSON.stringify(url)};\n${code}`],
      { cwd: new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1"), env: { ...clean, ...env } },
      (error, stdout, stderr) => done({ code: error ? error.code : 0, stdout, stderr }),
    ),
  );
  server.close();
  return { got, ...run };
}

test("a job runs on Node 18 without crypto.randomUUID and the host is the machine's name", async () => {
  const r = await scenario(`
    Object.defineProperty(globalThis, "crypto", { value: undefined, configurable: true });
    dokkit.start({ url, key: "k" });
    await dokkit.job("j", async () => 1);
    await dokkit.flush();`);
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  assert.match(r.got[0].batch, uuid);
  assert.match(r.got[0].lines[0].run, uuid);
  assert.strictEqual(r.got[0].lines[0].host, os.hostname());
});

test("a plain http address to another host keeps it off", async () => {
  const r = await scenario(`dokkit.start({ url: "http://example.com", key: "k" }); dokkit.beat("x"); await dokkit.flush();`);
  assert.match(r.stderr, /^dokkit: http:\/\//);
  assert.strictEqual(r.got.length, 0);
});

test("the insecure option allows plain http, and a line over 64 KB is cut", async () => {
  const r = await scenario(`dokkit.start({ url: url.replace("127.0.0.1", "localhost"), key: "k" }); dokkit.beat("small"); dokkit.log("info", "\u00e9".repeat(5_000_000), { a: 1 }); await dokkit.flush(); console.log(dokkit.dropped);`);
  const big = r.got[0].lines.at(-1);
  assert.strictEqual(r.got[0].lines.length, 2);
  assert.ok(Buffer.byteLength(JSON.stringify(big)) <= 65536);
  assert.ok(big.msg.endsWith(" [cut]") && !big.msg.includes("\ufffd") && big.fields === undefined);
  assert.strictEqual(r.stdout.trim(), "0");
  const o = await scenario(`dokkit.start({ url: "http://example.com", key: "k", insecure: true }); dokkit.beat("x"); console.log("on");`);
  assert.strictEqual(o.stderr, "");
});

test("a failed batch is sent once more with the same id, then dropped and counted", async () => {
  const r = await scenario(
    `dokkit.start({ url, key: "k" }); dokkit.beat("x"); await dokkit.flush(); await dokkit.flush(); console.log(dokkit.dropped);`,
    { status: 503 },
  );
  assert.strictEqual(r.got.length, 2);
  assert.strictEqual(r.got[0].batch, r.got[1].batch);
  assert.strictEqual(r.stdout.trim(), "1");
});

test("an error nothing caught is sent before the process ends", async () => {
  const r = await scenario(`dokkit.start({ url, key: "k" }); dokkit.catchUnhandled(); setTimeout(() => { throw new TypeError("x"); }, 10);`);
  assert.strictEqual(r.code, 1);
  assert.strictEqual(r.got[0].url, "/api/v1/errors");
  assert.strictEqual(r.got[0].lines[0].type, "TypeError");
  assert.ok(r.got[0].lines[0].frames.every((f) => !/^\w:|^\//.test(f.file)));
});

test("Firefox and Safari stack lines are read", async () => {
  const r = await scenario(`
    dokkit.start({ url, key: "k" });
    dokkit.capture({ name: "E", stack: "run@https://x.test/a.js:3:4\\n@https://x.test/b.js:5:6\\n[native code]" });
    await dokkit.flush();`);
  assert.ok(r.got[0], r.stderr);
  assert.deepStrictEqual(r.got[0].lines[0].frames.map((f) => [f.function, f.line]), [["(anonymous)", 5], ["run", 3]]);
});

test("patchConsole sends console calls through log and can be undone", async () => {
  const r = await scenario(`
    dokkit.start({ url, key: "k" });
    const restore = dokkit.patchConsole();
    console.warn("careful", { a: 1 });
    restore();
    console.error("not sent");
    await dokkit.flush();`);
  assert.deepStrictEqual(r.got[0].lines.map((l) => [l.level, l.msg]), [["warn", 'careful {"a":1}']]);
  assert.match(r.stderr, /careful/);
});

test("a large object is cut while it is written, never serialised whole", async () => {
  const r = await scenario(`
    dokkit.start({ url, key: "k" });
    const big = Array.from({ length: 300000 }, (_, i) => ({ i, name: "row" + i, nested: { a: [1, 2, 3] } }));
    const real = JSON.stringify;
    let whole = 0;
    JSON.stringify = function (v, ...rest) { if (v === big || (Array.isArray(v) && v.length > 1000)) whole++; return real.call(this, v, ...rest); };
    const started = Date.now();
    const restore = dokkit.patchConsole();
    console.info(big);
    console.info({ s: "x".repeat(1e6) });
    restore();
    JSON.stringify = real;
    await dokkit.flush();
    console.log(whole, Date.now() - started < 500);`);
  assert.ok(r.got[0].lines.every((l) => l.msg.length <= 2000), "capped");
  assert.ok(r.got[0].lines[0].msg.startsWith('[{"i":0,"name":"row0","nested":{"a":[1,2,3]}},'));
  assert.strictEqual(r.stdout.trim().split("\n").pop(), "0 true");
});

test("small values are written as JSON.stringify writes them", async () => {
  const r = await scenario(`
    dokkit.start({ url, key: "k" });
    const restore = dokkit.patchConsole();
    const loop = {}; loop.me = loop;
    console.info({ a: 1, b: [1, null, undefined, () => 1], c: "q\\"", d: undefined, e: new Date(0) }, loop, 5n, NaN);
    restore();
    await dokkit.flush();`);
  assert.strictEqual(r.got[0].lines[0].msg, '{"a":1,"b":[1,null,null,null],"c":"q\\"","e":"1970-01-01T00:00:00.000Z"} [object Object] 5 null');
});

test("with Dokkit off the console wrapper serialises nothing, and log never throws", async () => {
  const r = await scenario(`
    let n = 0;
    const restore = dokkit.patchConsole();
    console.log({ toJSON() { n++; return 1; } });
    dokkit.log("info", { toString() { throw new Error("no"); } });
    restore();
    console.log(n);`);
  assert.strictEqual(r.stdout.trim().split("\n").pop(), "0");
});

test("consoleLogger tolerates a target with a missing method", () => {
  const seen = [];
  const c = dokkit.consoleLogger({ log: (x) => seen.push(x) });
  assert.doesNotThrow(() => c.trace("x"));
  c.log("y");
  assert.deepStrictEqual(seen, ["y"]);
});

test("patchConsole keeps console properties, and a second patch restores fully", async () => {
  const r = await scenario(`
    const original = console;
    const had = original._stdout !== undefined;
    const r1 = dokkit.patchConsole();
    const r2 = dokkit.patchConsole();
    const kept = console._stdout === original._stdout;
    r1();
    r2();
    process.stdout.write(JSON.stringify([had, kept, console === original]));`);
  assert.strictEqual(r.stdout.trim(), "[true,true,true]");
});

test("a report body is gzipped, and a start without announceVersion sends no deploy line", async () => {
  const r = await scenario(`dokkit.start({ version: "1", url, key: "k", announceVersion: false }); dokkit.beat("x"); await dokkit.flush();`);
  assert.ok(r.got[0].zipped);
  assert.deepStrictEqual(r.got[0].lines.map((l) => l.type), ["beat"]);
  const d = await scenario(`dokkit.start({ version: "1", url, key: "k" }); dokkit.start({ version: "2", url, key: "k" }); await dokkit.flush(); await dokkit.flush();`);
  assert.deepStrictEqual(d.got.flatMap((g) => g.lines.map((l) => l.type + l.version)), ["deploy1"]);
});

test("without CompressionStream the body is sent plain", async () => {
  const r = await scenario(`delete globalThis.CompressionStream; dokkit.start({ url, key: "k" }); dokkit.beat("x"); await dokkit.flush();`);
  assert.ok(!r.got[0].zipped);
  assert.strictEqual(r.got[0].lines[0].type, "beat");
});

test("console output while the library's own fetch runs is not queued", async () => {
  const r = await scenario(`
    const bodies = [];
    globalThis.fetch = (u, o) => { console.warn("own"); bodies.push(o.body); return Promise.resolve({ ok: true, status: 200 }); };
    dokkit.start({ url, key: "k", announceVersion: false });
    const restore = dokkit.patchConsole();
    console.info("app");
    await dokkit.flush();
    console.info("app2");
    await dokkit.flush();
    restore();
    const { gunzipSync } = await import("node:zlib");
    console.log(bodies.map((b) => (b instanceof Uint8Array ? gunzipSync(b).toString() : b)).join("|").match(/"msg":"[a-z0-9]+"/g).join(" "));`);
  assert.strictEqual(r.stdout.trim().split("\n").pop(), '"msg":"app" "msg":"app2"');
  assert.match(r.stderr, /own/);
});

test("a failed error report is kept and the lines still go; a refused one is dropped and counted", async () => {
  const r = await scenario(
    `dokkit.start({ url, key: "k", announceVersion: false }); dokkit.capture(new Error("x")); dokkit.beat("x"); await dokkit.flush(); console.log(dokkit.dropped);`,
    { statuses: { "/api/v1/errors": 503 } },
  );
  assert.deepStrictEqual(r.got.slice(0, 2).map((g) => g.url), ["/api/v1/errors", "/api/v1/report"]);
  assert.strictEqual(r.stdout.trim(), "0");
  const k = await scenario(
    `dokkit.start({ url, key: "k", announceVersion: false }); dokkit.capture(new Error("x")); await dokkit.flush(); await dokkit.flush();`,
    { statuses: { "/api/v1/errors": 429 } },
  );
  assert.ok(k.got.length >= 2);
  const f = await scenario(
    `dokkit.start({ url, key: "k", announceVersion: false }); dokkit.capture(new Error("x")); dokkit.beat("x"); await dokkit.flush(); await dokkit.flush(); console.log(dokkit.dropped);`,
    { statuses: { "/api/v1/errors": 400 } },
  );
  assert.deepStrictEqual(f.got.slice(0, 2).map((g) => g.url), ["/api/v1/errors", "/api/v1/report"]);
  assert.strictEqual(f.stdout.trim(), "1");
});

test("a failed log batch does not stop the error reports", async () => {
  const r = await scenario(
    `dokkit.start({ url, key: "k", announceVersion: false }); dokkit.beat("x"); dokkit.capture(new Error("x")); await dokkit.flush();`,
    { statuses: { "/api/v1/report": 503 } },
  );
  assert.deepStrictEqual(r.got.slice(0, 2).map((g) => g.url), ["/api/v1/errors", "/api/v1/report"]);
});

test("stack paths are relative to the app's folder, and files outside carry only a name or what follows node_modules", async () => {
  const r = await scenario(`
    dokkit.start({ url, key: "k", announceVersion: false });
    const cwd = process.cwd().replace(/\\\\/g, "/");
    dokkit.capture({ name: "E", stack: ["Error", "    at a (" + cwd + "/src/app.js:1:2)", "    at b (" + cwd + "/node_modules/pkg/i.js:3:4)", "    at c (/elsewhere/deep/o.js:5:6)"].join("\\n") });
    await dokkit.flush();`);
  assert.deepStrictEqual(r.got[0].lines[0].frames.map((f) => [f.file, f.own]), [["o.js", false], ["node_modules/pkg/i.js", false], ["src/app.js", true]]);
});

test("a non-production environment is on every line, production adds nothing", async () => {
  const code = (e) => `dokkit.start({ version: "1", url, key: "k", environment: "${e}" }); dokkit.log("info", "m"); dokkit.beat("b"); await dokkit.job("j", async () => 1); await dokkit.flush();`;
  const d = await scenario(code("dev"));
  assert.ok(d.got[0].lines.length >= 5 && d.got[0].lines.every((l) => l.environment === "dev"));
  const p = await scenario(code("production"));
  assert.ok(p.got[0].lines.every((l) => !("environment" in l)));
});
