mod common;

use std::time::{Duration, Instant};

#[test]
fn a_long_interval_sends_nothing_until_flushed_and_flush_delivers_at_once() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::announce_version(false);
    dokkit::set_interval(Duration::from_secs(3600));
    dokkit::start_with("1.0", &address, "dka_test");
    std::thread::sleep(Duration::from_millis(2500));
    assert!(seen.lock().unwrap().is_empty(), "an idle sender made a request");
    dokkit::log("info", "one");
    dokkit::set_interval(Duration::from_secs(3600));
    std::thread::sleep(Duration::from_millis(2500));
    assert!(seen.lock().unwrap().is_empty(), "a line was sent before the interval or a flush");
    let began = Instant::now();
    dokkit::flush();
    assert!(began.elapsed() < Duration::from_secs(2));
    assert!(common::bodies(&seen, "/api/v1/report").contains("\"one\""));
}
