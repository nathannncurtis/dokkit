// Runs try.ps1 against a small local server.   node --test
import assert from "node:assert";
import { execFile } from "node:child_process";
import http from "node:http";
import os from "node:os";
import test from "node:test";
import zlib from "node:zlib";

const unpack = (req, chunks) => {
  const body = Buffer.concat(chunks);
  return (req.headers["content-encoding"] === "gzip" ? zlib.gunzipSync(body) : body).toString();
};

test("everything is off until started, then sends", async () => {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = unpack(req, chunks);
      for (const line of body.split("\n")) got.push([req.url, req.headers.authorization, JSON.parse(line)]);
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const script = new URL("try.ps1", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  await new Promise((done, fail) =>
    execFile("pwsh", ["-NoProfile", "-File", script, "-Port", server.address().port], { cwd: os.tmpdir() }, (e, out, err) =>
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
  assert.ok(error.frames.at(-1).own && error.frames.at(-1).line === 13 && error.frames.at(-1).file === "try.ps1");
  assert.ok(!JSON.stringify(got).includes("4411") && !JSON.stringify(got).includes("ignored"));
});

// Runs a snippet with the module imported and started, against a local server.
async function snippet(code, { status = 200, url = (port) => `http://127.0.0.1:${port}/` } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = unpack(req, chunks);
      got.push({ batch: req.headers["dokkit-batch"], lines: body.split("\n").map((l) => JSON.parse(l)) });
      res.statusCode = status;
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const script = `Import-Module '${dir}Dokkit.psm1'; Start-Dokkit -Url '${url(server.address().port)}' -Key k; ${code}`;
  const run = await new Promise((done) =>
    execFile("pwsh", ["-NoProfile", "-Command", script], (error, stdout, stderr) => done({ stdout, stderr })),
  );
  server.close();
  return { got, ...run };
}

test("zero values and empty messages are kept, and a nested job leaves the outer one's run alone", async () => {
  const r = await snippet(`
    Send-DokkitMetric depth 0
    Send-DokkitCheck c ok -Value 0
    Write-DokkitLog info ''
    Invoke-DokkitJob outer { Invoke-DokkitJob inner { }; Send-DokkitProgress 0 5 }
    Send-Dokkit`);
  const lines = r.got.flatMap((g) => g.lines);
  assert.strictEqual(lines.find((l) => l.type === "metric").value, 0);
  assert.strictEqual(lines.find((l) => l.type === "custom").value, 0);
  assert.ok(lines.find((l) => l.type === "log"));
  const ok = lines.find((l) => l.event === "ok" && l.name === "inner");
  assert.strictEqual(ok.exit_code, 0);
  const progress = lines.find((l) => l.event === "progress");
  assert.strictEqual(progress.done, 0);
  assert.strictEqual(progress.run, lines.find((l) => l.event === "start" && l.name === "outer").run);
});

test("plain http to another host keeps it off", async () => {
  const r = await snippet(`Send-DokkitBeat x; Send-Dokkit`, { url: () => "http://example.com" });
  assert.strictEqual(r.got.length, 0);
  assert.match(r.stderr, /dokkit: http:\/\//);
});

test("a failed batch is sent once more with the same id, then dropped and counted", async () => {
  const r = await snippet(`Send-DokkitBeat x; Send-Dokkit; & (Get-Module Dokkit) { $script:Dropped }`, { status: 503 });
  assert.strictEqual(r.got.length, 2);
  assert.strictEqual(r.got[0].batch, r.got[1].batch);
  assert.strictEqual(r.stdout.trim(), "1");
});

// Runs a snippet against a server that keeps path, headers and the decoded body; status is given per path.
async function raw(code, { start = "", status = () => 200, cwd } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      let body = Buffer.concat(chunks);
      if (req.headers["content-encoding"] === "gzip") body = zlib.gunzipSync(body);
      got.push({ url: req.url, headers: req.headers, size: body.length, lines: body.toString().split("\n").map((l) => JSON.parse(l)) });
      res.statusCode = status(req.url, got.length);
      res.end("{}");
    });
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  const dir = new URL(".", import.meta.url).pathname.replace(/^\/(\w:)/, "$1");
  const script = `Import-Module '${dir}Dokkit.psm1'; Start-Dokkit -Url 'http://127.0.0.1:${server.address().port}' -Key k ${start}; ${code}`;
  const run = await new Promise((done) => execFile("pwsh", ["-NoProfile", "-Command", script], { cwd }, (error, stdout, stderr) => done({ stdout, stderr })));
  server.close();
  return { got, lines: got.flatMap((g) => g.lines), ...run };
}

test("a log line over 64 KB is cut in bytes with a marker, and a small one is untouched", async () => {
  const r = await raw(`Write-DokkitLog info ([string]::new([char]0x00e9, 70000)); Write-DokkitLog info short; Send-Dokkit`);
  assert.ok(r.got[0].size <= 65536 + 1 + 200);
  const [big, small] = r.lines;
  assert.ok(big.msg.endsWith(" [cut]") && big.msg.length > 30000);
  assert.strictEqual(small.msg, "short");
});

test("report bodies are gzipped", async () => {
  const r = await raw(`Write-DokkitLog info hi; Send-Dokkit`);
  assert.strictEqual(r.got[0].headers["content-encoding"], "gzip");
  assert.strictEqual(r.lines[0].msg, "hi");
});

test("-AnnounceVersion $false leaves out the deploy line", async () => {
  const on = await raw(`Send-DokkitBeat x; Send-Dokkit`, { start: "-Version 2.3.0" });
  assert.deepStrictEqual(on.lines.map((l) => l.type), ["deploy", "beat"]);
  const off = await raw(`Send-DokkitBeat x; Send-Dokkit`, { start: "-Version 2.3.0 -AnnounceVersion $false" });
  assert.deepStrictEqual(off.lines.map((l) => l.type), ["beat"]);
});

test("Send-DokkitStats sends an object or a JSON string and ignores bad JSON", async () => {
  const r = await raw(`Send-DokkitStats @{ queue = @{ depth = 4 } }; Send-DokkitStats '{"a":{"b":1}}'; Send-DokkitStats '{nope'; Send-Dokkit`);
  assert.deepStrictEqual(r.lines.map((l) => [l.type, l.document]), [["stats", { queue: { depth: 4 } }], ["stats", { a: { b: 1 } }]]);
});

test("an environment other than production goes on every line; production adds nothing", async () => {
  const code = `Write-DokkitLog info x; Send-DokkitBeat b; Invoke-DokkitJob j { }; Send-Dokkit`;
  const dev = await raw(code, { start: "-Environment dev" });
  assert.ok(dev.lines.length === 4 && dev.lines.every((l) => l.environment === "dev"));
  for (const env of ["production", ""]) {
    const r = await raw(code, { start: `-Environment '${env}'` });
    assert.ok(r.lines.length === 4 && r.lines.every((l) => !("environment" in l)));
  }
});

test("an error report the server did not answer for is kept for the next pass; a refused one is dropped", async () => {
  const kept = await raw(`try { throw 'x' } catch { Send-DokkitError $_ }; Send-Dokkit; Send-Dokkit; & (Get-Module Dokkit) { "$($script:Errors.Count) $script:Dropped" }`, {
    status: (url, n) => (url === "/api/v1/errors" && n === 1 ? 503 : 200),
  });
  assert.strictEqual(kept.got.filter((g) => g.url === "/api/v1/errors").length, 2);
  assert.strictEqual(kept.stdout.trim(), "0 0");
  const dropped = await raw(`try { throw 'x' } catch { Send-DokkitError $_ }; Write-DokkitLog info x; Send-Dokkit; Send-Dokkit; & (Get-Module Dokkit) { "$($script:Errors.Count) $script:Dropped" }`, {
    status: (url) => (url === "/api/v1/errors" ? 400 : 200),
  });
  assert.strictEqual(dropped.got.filter((g) => g.url === "/api/v1/errors").length, 1);
  assert.strictEqual(dropped.got.filter((g) => g.url === "/api/v1/report").length, 1);
  assert.strictEqual(dropped.stdout.trim(), "0 1");
  const limited = await raw(`try { throw 'x' } catch { Send-DokkitError $_ }; Send-Dokkit; & (Get-Module Dokkit) { $script:Errors.Count }`, { status: () => 429 });
  assert.strictEqual(limited.stdout.trim(), "1");
});
