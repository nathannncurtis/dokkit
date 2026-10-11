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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const QUEUE: usize = 1000;
const MAX_BYTES: usize = 8 << 20;
const MAX_LINE: usize = 65536;
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
    announce: bool,
}

static FLUSHING: Mutex<()> = Mutex::new(());

static ENVIRONMENT: Mutex<Option<String>> = Mutex::new(None);

static ANNOUNCE: AtomicBool = AtomicBool::new(true);

static FLUSH_MS: AtomicU64 = AtomicU64::new(5000);

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
        environment: ENVIRONMENT.lock().ok().and_then(|e| e.clone()).or_else(|| var("DOKKIT_ENV")),
        host: var("COMPUTERNAME").or(var("HOSTNAME")).or_else(hostname).unwrap_or_else(|| "unknown".into()),
        lines: VecDeque::new(),
        errors: VecDeque::new(),
        bytes: 0,
        held: None,
        dropped: 0,
        announce: ANNOUNCE.load(Ordering::Relaxed) && !version.is_empty(),
    };
    if STATE.set(Mutex::new(state)).is_err() {
        return;
    }
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(2));
        send_all();
    });
}

/// `announce_version(false)`, called before `start`, stops the deploy line `start` sends with the version. The server records a deploy only when the version changes.
pub fn announce_version(on: bool) {
    ANNOUNCE.store(on, Ordering::Relaxed);
}

/// Names the environment, called before `start`; DOKKIT_ENV is used when this is not. Any value but "production" is on every line sent.
pub fn environment(name: &str) {
    if let Ok(mut e) = ENVIRONMENT.lock() {
        *e = Some(name.to_string());
    }
}

/// The longest `flush` waits for the server, 5 seconds unless set.
pub fn flush_timeout(wait: Duration) {
    FLUSH_MS.store(wait.as_millis() as u64, Ordering::Relaxed);
}

fn line_of(kind: &str, host: &str, environment: Option<&str>, pairs: &[(&str, J)]) -> String {
    let environment = environment.filter(|e| *e != "production");
    let line = object(&[("type", J::S(kind)), ("host", J::S(host)), ("environment", opt(environment))]);
    let more = object(pairs);
    // Two objects joined into one.
    if more.len() > 2 { format!("{},{}", &line[..line.len() - 1], &more[1..]) } else { line }
}

// A line over the limit loses the end of its msg, then its fields. One with no msg is dropped.
fn cut(kind: &str, host: &str, environment: Option<&str>, pairs: &[(&str, J)]) -> Option<String> {
    let msg = pairs.iter().find_map(|(name, value)| match (*name, value) {
        ("msg", J::S(m)) => Some(*m),
        _ => None,
    })?;
    let (mut fields, mut end) = (true, msg.len());
    loop {
        let shorter = format!("{} [cut]", &msg[..end]);
        let kept: Vec<(&str, J)> = pairs
            .iter()
            .map(|(name, value)| match *name {
                "msg" => (*name, J::S(&shorter)),
                "fields" if !fields => (*name, J::None),
                _ => (*name, value.clone()),
            })
            .collect();
        let line = line_of(kind, host, environment, &kept);
        if line.len() <= MAX_LINE {
            return Some(line);
        }
        if end == 0 {
            if !fields {
                return None;
            }
            (fields, end) = (false, msg.len());
            continue;
        }
        end = end.saturating_sub(line.len() - MAX_LINE);
        while !msg.is_char_boundary(end) {
            end -= 1;
        }
    }
}

fn add(kind: &str, pairs: &[(&str, J)]) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };
    let mut line = line_of(kind, &s.host, s.environment.as_deref(), pairs);
    if line.len() > MAX_LINE {
        match cut(kind, &s.host, s.environment.as_deref(), pairs) {
            Some(shorter) => line = shorter,
            None => {
                s.dropped += 1;
                return;
            }
        }
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

/// A value in a log line's fields.
pub enum Value {
    Str(String),
    Int(i64),
    Num(f64),
    Bool(bool),
}

impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Str(v.to_string())
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Str(v)
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v)
    }
}
impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::Int(v.into())
    }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::Num(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}

