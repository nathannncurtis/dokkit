// The Dokkit client library for JavaScript. One file, no packages. Node 18 or later, and browsers.
//
//     import * as dokkit from "./dokkit.js";
//     dokkit.start({ version: "2.3.0" });      // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     dokkit.beat("worker");                   // from the main loop
//     await dokkit.job("nightly-purge", async (run) => { run.progress(4000, 9000); });
//     dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
//     dokkit.capture(error);
//
// Nothing here throws into the app or waits on the network. Lines wait in a queue of fixed
// size and a timer sends them. Error message text is never sent.

const QUEUE = 1000;
let state = null;

/** How many lines were dropped because the queue was full. */
export let dropped = 0;

const env = (name) => (typeof process !== "undefined" && process.env && process.env[name]) || "";
const now = () => new Date().toISOString();

/** Turns the library on. With no address or key it stays off and every call does nothing. */
export function start({ version, environment, url, key, host } = {}) {
  try {
    url = url || env("DOKKIT_URL");
    key = key || env("DOKKIT_KEY");
    if (!url || !key || state) return;
    state = {
      url: url.replace(/\/+$/, ""),
      key,
      version,
      environment: environment || env("DOKKIT_ENV") || undefined,
      host: host || env("COMPUTERNAME") || env("HOSTNAME") || globalThis.location?.hostname || "unknown",
      lines: [],
      errors: [],
    };
    const timer = setInterval(flush, 2000);
    if (timer.unref) timer.unref();
    if (typeof process !== "undefined" && process.on) process.on("beforeExit", flush);
    if (version) add({ type: "deploy", version: String(version) });
  } catch {
    state = null;
  }
}

function add(line) {
  if (!state) return;
  if (state.lines.length >= QUEUE) {
    state.lines.shift();
    dropped++;
  }
  state.lines.push({ at: now(), ...line, host: state.host });
}

export const beat = (name, everySeconds = 60) => add({ type: "beat", name, every_seconds: everySeconds });

/** state is "ok", "degraded" or "down". */
export const check = (name, state, value, note) => add({ type: "custom", check: name, state, value, note });

export const metric = (name, value, unit) => add({ type: "metric", name, value, unit });

/** level is trace, debug, info, warn, error or fatal. */
export const log = (level, msg, fields) => add({ type: "log", t: now(), level, msg: String(msg), fields });

/** Sends a stats document, for an app dokkit cannot reach. */
export const stats = (document) => add({ type: "stats", document });

/** Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns. */
export async function job(name, work) {
  const run = globalThis.crypto.randomUUID();
  const began = Date.now();
  const send = (event, more) => add({ type: "job", name, run, event, ...more });
  send("start");
  try {
    const result = await work({ progress: (done, total) => send("progress", { done, total }) });
    send("ok", { exit_code: 0, duration_ms: Date.now() - began });
    return result;
  } catch (error) {
    send("fail", { exit_code: 1, duration_ms: Date.now() - began });
    capture(error, { handled: false });
    throw error;
  } finally {
    flush();
  }
}

/** Sends an error: its type and stack, never its message. */
export function capture(error, { handled = true, tags = {} } = {}) {
  try {
    if (!state || !error) return;
    // Innermost last, as the format asks. Only the "at" lines are read, so the message stays behind.
    const frames = String(error.stack || "")
      .split("\n")
      .map((l) => /^\s*at (?:(.+?) \()?(.+?):(\d+):\d+\)?$/.exec(l))
      .filter(Boolean)
      .reverse()
      .map(([, fn, file, line]) => ({
        file,
        function: fn || "(anonymous)",
        line: Number(line),
        own: !file.includes("node_modules") && !file.startsWith("node:"),
      }));
    if (state.errors.length < 100)
      state.errors.push({
        at: now(),
        type: error.name || error.constructor?.name || "Error",
        handled,
        release: state.version,
        environment: state.environment,
        host: state.host,
        frames,
        tags: Object.fromEntries(Object.entries(tags).map(([k, v]) => [k, String(v)])),
      });
  } catch {}
}

/** Also reports errors nothing caught. In Node the process still ends as it would have. */
export function catchUnhandled() {
  if (typeof process !== "undefined" && process.on) {
    process.on("uncaughtExceptionMonitor", (error) => {
      capture(error, { handled: false });
      flush();
    });
  } else {
    globalThis.addEventListener("error", (e) => capture(e.error, { handled: false }));
    globalThis.addEventListener("unhandledrejection", (e) => capture(e.reason, { handled: false }));
  }
}

/** Sends what is waiting. Runs by itself every two seconds. */
export async function flush() {
  if (!state) return;
  const post = (path, body, kind, more) =>
    fetch(state.url + path, {
      method: "POST",
      body,
      keepalive: true,
      headers: { Authorization: "Bearer " + state.key, "Content-Type": kind, ...more },
    });
  try {
    for (const error of state.errors.splice(0)) await post("/api/v1/errors", JSON.stringify(error), "application/json");
    while (state.lines.length) {
      const batch = state.lines.splice(0, 500).map((l) => JSON.stringify(l)).join("\n");
      await post("/api/v1/report", batch, "application/x-ndjson", { "Dokkit-Batch": globalThis.crypto.randomUUID() });
    }
  } catch {
    // What could not be sent is dropped. The app is never told.
  }
}
