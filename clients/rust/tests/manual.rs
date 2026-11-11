mod common;

use std::time::Duration;

#[cfg(target_os = "linux")]
fn threads() -> usize {
    std::fs::read_dir("/proc/self/task").unwrap().count()
}

#[test]
fn manual_mode_starts_no_thread_sends_nothing_alone_and_sends_on_the_callers_flush() {
    let (address, seen) = common::fake(|_, _| 200);
    #[cfg(target_os = "linux")]
    let before = threads();
    dokkit::start_manual_with("1.0", &address, "dka_test");
    #[cfg(target_os = "linux")]
    assert_eq!(threads(), before, "start_manual made a thread");
    dokkit::log("info", "one");
    std::thread::sleep(Duration::from_millis(2500));
    assert!(seen.lock().unwrap().is_empty(), "something was sent without a flush");
    dokkit::flush();
    let body = common::bodies(&seen, "/api/v1/report");
    assert!(body.contains("\"one\""), "{body}");
    assert!(body.contains("\"type\":\"deploy\"") && body.contains("\"version\":\"1.0\""), "the version was not announced on the first flush: {body}");
    #[cfg(target_os = "linux")]
    assert_eq!(threads(), before, "flush made a thread");
}
