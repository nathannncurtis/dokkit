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
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const QUEUE: usize = 1000;

struct State {
    url: String,
    key: String,
    version: String,
    environment: Option<String>,
    host: String,
    lines: VecDeque<String>,
    errors: VecDeque<String>,
    dropped: usize,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

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

/// Turns the library on. With no address or key it stays off and every call does nothing.
pub fn start(version: &str) {
    let var = |name| std::env::var(name).unwrap_or_default();
    start_with(version, &var("DOKKIT_URL"), &var("DOKKIT_KEY"));
}

/// `start` with the address and key given instead of read from the environment.
pub fn start_with(version: &str, url: &str, key: &str) {
    if url.is_empty() || key.is_empty() {
        return;
    }
    let var = |name| std::env::var(name).ok().filter(|v| !v.is_empty());
    let state = State {
        url: url.trim_end_matches('/').to_string(),
        key: key.to_string(),
        version: version.to_string(),
        environment: var("DOKKIT_ENV"),
        host: var("COMPUTERNAME").or(var("HOSTNAME")).unwrap_or_else(|| "unknown".into()),
        lines: VecDeque::new(),
        errors: VecDeque::new(),
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
    if s.lines.len() >= QUEUE {
        s.lines.pop_front();
        s.dropped += 1;
    }
    s.lines.push_back(line);
}

/// How many lines were dropped because the queue was full.
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

/// Sends a stats document already written as JSON, for an app dokkit cannot reach.
pub fn stats(document_json: &str) {
    add("stats", &[("document", J::Raw(document_json.to_string()))]);
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
    let result = work(&run);
    let took = J::I(began.elapsed().as_millis() as i64);
    match &result {
        Ok(_) => run.send("ok", &[("exit_code", J::I(0)), ("duration_ms", took)]),
        Err(_) => {
            run.send("fail", &[("exit_code", J::I(1)), ("duration_ms", took)]);
            report(std::any::type_name::<E>(), false, from);
        }
    }
    result
}

/// Sends an error: its type and where `capture` was called from, never its message.
#[track_caller]
pub fn capture<E: ?Sized>(_error: &E) {
    report(std::any::type_name::<E>(), true, Location::caller());
}

/// Also reports panics, then lets them carry on as before.
pub fn catch_unhandled() {
    let before = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(from) = info.location() {
            report("panic", false, from);
            flush();
        }
        before(info);
    }));
}

// Rust keeps no stack with an error, so the report has one frame: where it was reported from.
fn report(kind: &str, handled: bool, from: &Location) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };
    if s.errors.len() >= 100 {
        return;
    }
    let frame = object(&[("file", J::S(from.file())), ("function", J::S(from.file())), ("line", J::I(from.line() as i64)), ("own", J::B(true))]);
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
    loop {
        let (url, key, error, batch) = {
            let Ok(mut s) = state.lock() else { return };
            let error = s.errors.pop_front();
            let n = if error.is_some() { 0 } else { s.lines.len().min(500) };
            let batch: Vec<String> = s.lines.drain(..n).collect();
            (s.url.clone(), s.key.clone(), error, batch)
        };
        let post = |path: &str, kind: &str, body: &str| {
            // What cannot be sent is dropped. The app is never told.
            let _ = ureq::post(&format!("{url}{path}"))
                .timeout(Duration::from_secs(10))
                .set("Authorization", &format!("Bearer {key}"))
                .set("Content-Type", kind)
                .set("Dokkit-Batch", &id())
                .send_string(body);
        };
        match error {
            Some(error) => post("/api/v1/errors", "application/json", &error),
            None if !batch.is_empty() => post("/api/v1/report", "application/x-ndjson", &batch.join("\n")),
            None => return,
        }
    }
}
