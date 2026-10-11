mod common;

#[test]
fn production_adds_nothing() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::environment("production");
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::log("info", "x");
    dokkit::beat("w", 30);
    dokkit::flush();
    assert!(!common::bodies(&seen, "/api/v1/report").contains("environment"));
}
