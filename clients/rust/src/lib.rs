//! The Dokkit client library for Rust. One file, one package (`ureq`, for HTTPS).
//!
//! ```no_run
//! dokkit::start("2.3.0");                    // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//! dokkit::beat("worker", 60);                // from the main loop
//! let done: Result<(), std::io::Error> = dokkit::job("nightly-purge", |run| { run.progress(4000, Some(9000)); Ok(()) });
//! dokkit::check("queue-age", "degraded", Some(14.0), Some("oldest item is 14 minutes old"));
//! if let Err(error) = done { dokkit::capture(&error); }
//! ```
//!
//! Nothing here panics into the app or waits on the network. Lines wait in a queue of fixed
//! size and a thread sends them. Error message text is never sent. Lines carry no time of
//! their own: the server stamps them when they arrive, at most two seconds later.

use std::collections::hash_map::RandomState;
use std::collections::VecDeque;
use std::hash::{BuildHasher, Hasher};
use std::panic::Location;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const QUEUE: usize = 1000;
const MAX_BYTES: usize = 8 << 20;
const MAX_LINE: usize = 1 << 20;
const MAX_BATCH: usize = 4 << 20; // the server refuses an unzipped batch over 5 MB

/// What one request carries. One that fails is kept for a second try.
struct Batch {
    path: &'static str,
    items: Vec<String>,
    id: String,
    tried: bool,
}

struct State {
    url: String,
    key: String,
    version: String,
    environment: Option<String>,
    host: String,
    lines: VecDeque<String>,
    errors: VecDeque<String>,
    bytes: usize,
    held: Option<Batch>,
    dropped: usize,
}

static FLUSHING: Mutex<()> = Mutex::new(());

// Set once catch_unhandled is on: the hook reports panics, so job does not.
static HOOKED: AtomicBool = AtomicBool::new(false);

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

#[cfg(feature = "log")]
thread_local!(static SENDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) });

/// One value in a line. `None` is left out of the line.
#[derive(Clone)]
enum J<'a> {
    S(&'a str),
    N(f64),
    I(i64),
    B(bool),
    Raw(String),
    None,
}

fn text(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' | '\\' => {
                out.push('\\');
                out.push(c)
            }
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out + "\""
}

fn object(pairs: &[(&str, J)]) -> String {
    let fields: Vec<String> = pairs
        .iter()
        .filter_map(|(name, value)| {
            let value = match value {
                J::S(s) => text(s),
                J::N(n) if n.is_finite() => n.to_string(),
                J::N(_) | J::None => return None,
                J::I(i) => i.to_string(),
                J::B(b) => b.to_string(),
                J::Raw(r) => r.clone(),
            };
            Some(format!("{}:{}", text(name), value))
        })
        .collect();
    format!("{{{}}}", fields.join(","))
}

fn opt(s: Option<&str>) -> J<'_> {
    s.map_or(J::None, J::S)
}

fn id() -> String {
    let part = || RandomState::new().build_hasher().finish();
    let (a, b) = (part(), part());
    format!("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}", a >> 32, (a >> 16) & 0xffff, a & 0xffff, b >> 48, b & 0xffff_ffff_ffff)
}

// Off for an http address to another machine, unless DOKKIT_INSECURE=1.
fn secure(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix("http://") else { return true };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let authority = authority.rsplit('@').next().unwrap_or("");
    let host = if let Some(v6) = authority.strip_prefix('[') { v6.split(']').next().unwrap_or("") } else { authority.split(':').next().unwrap_or("") };
    let local = host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback());
    if local || std::env::var("DOKKIT_INSECURE").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("dokkit: off, the address is http and not this machine; use https or set DOKKIT_INSECURE=1");
    false
}

fn hostname() -> Option<String> {
    let from_file = std::fs::read_to_string("/etc/hostname").ok();
    let from_command = || std::process::Command::new("hostname").output().ok().and_then(|o| String::from_utf8(o.stdout).ok());
    from_file.or_else(from_command).map(|h| h.trim().to_string()).filter(|h| !h.is_empty())
}

