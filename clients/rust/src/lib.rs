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
//!
//! `start_manual` starts no thread: lines wait until the app calls `flush`, which sends them on its own thread.

use std::collections::hash_map::RandomState;
use std::collections::VecDeque;
use std::hash::{BuildHasher, Hasher};
use std::panic::Location;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ureq::config::Config;
use ureq::http::Uri;
use ureq::unversioned::resolver::{DefaultResolver, ResolvedSocketAddrs, Resolver};
use ureq::unversioned::transport::{DefaultConnector, NextTimeout};

const QUEUE: usize = 1000;
const BATCH: usize = 500; // lines that wake the sender before its interval is up
const DEFAULT_MS: u64 = 2000;
const MIN_MS: u64 = 100;
const MAX_BYTES: usize = 8 << 20;
const MAX_LINE: usize = 65536;
const MAX_BATCH: usize = 4 << 20; // the server refuses an unzipped batch over 5 MB

/// What one request carries. One that fails is kept for a second try.
struct Batch {
    items: Vec<String>,
    id: String,
    tried: bool,
}

struct State {
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

/// Where lines and error reports go, and the Authorization header, made once at start.
struct Address {
    report: String,
    errors: String,
    auth: String,
}

static ADDRESS: OnceLock<Address> = OnceLock::new();

// Set by `start_manual`: no sender thread, `flush` sends on the caller's thread.
static MANUAL: AtomicBool = AtomicBool::new(false);

type Found = Arc<Mutex<Option<(String, ResolvedSocketAddrs)>>>;

/// The address a name resolved to, kept until a connection fails.
#[derive(Debug)]
struct Cached<R> {
    inner: R,
    found: Found,
}

impl<R: Resolver> Resolver for Cached<R> {
    fn resolve(&self, uri: &Uri, config: &Config, timeout: NextTimeout) -> Result<ResolvedSocketAddrs, ureq::Error> {
        let name = uri.authority().map(|a| a.as_str().to_string()).unwrap_or_default();
        let mut found = self.found.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((was, addresses)) = &*found {
            if *was == name {
                return Ok(addresses.clone());
            }
        }
        let addresses = self.inner.resolve(uri, config, timeout)?;
        *found = Some((name, addresses.clone()));
        Ok(addresses)
    }
}

/// One agent for the process: its pool keeps a connection between sends, and its TLS config
/// keeps the session tickets, so a reconnect resumes instead of a full handshake.
struct Net {
    agent: ureq::Agent,
    found: Found,
    manual: bool,
    limit: Duration,
}

// The longest one request may take: the flush timeout in manual mode, else 10 seconds.
fn limit(manual: bool) -> Duration {
    if manual { Duration::from_millis(FLUSH_MS.load(Ordering::Relaxed)) } else { Duration::from_secs(10) }
}

impl Net {
    // Manual mode keeps no idle connection between flushes: the server closes one idle for a minute.
    fn new(resolver: impl Resolver, manual: bool) -> Net {
        Net::with_tls(resolver, manual, ureq::tls::TlsConfig::default())
    }

    // The timeout is set on the agent: ureq builds a new TLS config, with an empty session cache,
    // for every connection of a request that sets its own.
    fn with_tls(resolver: impl Resolver, manual: bool, tls: ureq::tls::TlsConfig) -> Net {
        let found: Found = Arc::new(Mutex::new(None));
        let limit = limit(manual);
        // ureq's 128 KB buffers, two per layer, were most of what each new connection allocated;
        // 16 KB holds a TLS record and the server's small replies.
        let mut config = ureq::Agent::config_builder()
            .timeout_global(Some(limit))
            .tls_config(tls)
            .input_buffer_size(16 << 10)
            .output_buffer_size(16 << 10);
        if manual {
            config = config.max_idle_connections(0);
        }
        let agent = ureq::Agent::with_parts(config.build(), DefaultConnector::default(), Cached { inner: resolver, found: found.clone() });
        Net { agent, found, manual, limit }
    }

