// node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import os from "node:os";
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

// Each case runs in its own process because the library keeps one global state.
async function scenario(code, { status = 200, env = {} } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      got.push({ url: req.url, batch: req.headers["dokkit-batch"], lines: body.split("\n").map((l) => JSON.parse(l)) });
      res.statusCode = status;
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

test("the insecure option allows plain http, and a line over the byte limit is dropped alone", async () => {
  const r = await scenario(`dokkit.start({ url: url.replace("127.0.0.1", "localhost"), key: "k" }); dokkit.beat("small"); dokkit.log("info", "x".repeat(5_000_000)); await dokkit.flush(); console.log(dokkit.dropped);`);
  assert.strictEqual(r.got[0].lines.length, 1);
  assert.strictEqual(r.stdout.trim(), "1");
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