/// Turns the library on. With no address or key it stays off and every call does nothing.
pub fn start(version: &str) {
    let var = |name| std::env::var(name).unwrap_or_default();
    start_with(version, &var("DOKKIT_URL"), &var("DOKKIT_KEY"));
}

/// `start` with the address and key given instead of read from the environment.
pub fn start_with(version: &str, url: &str, key: &str) {
    if url.is_empty() || key.is_empty() || !secure(url) {
        return;
    }
    let var = |name| std::env::var(name).ok().filter(|v| !v.is_empty());
    let state = State {
        url: url.trim_end_matches('/').to_string(),
        key: key.to_string(),
        version: version.to_string(),
        environment: var("DOKKIT_ENV"),
        host: var("COMPUTERNAME").or(var("HOSTNAME")).or_else(hostname).unwrap_or_else(|| "unknown".into()),
        lines: VecDeque::new(),
        errors: VecDeque::new(),
        bytes: 0,
        held: None,
        dropped: 0,
    };
    if STATE.set(Mutex::new(state)).is_err() {
        return;
    }
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(2));
        flush();
    });
    if !version.is_empty() {
        add("deploy", &[("version", J::S(version))]);
    }
}

fn add(kind: &str, pairs: &[(&str, J)]) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };
    let line = object(&[("type", J::S(kind)), ("host", J::S(&s.host))]);
    let more = object(pairs);
    // Two objects joined into one.
    let line = if more.len() > 2 { format!("{},{}", &line[..line.len() - 1], &more[1..]) } else { line };
    if line.len() > MAX_LINE {
        s.dropped += 1;
        return;
    }
    while !s.lines.is_empty() && (s.lines.len() >= QUEUE || s.bytes + line.len() > MAX_BYTES) {
        let old = s.lines.pop_front().map_or(0, |l| l.len());
        s.bytes -= old;
        s.dropped += 1;
    }
    s.bytes += line.len();
    s.lines.push_back(line);
}

/// How many lines were dropped: the queue was full, or they could not be sent.
pub fn dropped() -> usize {
    STATE.get().and_then(|s| s.lock().ok().map(|s| s.dropped)).unwrap_or(0)
}

/// Says the app is alive. Call it from the main loop.
pub fn beat(name: &str, every_seconds: i64) {
    add("beat", &[("name", J::S(name)), ("every_seconds", J::I(every_seconds))]);
}

/// One of the app's own checks. `state` is "ok", "degraded" or "down".
pub fn check(name: &str, state: &str, value: Option<f64>, note: Option<&str>) {
    add("custom", &[("check", J::S(name)), ("state", J::S(state)), ("value", value.map_or(J::None, J::N)), ("note", opt(note))]);
}

pub fn metric(name: &str, value: f64, unit: Option<&str>) {
    add("metric", &[("name", J::S(name)), ("value", J::N(value)), ("unit", opt(unit))]);
}

/// `level` is trace, debug, info, warn, error or fatal.
pub fn log(level: &str, msg: &str) {
    add("log", &[("level", J::S(level)), ("msg", J::S(msg))]);
}

/// For the `log` crate, with the `log` feature: `log::set_logger(&dokkit::Logger)`, then `log::set_max_level(...)`.
#[cfg(feature = "log")]
pub struct Logger;

#[cfg(feature = "log")]
impl ::log::Log for Logger {
    fn enabled(&self, _: &::log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &::log::Record) {
        // The sender and this crate log about their own requests; never feed those back.
        let target = record.target();
        if STATE.get().is_none() || SENDING.with(|s| s.get()) || ["ureq", "rustls", "dokkit"].iter().any(|t| target.starts_with(t)) {
            return;
        }
        let level = match record.level() {
            ::log::Level::Error => "error",
            ::log::Level::Warn => "warn",
            ::log::Level::Info => "info",
            ::log::Level::Debug => "debug",
            ::log::Level::Trace => "trace",
        };
        log(level, &record.args().to_string());
    }

    fn flush(&self) {}
}

/// Sends a stats document already written as JSON, for an app dokkit cannot reach.
pub fn stats(document_json: &str) {
    add("stats", &[("document", J::Raw(document_json.replace(['\r', '\n'], " ")))]);
}