/// `log` with fields, sent as a flat object: `log_fields("info", "paid", &[("order", 42.into())])`.
pub fn log_fields(level: &str, msg: &str, fields: &[(&str, Value)]) {
    let pairs: Vec<(&str, J)> = fields
        .iter()
        .map(|(name, value)| {
            let value = match value {
                Value::Str(s) => J::S(s),
                Value::Int(i) => J::I(*i),
                Value::Num(n) => J::N(*n),
                Value::Bool(b) => J::B(*b),
            };
            (*name, value)
        })
        .collect();
    add("log", &[("level", J::S(level)), ("msg", J::S(msg)), ("fields", if pairs.is_empty() { J::None } else { J::Raw(object(&pairs)) })]);
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
        // Whatever is logged on the sending thread, such as ureq's own lines, is not fed back in.
        if STATE.get().is_none() || SENDING.with(|s| s.get()) {
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
                report("panic", false, from, Some(&function), false);
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
            report(std::any::type_name::<E>(), false, from, Some(&function), false);
        }
    }
    result
}

/// Sends an error: its type and where `capture` was called from, never its message.
#[track_caller]
pub fn capture<E: ?Sized>(_error: &E) {
    report(std::any::type_name::<E>(), true, Location::caller(), None, false);
}

/// Also reports panics as errors of type "panic", with the stack, never the message, then lets them carry on as before.
pub fn catch_unhandled() {
    HOOKED.store(true, Ordering::Relaxed);
    let before = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(from) = info.location() {
            report("panic", false, from, None, true);
            flush();
        }
        before(info);
    }));
}

// The folder of a path on this machine is not sent. A crate or the standard library keeps its
// crate-relative path; a file under the working directory (the app's folder) is relative to it;
// any other absolute path is cut to the file name.
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
        if let Some(dir) = std::env::current_dir().ok().map(|d| d.to_string_lossy().replace('\\', "/")) {
            if let Some(rest) = f.strip_prefix(&format!("{}/", dir.trim_end_matches('/'))) {
                return rest.to_string();
            }
        }
        return f.rsplit('/').next().unwrap_or(&f).to_string();
    }
    file.to_string()
}

fn is_own(file: &str) -> bool {
    let f = file.replace('\\', "/");
    !(f.contains("/registry/src/") || f.contains("/rustc/"))
}

fn frame(file: &str, function: Option<&str>, line: i64) -> String {
    object(&[("file", J::S(&relative(file))), ("function", opt(function)), ("line", J::I(line)), ("own", J::B(is_own(file)))])
}

// The frames of a backtrace, innermost last, from its text: "N: function" then "at file:line:col".
fn backtrace_frames() -> Vec<String> {
    let text = std::backtrace::Backtrace::force_capture().to_string();
    let (mut frames, mut function) = (Vec::new(), None::<String>);
    for row in text.lines().map(str::trim) {
        if let Some((n, name)) = row.split_once(": ") {
            if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) {
                let name = name.rsplit_once("::h").filter(|(_, h)| h.len() == 16).map_or(name, |(head, _)| head);
                function = Some(name.to_string());
                continue;
            }
        }
        if let Some(at) = row.strip_prefix("at ") {
            let (mut file, mut numbers) = (at, Vec::new());
            while let Some((head, tail)) = file.rsplit_once(':') {
                let Ok(n) = tail.parse::<i64>() else { break };
                (file, numbers) = (head, [numbers, vec![n]].concat());
            }
            if let Some(&line) = numbers.last() {
                let name = function.take();
                let machinery = name.as_deref().is_some_and(|n| ["std::panicking", "core::panicking", "std::sys", "std::backtrace", "dokkit::backtrace_frames", "dokkit::report"].iter().any(|p| n.starts_with(p)));
                if !machinery {
                    frames.push(frame(file, name.as_deref(), line));
                }
            }
        }
    }
    frames.truncate(30);
    frames.reverse();
    frames
}

// A report from `capture` has one frame, where it was reported from: Rust keeps no stack with an
// error. The function is known only for a job, from the type of its closure. A panic adds its backtrace.
fn report(kind: &str, handled: bool, from: &Location, function: Option<&str>, trace: bool) {
    let Some(state) = STATE.get() else { return };
    let mut frames = if trace { backtrace_frames() } else { Vec::new() };
    frames.push(frame(from.file(), function, from.line() as i64));
    let Ok(mut s) = state.lock() else { return };
    if s.errors.len() >= 100 {
        s.dropped += 1;
        return;
    }
    let report = object(&[
        ("type", J::S(kind)),
        ("handled", J::B(handled)),
        ("release", J::S(&s.version)),
        ("environment", opt(s.environment.as_deref())),
        ("host", J::S(&s.host)),
        ("frames", J::Raw(format!("[{}]", frames.join(",")))),
        ("tags", J::Raw("{}".into())),
    ]);
    s.errors.push_back(report);
}

