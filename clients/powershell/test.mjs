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

// Runs a snippet with the module imported and started, against a local server.
async function snippet(code, { status = 200, url = (port) => `http://127.0.0.1:${port}/` } = {}) {
  const got = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
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
  const r = await snippet(`Send-DokkitBeat x; Send-Dokkit; Send-Dokkit; & (Get-Module Dokkit) { $script:Dropped }`, { status: 503 });
  assert.strictEqual(r.got.length, 2);
  assert.strictEqual(r.got[0].batch, r.got[1].batch);
  assert.strictEqual(r.stdout.trim(), "1");
});
