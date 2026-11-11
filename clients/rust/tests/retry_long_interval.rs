mod common;

use std::time::{Duration, Instant};

#[test]
fn a_failed_batch_is_retried_within_two_seconds_whatever_the_interval() {
    let (address, seen) = common::fake(|_, before| if before == 0 { 500 } else { 200 });
    dokkit::announce_version(false);
    dokkit::set_interval(Duration::from_secs(3600));
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::log("info", "retry me");
    dokkit::flush();
    assert_eq!(seen.lock().unwrap().len(), 1);
    let began = Instant::now();
    while seen.lock().unwrap().len() < 2 {
        assert!(began.elapsed() < Duration::from_secs(5), "no retry");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(dokkit::dropped(), 0);
    assert_eq!(common::bodies(&seen, "/api/v1/report").matches("retry me").count(), 2);
}