/// One run of a job.
pub struct Run {
    name: String,
    id: String,
}

impl Run {
    fn send(&self, event: &str, more: &[(&str, J)]) {
        let mut pairs = vec![("name", J::S(&self.name)), ("run", J::S(&self.id)), ("event", J::S(event))];
        pairs.extend(more.iter().cloned());
        add("job", &pairs);
    }

    pub fn progress(&self, done: i64, total: Option<i64>) {
        self.send("progress", &[("done", J::I(done)), ("total", total.map_or(J::None, J::I))]);
    }
}

/// Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns.
#[track_caller]
pub fn job<T, E: 'static>(name: &str, work: impl FnOnce(&Run) -> Result<T, E>) -> Result<T, E> {
    let (run, began, from) = (Run { name: name.to_string(), id: id() }, Instant::now(), Location::caller());
    run.send("start", &[]);
    let function = std::any::type_name_of_val(&work).trim_end_matches("::{{closure}}").to_string();
    let result = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| work(&run))) {
        Ok(result) => result,
        Err(panic) => {
            run.send("fail", &[("exit_code", J::I(1)), ("duration_ms", J::I(began.elapsed().as_millis() as i64))]);
            if !HOOKED.load(Ordering::Relaxed) {
                report("panic", false, from, Some(&function));
            }
            flush();
            std::panic::resume_unwind(panic);
        }
    };
    let took = J::I(began.elapsed().as_millis() as i64);
    match &result {
        Ok(_) => run.send("ok", &[("exit_code", J::I(0)), ("duration_ms", took)]),
        Err(_) => {
            run.send("fail", &[("exit_code", J::I(1)), ("duration_ms", took)]);
            report(std::any::type_name::<E>(), false, from, Some(&function));
        }
    }
    result
}

/// Sends an error: its type and where `capture` was called from, never its message.
#[track_caller]
pub fn capture<E: ?Sized>(_error: &E) {
    report(std::any::type_name::<E>(), true, Location::caller(), None);
}

/// Also reports panics, then lets them carry on as before.
pub fn catch_unhandled() {
    HOOKED.store(true, Ordering::Relaxed);
    let before = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(from) = info.location() {
            report("panic", false, from, None);
            flush();
        }
        before(info);
    }));
}

// The folder of a path on this machine is not sent. A crate or the standard library keeps its
// crate-relative path; any other absolute path is cut to the file name.
fn relative(file: &str) -> String {
    let f = file.replace('\\', "/");
    if let Some(i) = f.find("/registry/src/") {
        if let Some((_, rest)) = f[i + 14..].split_once('/') {
            return rest.to_string();
        }
    }
    if let Some((_, rest)) = f.strip_prefix("/rustc/").and_then(|r| r.split_once('/')) {
        return rest.to_string();
    }
    if f.starts_with('/') || f.as_bytes().get(1) == Some(&b':') {
        return f.rsplit('/').next().unwrap_or(&f).to_string();
    }
    file.to_string()
}

// Rust keeps no stack with an error, so the report has one frame: where it was reported from.
// The function is known only for a job, from the type of its closure.
fn report(kind: &str, handled: bool, from: &Location, function: Option<&str>) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };
    if s.errors.len() >= 100 {
        return;
    }
    let file = from.file();
    let own = !(file.contains("/registry/src/") || file.contains("\\registry\\src\\") || file.starts_with("/rustc/"));
    let frame = object(&[("file", J::S(&relative(file))), ("function", opt(function)), ("line", J::I(from.line() as i64)), ("own", J::B(own))]);
    let report = object(&[
        ("type", J::S(kind)),
        ("handled", J::B(handled)),
        ("release", J::S(&s.version)),
        ("environment", opt(s.environment.as_deref())),
        ("host", J::S(&s.host)),
        ("frames", J::Raw(format!("[{frame}]"))),
        ("tags", J::Raw("{}".into())),
    ]);
    s.errors.push_back(report);
}