/// Sends what is waiting and returns after at most 5 seconds, or what `flush_timeout` set. Call it before the app exits.
pub fn flush() {
    if STATE.get().is_none() {
        return;
    }
    let (done, wait) = std::sync::mpsc::channel();
    let sender = std::thread::Builder::new().spawn(move || {
        send_all();
        let _ = done.send(());
    });
    if sender.is_ok() {
        let _ = wait.recv_timeout(Duration::from_millis(FLUSH_MS.load(Ordering::Relaxed)));
    }
}

enum Sent {
    Taken,
    Refused,
    Failed,
}

// Lines go first: all of them fit in a few requests, and an error report is one request each.
// Neither stops the other when it fails.
fn send_all() {
    let Some(state) = STATE.get() else { return };
    let Ok(_flushing) = FLUSHING.lock() else { return };
    let announce = state.lock().ok().and_then(|mut s| std::mem::take(&mut s.announce).then(|| s.version.clone()));
    if let Some(version) = announce {
        add("deploy", &[("version", J::S(&version))]);
    }
    while send_lines(state) {}
    while send_error(state) {}
}

fn post(url: &str, key: &str, path: &str, kind: &str, id: &str, body: &str) -> Sent {
    #[cfg(feature = "log")]
    SENDING.with(|s| s.set(true));
    let sent = ureq::post(&format!("{url}{path}"))
        .timeout(Duration::from_secs(10))
        .set("Authorization", &format!("Bearer {key}"))
        .set("Content-Type", kind)
        .set("Dokkit-Batch", id)
        .send_string(body);
    #[cfg(feature = "log")]
    SENDING.with(|s| s.set(false));
    match sent {
        Ok(_) => Sent::Taken,
        Err(ureq::Error::Status(code, _)) if code < 500 && code != 429 => Sent::Refused,
        Err(_) => Sent::Failed,
    }
}

// Sends the held batch or the next one, and says whether to go on. A batch that fails is held
// for one more try, then counted as dropped.
fn send_lines(state: &Mutex<State>) -> bool {
    let (url, key, mut batch) = {
        let Ok(mut s) = state.lock() else { return false };
        let batch = match s.held.take() {
            Some(held) => held,
            None => {
                let (mut n, mut size) = (0, 0);
                while n < s.lines.len() && n < 500 && (n == 0 || size + s.lines[n].len() <= MAX_BATCH) {
                    size += s.lines[n].len();
                    n += 1;
                }
                s.bytes -= size;
                Batch { path: "/api/v1/report", items: s.lines.drain(..n).collect(), id: id(), tried: false }
            }
        };
        (s.url.clone(), s.key.clone(), batch)
    };
    if batch.items.is_empty() {
        return false;
    }
    let result = post(&url, &key, batch.path, "application/x-ndjson", &batch.id, &batch.items.join("\n"));
    let Ok(mut s) = state.lock() else { return false };
    match result {
        Sent::Taken => true,
        Sent::Failed if !batch.tried => {
            batch.tried = true;
            s.held = Some(batch);
            false
        }
        Sent::Failed => {
            s.dropped += batch.items.len();
            false
        }
        Sent::Refused => {
            s.dropped += batch.items.len();
            true
        }
    }
}

// Sends the oldest error report, and says whether to go on. One the server did not answer for
// stays for the next pass; the hundred that report keeps is the bound.
fn send_error(state: &Mutex<State>) -> bool {
    let (url, key, body) = {
        let Ok(s) = state.lock() else { return false };
        match s.errors.front() {
            Some(error) => (s.url.clone(), s.key.clone(), error.clone()),
            None => return false,
        }
    };
    let result = post(&url, &key, "/api/v1/errors", "application/json", &id(), &body);
    if matches!(result, Sent::Failed) {
        return false;
    }
    let Ok(mut s) = state.lock() else { return false };
    s.errors.pop_front();
    if matches!(result, Sent::Refused) {
        s.dropped += 1;
    }
    true
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
        let state = State { url: String::new(), key: String::new(), version: String::new(), environment: None, host: "h".into(), lines: VecDeque::new(), errors: VecDeque::new(), bytes: 0, held: None, dropped: 0, announce: false };
        let _ = STATE.set(Mutex::new(state));
        let big = "x".repeat(60 << 10);
        for _ in 0..200 {
            log("info", &big);
        }
        let s = STATE.get().unwrap().lock().unwrap();
        assert!(s.bytes <= MAX_BYTES && s.dropped > 0);
    }
}
