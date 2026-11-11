mod common;

use std::time::Duration;

#[test]
fn manual_mode_retries_a_failed_batch_on_the_next_flush_and_not_before() {
    let (address, seen) = common::fake(|_, before| if before == 0 { 500 } else { 200 });
    dokkit::announce_version(false);
    dokkit::start_manual_with("1.0", &address, "dka_test");
    dokkit::log("info", "retry me");
    dokkit::flush();
    assert_eq!(seen.lock().unwrap().len(), 1);
    std::thread::sleep(Duration::from_millis(2500));
    assert_eq!(seen.lock().unwrap().len(), 1, "a retry was sent without a flush");
    dokkit::flush();
    assert_eq!(seen.lock().unwrap().len(), 2);
    assert_eq!(dokkit::dropped(), 0);
    assert_eq!(common::bodies(&seen, "/api/v1/report").matches("retry me").count(), 2);
}
