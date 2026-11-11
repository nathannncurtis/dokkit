mod common;

use std::time::{Duration, Instant};

#[test]
fn a_full_batch_is_sent_without_waiting_for_the_interval() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::announce_version(false);
    dokkit::set_interval(Duration::from_secs(3600));
    dokkit::start_with("1.0", &address, "dka_test");
    for _ in 0..499 {
        dokkit::log("info", "x");
    }
    std::thread::sleep(Duration::from_millis(2500));
    assert!(seen.lock().unwrap().is_empty());
    dokkit::log("info", "x");
    let began = Instant::now();
    while common::bodies(&seen, "/api/v1/report").lines().count() < 500 {
        assert!(began.elapsed() < Duration::from_secs(5), "the full batch was not sent");
        std::thread::sleep(Duration::from_millis(20));
    }
}
