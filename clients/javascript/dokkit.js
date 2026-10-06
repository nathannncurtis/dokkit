// The Dokkit client library for JavaScript. One file, no packages. Node 18 or later, and browsers.
//
//     import * as dokkit from "./dokkit.js";
//     dokkit.start({ version: "2.3.0" });      // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     dokkit.beat("worker");                   // from the main loop
//     await dokkit.job("nightly-purge", async (run) => { run.progress(4000, 9000); });
//     dokkit.check("queue-age", "degraded", 14, "oldest item is 14 minutes old");
//     dokkit.capture(error);
//     const restore = dokkit.patchConsole();   // optional: console.* also goes to the log
//
// Nothing here throws into the app or waits on the network. Lines wait in a queue of fixed
// size and a timer sends them. Error message text is never sent.

const QUEUE = 1000;
const MAX_BYTES = 4_000_000;
let state = null;
let busy = false;
let tail = Promise.resolve();

// Node 18 and plain-http browser pages have no crypto.randomUUID.
const uuid = () => {
  const c = globalThis.crypto;
  if (c?.randomUUID) return c.randomUUID();
  const b = new Uint8Array(16).map(() => (c?.getRandomValues ? c.getRandomValues(new Uint8Array(1))[0] : Math.random() * 256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};

const enc = new TextEncoder();
const size = (text) => enc.encode(text).length;

/** How many lines were dropped because the queue was full. */
export let dropped = 0;

const env = (name) => (typeof process !== "undefined" && process.env && process.env[name]) || "";
const now = () => new Date().toISOString();

/** Turns the library on. With no address or key it stays off and every call does nothing. */
export function start({ version, environment, url, key, host, insecure } = {}) {
  try {
    url = url || env("DOKKIT_URL");
    key = key || env("DOKKIT_KEY");
    if (!url || !key || state) return;
    if (/^http:\/\//i.test(url) && !/^http:\/\/(localhost|127(\.\d+){3}|\[::1\])([:/]|$)/i.test(url) && !insecure && env("DOKKIT_INSECURE") !== "1") {
      console.error("dokkit: http:// address to a non-local host; set DOKKIT_INSECURE=1 or pass insecure: true to allow it. Staying off.");
      return;
    }
    state = {
      url: url.replace(/\/+$/, ""),
      key,
      version,
      environment: environment || env("DOKKIT_ENV") || undefined,
      host: host || env("COMPUTERNAME") || env("HOSTNAME") || globalThis.process?.getBuiltinModule?.("node:os")?.hostname?.() || globalThis.location?.hostname || "unknown",
      lines: [],
      bytes: 0,
      retry: null,
      errors: [],
    };
    const timer = setInterval(() => busy || flush(), 2000);
    if (timer.unref) timer.unref();
    if (typeof process !== "undefined" && process.on) process.on("beforeExit", flush);
    if (version) add({ type: "deploy", version: String(version) });
  } catch {
    state = null;
  }
}

function add(line) {
  try {
    if (!state) return;
    const text = JSON.stringify({ at: now(), ...line, host: state.host });
    const n = size(text);
    if (n > MAX_BYTES) {
      dropped++;
      return;
    }
    while (state.lines.length && (state.lines.length >= QUEUE || state.bytes + n > MAX_BYTES)) {
      state.bytes -= size(state.lines.shift());
      dropped++;
    }
    state.lines.push(text);
    state.bytes += n;
  } catch {
    dropped++;
  }
}

export const beat = (name, everySeconds = 60) => add({ type: "beat", name, every_seconds: everySeconds });

/** state is "ok", "degraded" or "down". */
export const check = (name, state, value, note) => add({ type: "custom", check: name, state, value, note });

export const metric = (name, value, unit) => add({ type: "metric", name, value, unit });

/** level is trace, debug, info, warn, error or fatal. */
export function log(level, msg, fields) {
  try {
    if (state) add({ type: "log", t: now(), level, msg: String(msg), fields });
  } catch {}
}

const LEVELS = { log: "info", debug: "debug", info: "info", warn: "warn", error: "error", trace: "trace" };

const text = (a) => {
  try {
    if (typeof a === "string") return a.slice(0, 2000);
    return (a instanceof Error ? a.name : JSON.stringify(a) ?? String(a)).slice(0, 2000);
  } catch {
    try {
      return String(a).slice(0, 2000);
    } catch {
      return "";
    }
  }
};

/** A console that also sends each call through log. Pass a console to wrap it; the default is the global one. */
export function consoleLogger(target = globalThis.console) {
  const out = Object.create(target);
  for (const [k, level] of Object.entries(LEVELS))
    out[k] = (...args) => {
      if (state)
        try {
          log(level, args.map(text).join(" "));
        } catch {}
      return target[k]?.(...args);
    };
  return out;
}

let restoreConsole = null;

/** Makes the global console send through log too. Returns a function that puts it back. */
export function patchConsole() {
  if (restoreConsole) return restoreConsole;
  const original = globalThis.console;
  globalThis.console = consoleLogger(original);
  const restore = () => {
    if (restoreConsole !== restore) return;
    globalThis.console = original;
    restoreConsole = null;
  };
  return (restoreConsole = restore);
}

/** Sends a stats document, for an app dokkit cannot reach. */
export const stats = (document) => add({ type: "stats", document });

/** Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns. */
export async function job(name, work) {
  const run = uuid();
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

// Paths under the folder the app runs from are sent relative to it; others keep only what follows node_modules, or their name.
function where(file) {
  const root = typeof process !== "undefined" && process.cwd ? process.cwd().replace(/\\/g, "/").replace(/\/+$/, "") : "";
  if (!root) return { file, own: !file.includes("node_modules") && !file.startsWith("node:") };
  let path = file.replace(/^file:\/\//, "").replace(/\\/g, "/").replace(/^\/(\w:)/, "$1");
  try {
    path = decodeURIComponent(path);
  } catch {}
  if (path.startsWith(root + "/") && !path.includes("/node_modules/")) return { file: path.slice(root.length + 1), own: true };
  const i = path.indexOf("/node_modules/");
  return { file: i >= 0 ? path.slice(i + 1) : path.slice(path.lastIndexOf("/") + 1), own: false };
}

/** Sends an error: its type and stack, never its message. */
export function capture(error, { handled = true, tags = {} } = {}) {
  try {
    if (!state || !error) return;
    // Innermost last, as the format asks. Only the "at" lines are read, so the message stays behind.
    // V8 prints "at fn (file:1:2)", Firefox and Safari "fn@file:1:2".
    const frames = String(error.stack || "")
      .split("\n")
      .map((l) => /^\s*at (?:(.+?) \()?(.+?):(\d+):\d+\)?$/.exec(l) || /^\s*(.*?)@(.+?):(\d+):\d+$/.exec(l))
      .filter(Boolean)
      .reverse()
      .map(([, fn, file, line]) => ({ ...where(file), function: fn || "(anonymous)", line: Number(line) }));
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

/** Also reports errors nothing caught. In Node the process ends after the report is sent, or after 3 seconds; if another uncaughtException listener exists it decides whether the process ends. */
export function catchUnhandled() {
  if (typeof process !== "undefined" && process.on) {
    // Node ends the process right after a monitor returns, so the report is sent first.
    process.on("uncaughtException", async (error) => {
      capture(error, { handled: false });
      await Promise.race([flush(), new Promise((done) => setTimeout(done, 3000))]);
      if (process.listenerCount("uncaughtException") > 1) return;
      console.error(error);
      process.exit(1);
    });
  } else {
    globalThis.addEventListener("error", (e) => capture(e.error, { handled: false }));
    globalThis.addEventListener("unhandledrejection", (e) => capture(e.reason, { handled: false }));
  }
}

/** Sends what is waiting. Runs by itself every two seconds. */
export function flush() {
  return (tail = tail.then(send));
}

async function send() {
  if (!state) return;
  busy = true;
  const post = async (path, body, kind, more) => {
    try {
      const res = await fetch(state.url + path, {
        method: "POST",
        body,
        // keepalive bodies are capped at 64 KB
        keepalive: body.length < 16000,
        signal: AbortSignal.timeout?.(10000),
        headers: { Authorization: "Bearer " + state.key, "Content-Type": kind, ...more },
      });
      return res.ok;
    } catch {
      return false;
    }
  };
  try {
    while (state.errors.length) {
      const ok = await post("/api/v1/errors", JSON.stringify(state.errors.shift()), "application/json");
      if (!ok) {
        dropped++;
        return;
      }
    }
    while (state.retry || state.lines.length) {
      if (!state.retry) {
        const lines = state.lines.splice(0, 500);
        state.bytes -= lines.reduce((n, l) => n + size(l), 0);
        state.retry = { id: uuid(), n: lines.length, body: lines.join("\n"), tries: 0 };
      }
      const batch = state.retry;
      if (await post("/api/v1/report", batch.body, "application/x-ndjson", { "Dokkit-Batch": batch.id })) state.retry = null;
      else {
        // A failed batch gets one more try; after that it is dropped and counted.
        if (batch.tries++) {
          dropped += batch.n;
          state.retry = null;
        }
        return;
      }
    }
  } finally {
    busy = false;
  }
}
