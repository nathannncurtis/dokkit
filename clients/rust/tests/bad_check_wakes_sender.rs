mod common;

use std::time::{Duration, Instant};

#[test]
fn a_bad_check_is_sent_at_once_but_an_ok_check_waits_for_the_interval() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::announce_version(false);
    dokkit::set_interval(Duration::from_secs(3600));
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::check("fine", "ok", None, None);
    std::thread::sleep(Duration::from_millis(2500));
    assert!(common::bodies(&seen, "/api/v1/report").is_empty());
    dokkit::check("broken", "down", None, None);
    let began = Instant::now();
    while common::bodies(&seen, "/api/v1/report").is_empty() {
        assert!(began.elapsed() < Duration::from_secs(2), "the bad check waited for the interval");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(common::bodies(&seen, "/api/v1/report").contains("broken"));
}
