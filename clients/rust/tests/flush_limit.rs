mod common;

use std::time::{Duration, Instant};

#[test]
fn the_flush_gives_up_after_its_time_limit() {
    let (address, _) = common::fake(|_, _| 0);
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::catch_unhandled();
    dokkit::flush_timeout(Duration::from_millis(300));
    dokkit::log("info", "waiting");
    let began = Instant::now();
    let _ = std::panic::catch_unwind(|| panic!("boom"));
    dokkit::flush();
    assert!(began.elapsed() < Duration::from_secs(3));
}