/// Sends what is waiting. Call it before the app exits.
pub fn flush() {
    let Some(state) = STATE.get() else { return };
    let Ok(_flushing) = FLUSHING.lock() else { return };
    loop {
        let (url, key, mut batch) = {
            let Ok(mut s) = state.lock() else { return };
            let batch = match s.held.take() {
                Some(held) => held,
                None => match s.errors.pop_front() {
                    Some(error) => Batch { path: "/api/v1/errors", items: vec![error], id: id(), tried: false },
                    None => {
                        let (mut n, mut size) = (0, 0);
                        while n < s.lines.len() && n < 500 && (n == 0 || size + s.lines[n].len() <= MAX_BATCH) {
                            size += s.lines[n].len();
                            n += 1;
                        }
                        s.bytes -= size;
                        Batch { path: "/api/v1/report", items: s.lines.drain(..n).collect(), id: id(), tried: false }
                    }
                },
            };
            (s.url.clone(), s.key.clone(), batch)
        };
        if batch.items.is_empty() {
            return;
        }
        let (kind, body) = if batch.path == "/api/v1/errors" { ("application/json", batch.items[0].clone()) } else { ("application/x-ndjson", batch.items.join("\n")) };
        #[cfg(feature = "log")]
        SENDING.with(|s| s.set(true));
        let sent = ureq::post(&format!("{url}{}", batch.path))
            .timeout(Duration::from_secs(10))
            .set("Authorization", &format!("Bearer {key}"))
            .set("Content-Type", kind)
            .set("Dokkit-Batch", &batch.id)
            .send_string(&body);
        #[cfg(feature = "log")]
        SENDING.with(|s| s.set(false));
        // A refusal is counted and not retried. An unreachable server or a server error is retried
        // once, except an error post, which the server would count twice.
        if let Err(ureq::Error::Status(code, _)) = &sent {
            if *code < 500 {
                let Ok(mut s) = state.lock() else { return };
                s.dropped += batch.items.len();
                continue;
            }
        }
        if sent.is_err() {
            let Ok(mut s) = state.lock() else { return };
            if batch.tried || batch.path == "/api/v1/errors" {
                s.dropped += batch.items.len();
            } else {
                batch.tried = true;
                s.held = Some(batch);
            }
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_or_this_machine() {
        assert!(secure("https://dokkit.example.com") && secure("http://localhost:4000") && secure("http://127.0.0.1:4000/") && secure("http://[::1]:4000"));
        assert!(!secure("http://dokkit.example.com:4000"));
        for bad in ["http://127.0.0.1.example.com", "http://127.example.com", "http://localhost:x@other.example.com/", "HTTP://other.example.com"] {
            assert!(!secure(bad), "{bad}");
        }
        assert!(secure("HTTP://LOCALHOST:4000"));
    }

    #[cfg(unix)]
    #[test]
    fn hostname_is_found() {
        assert!(hostname().is_some());
    }

    #[test]
    fn paths_lose_their_folders() {
        assert_eq!(relative("/home/bob/.cargo/registry/src/index.crates.io-1/ureq-2.9.0/src/lib.rs"), "ureq-2.9.0/src/lib.rs");
        assert_eq!(relative("/rustc/abc123/library/core/src/mod.rs"), "library/core/src/mod.rs");
        assert_eq!(relative("/home/bob/app/a.rs"), "a.rs");
        assert_eq!(relative(r"C:\Users\bob\a.rs"), "a.rs");
        assert_eq!(relative("src/main.rs"), "src/main.rs");
    }

    #[test]
    fn a_full_queue_drops_the_oldest_and_counts_it() {
        let state = State { url: String::new(), key: String::new(), version: String::new(), environment: None, host: "h".into(), lines: VecDeque::new(), errors: VecDeque::new(), bytes: 0, held: None, dropped: 0 };
        let _ = STATE.set(Mutex::new(state));
        let big = "x".repeat(900 << 10);
        for _ in 0..12 {
            log("info", &big);
        }
        let s = STATE.get().unwrap().lock().unwrap();
        assert!(s.bytes <= MAX_BYTES && s.dropped > 0);
    }
}