    fn forget(&self) {
        *self.found.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

// Built at the first send, so start does no network or TLS setup.
static NET: OnceLock<Net> = OnceLock::new();

fn net() -> &'static Net {
    NET.get_or_init(|| Net::new(DefaultResolver::default(), MANUAL.load(Ordering::Relaxed)))
}

static ENVIRONMENT: Mutex<Option<String>> = Mutex::new(None);

static ANNOUNCE: AtomicBool = AtomicBool::new(true);

static FLUSH_MS: AtomicU64 = AtomicU64::new(5000);

// 0 until `start` or `set_interval` decides: DOKKIT_INTERVAL_SECS, else 2 seconds.
static INTERVAL_MS: AtomicU64 = AtomicU64::new(0);

// True when the sender should send now; `set_interval` only wakes it to move its deadline.
static SEND_NOW: Mutex<bool> = Mutex::new(false);
static WOKEN: Condvar = Condvar::new();

fn wake(send: bool) {
    let mut now = SEND_NOW.lock().unwrap_or_else(|e| e.into_inner());
    *now |= send;
    drop(now);
    WOKEN.notify_one();
}

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
    begin(version, &var("DOKKIT_URL"), &var("DOKKIT_KEY"), false);
}

/// `start` with the address and key given instead of read from the environment.
pub fn start_with(version: &str, url: &str, key: &str) {
    begin(version, url, key, false);
}

/// `start` with no sender thread and no work between calls, for a small resident service. Lines wait in memory and `flush` sends them on the caller's thread; so does the retry of a failed batch, and the version is announced on the first `flush`. See the README for how often to call it.
pub fn start_manual(version: &str) {
    let var = |name| std::env::var(name).unwrap_or_default();
    begin(version, &var("DOKKIT_URL"), &var("DOKKIT_KEY"), true);
}

/// `start_manual` with the address and key given instead of read from the environment.
pub fn start_manual_with(version: &str, url: &str, key: &str) {
    begin(version, url, key, true);
}

fn begin(version: &str, url: &str, key: &str, manual: bool) {
    if url.is_empty() || key.is_empty() || !secure(url) {
        return;
    }
    let var = |name| std::env::var(name).ok().filter(|v| !v.is_empty());
    let state = State {
        version: version.to_string(),
        environment: ENVIRONMENT.lock().ok().and_then(|e| e.clone()).or_else(|| var("DOKKIT_ENV")),
        host: var("COMPUTERNAME").or(var("HOSTNAME")).unwrap_or_default(),
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
    let url = url.trim_end_matches('/');
    let _ = ADDRESS.set(Address { report: format!("{url}/api/v1/report"), errors: format!("{url}/api/v1/errors"), auth: format!("Bearer {key}") });
    if manual {
        MANUAL.store(true, Ordering::Relaxed);
        return;
    }
    if INTERVAL_MS.load(Ordering::Relaxed) == 0 {
        let secs = var("DOKKIT_INTERVAL_SECS").and_then(|v| v.parse::<f64>().ok()).filter(|s| s.is_finite() && *s > 0.0);
        let ms = secs.map_or(DEFAULT_MS, |s| (s * 1000.0) as u64).max(MIN_MS);
        let _ = INTERVAL_MS.compare_exchange(0, ms, Ordering::Relaxed, Ordering::Relaxed);
    }
    std::thread::spawn(sender);
}

/// How long the sender waits between sends when nothing wakes it earlier, 2 seconds unless set (or DOKKIT_INTERVAL_SECS, read by `start`). A full batch of lines, an error report, a check that is not "ok" and `flush` send at once whatever this is. The shortest is 100 ms.
pub fn set_interval(every: Duration) {
    INTERVAL_MS.store((every.as_millis() as u64).max(MIN_MS), Ordering::Relaxed);
    wake(false);
}

fn interval() -> Duration {
    Duration::from_millis(match INTERVAL_MS.load(Ordering::Relaxed) {
        0 => DEFAULT_MS,
        ms => ms,
    })
}

// The version still to announce, or a failed send to retry, is due within two seconds.
fn soon() -> bool {
    STATE.get().is_some_and(|s| s.lock().is_ok_and(|s| s.announce || s.held.is_some() || !s.errors.is_empty()))
}

// Sleeps until a batch is full, an error is reported, a check goes bad, the interval is up, or a retry is due. An idle pass allocates nothing.
fn sender() {
    let mut last = Instant::now();
    loop {
        let mut now = SEND_NOW.lock().unwrap_or_else(|e| e.into_inner());
        while !*now {
            let wait = if soon() { interval().min(Duration::from_millis(DEFAULT_MS)) } else { interval() };
            let left = (last + wait).saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            now = WOKEN.wait_timeout(now, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        *now = false;
        drop(now);
        send_all();
        last = Instant::now();
    }
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

// The hostname is looked up when the first line or report needs it, not at start.
fn host_known(s: &mut State) {
    if s.host.is_empty() {
        s.host = hostname().unwrap_or_else(|| "unknown".into());
    }
}

fn add(kind: &str, pairs: &[(&str, J)]) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };
    host_known(&mut s);
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
    if s.lines.len() == BATCH {
        drop(s);
        wake(true);
    }
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
    if state != "ok" {
        wake(true);
    }
}

pub fn metric(name: &str, value: f64, unit: Option<&str>) {
    add("metric", &[("name", J::S(name)), ("value", J::N(value)), ("unit", opt(unit))]);
}

/// For an app that installs others: `service` went onto this host at `version`. Dokkit has to let the app deploy others.
pub fn deploy(service: &str, version: &str) {
    add("deploy", &[("service", J::S(service)), ("version", J::S(version))]);
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
    host_known(&mut s);
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
    drop(s);
    wake(true);
}

/// Sends what is waiting and returns after at most 5 seconds, or what `flush_timeout` set. Call it before the app exits. After `start_manual` it sends on the calling thread, each request taking at most that long.
pub fn flush() {
    if STATE.get().is_none() {
        return;
    }
    if MANUAL.load(Ordering::Relaxed) {
        send_all();
        return;
    }
    let (done, wait) = std::sync::mpsc::channel();
    let sender = std::thread::Builder::new().spawn(move || {
        send_all();
        wake(false);
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
    let announce = {
        let Ok(mut s) = state.lock() else { return };
        if s.lines.is_empty() && s.errors.is_empty() && s.held.is_none() && !s.announce {
            return;
        }
        std::mem::take(&mut s.announce).then(|| s.version.clone())
    };
    if let Some(version) = announce {
        add("deploy", &[("version", J::S(&version))]);
    }
    while send_lines(state) {}
    while send_error(state) {}
}

fn post(net: &Net, url: &str, auth: &str, kind: &str, id: &str, body: &str) -> Sent {
    #[cfg(feature = "log")]
    SENDING.with(|s| s.set(true));
    let mut request = net.agent.post(url);
    let limit = limit(net.manual);
    if limit != net.limit {
        request = request.config().timeout_global(Some(limit)).build();
    }
    let sent = request.header("Authorization", auth).header("Content-Type", kind).header("Dokkit-Batch", id).send(body);
    #[cfg(feature = "log")]
    SENDING.with(|s| s.set(false));
    outcome(net, sent.map(|_| ()))
}

// A status error means the connection worked; any other error forgets the resolved address.
fn outcome(net: &Net, sent: Result<(), ureq::Error>) -> Sent {
    match sent {
        Ok(()) => Sent::Taken,
        Err(ureq::Error::StatusCode(code)) if code < 500 && code != 429 => Sent::Refused,
        Err(ureq::Error::StatusCode(_)) => Sent::Failed,
        Err(_) => {
            net.forget();
            Sent::Failed
        }
    }
}

// Sends the held batch or the next one, and says whether to go on. A batch that fails is held
// for one more try, then counted as dropped.
fn send_lines(state: &Mutex<State>) -> bool {
    let Some(to) = ADDRESS.get() else { return false };
    let mut batch = {
        let Ok(mut s) = state.lock() else { return false };
        match s.held.take() {
            Some(held) => held,
            None => {
                let (mut n, mut size) = (0, 0);
                while n < s.lines.len() && n < 500 && (n == 0 || size + s.lines[n].len() <= MAX_BATCH) {
                    size += s.lines[n].len();
                    n += 1;
                }
                s.bytes -= size;
                Batch { items: s.lines.drain(..n).collect(), id: id(), tried: false }
            }
        }
    };
    if batch.items.is_empty() {
        return false;
    }
    let result = post(net(), &to.report, &to.auth, "application/x-ndjson", &batch.id, &batch.items.join("\n"));
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
    let Some(to) = ADDRESS.get() else { return false };
    let body = {
        let Ok(s) = state.lock() else { return false };
        match s.errors.front() {
            Some(error) => error.clone(),
            None => return false,
        }
    };
    let result = post(net(), &to.errors, &to.auth, "application/json", &id(), &body);
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

    #[derive(Debug)]
    struct Counting(Arc<std::sync::atomic::AtomicUsize>);

    impl Resolver for Counting {
        fn resolve(&self, _: &Uri, _: &Config, _: NextTimeout) -> Result<ResolvedSocketAddrs, ureq::Error> {
            self.0.fetch_add(1, Ordering::Relaxed);
            let mut found = DefaultResolver::default().empty();
            found.push(std::net::SocketAddr::from(([127, 0, 0, 1], 4000)));
            Ok(found)
        }
    }

    #[test]
    fn the_address_is_looked_up_once_and_again_only_after_a_connection_error() {
        let asked = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let net = Net::new(Counting(asked.clone()), false);
        let cached = Cached { inner: Counting(asked.clone()), found: net.found.clone() };
        let (config, uri) = (Config::default(), Uri::from_static("https://localhost:4000"));
        let lookup = |c: &Cached<Counting>| c.resolve(&uri, &config, NextTimeout::default()).unwrap();
        assert_eq!(lookup(&cached).len(), 1);
        lookup(&cached);
        assert_eq!(asked.load(Ordering::Relaxed), 1, "the name was looked up for every call");
        assert!(matches!(outcome(&net, Err(ureq::Error::StatusCode(500))), Sent::Failed));
        assert!(matches!(outcome(&net, Err(ureq::Error::StatusCode(404))), Sent::Refused));
        lookup(&cached);
        assert_eq!(asked.load(Ordering::Relaxed), 1, "a status error cleared the address");
        assert!(matches!(outcome(&net, Err(ureq::Error::ConnectionFailed)), Sent::Failed));
        lookup(&cached);
        assert_eq!(asked.load(Ordering::Relaxed), 2, "a connection error did not force a new lookup");
    }

    #[derive(Debug)]
    struct Local(u16);

    impl Resolver for Local {
        fn resolve(&self, _: &Uri, _: &Config, _: NextTimeout) -> Result<ResolvedSocketAddrs, ureq::Error> {
            let mut found = DefaultResolver::default().empty();
            found.push(std::net::SocketAddr::from(([127, 0, 0, 1], self.0)));
            Ok(found)
        }
    }

    // A TLS 1.3 server that issues tickets and answers each request with 200, reporting how each connection's handshake went.
    fn ticket_server(connections: usize) -> (u16, ureq::tls::Certificate<'static>, std::sync::mpsc::Receiver<rustls::HandshakeKind>) {
        use std::io::{Read, Write};
        let made = rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
        let key = rustls::pki_types::PrivateKeyDer::Pkcs8(made.signing_key.serialize_der().into());
        let mut config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![made.cert.der().clone()], key)
            .unwrap();
        config.ticketer = rustls::crypto::ring::Ticketer::new().unwrap();
        let config = Arc::new(config);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tell, told) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for socket in listener.incoming().take(connections) {
                let mut tls = rustls::StreamOwned::new(rustls::ServerConnection::new(config.clone()).unwrap(), socket.unwrap());
                let (mut got, mut buf) = (Vec::new(), [0; 4096]);
                // The whole request, body too: Windows resets a socket closed with bytes unread, and the reset can beat the reply.
                while !got.ends_with(b"\r\n\r\n{}") {
                    match tls.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => got.extend_from_slice(&buf[..n]),
                    }
                }
                let _ = tell.send(tls.conn.handshake_kind().unwrap());
                let _ = tls.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n");
                let _ = tls.flush();
                while matches!(tls.read(&mut buf), Ok(n) if n > 0) {}
            }
        });
        (port, ureq::tls::Certificate::from_der(made.cert.der()).to_owned(), told)
    }

    #[test]
    fn a_reconnect_resumes_the_tls_session_instead_of_a_full_handshake() {
        let (port, cert, told) = ticket_server(4);
        let tls = ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::new_with_certs(&[cert])).build();
        let net = Net::with_tls(Local(port), true, tls);
        let url = format!("https://localhost:{port}/api/v1/report");
        let send = || assert!(matches!(post(&net, &url, "Bearer k", "application/x-ndjson", "1", "{}"), Sent::Taken));
        let kinds: Vec<_> = (0..3)
            .map(|_| {
                send();
                told.recv().unwrap()
            })
            .collect();
        assert_eq!(kinds, [rustls::HandshakeKind::Full, rustls::HandshakeKind::Resumed, rustls::HandshakeKind::Resumed]);
        // A flush timeout changed after the first send still applies, and still resumes: the agent's TLS config is cached by then.
        let was = FLUSH_MS.swap(FLUSH_MS.load(Ordering::Relaxed) + 1, Ordering::Relaxed);
        send();
        FLUSH_MS.store(was, Ordering::Relaxed);
        assert_eq!(told.recv().unwrap(), rustls::HandshakeKind::Resumed);
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
        let state = State { version: String::new(), environment: None, host: "h".into(), lines: VecDeque::new(), errors: VecDeque::new(), bytes: 0, held: None, dropped: 0, announce: false };
        let _ = STATE.set(Mutex::new(state));
        let big = "x".repeat(60 << 10);
        for _ in 0..200 {
            log("info", &big);
        }
        let s = STATE.get().unwrap().lock().unwrap();
        assert!(s.bytes <= MAX_BYTES && s.dropped > 0);
    }
}
