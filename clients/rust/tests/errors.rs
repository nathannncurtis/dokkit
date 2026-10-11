mod common;

#[test]
fn a_failed_error_report_is_kept_and_a_refused_one_is_dropped() {
    let (address, seen) = common::fake(|path, before| match (path, before) {
        ("/api/v1/errors", 0) => 503,
        ("/api/v1/errors", 2) => 429,
        ("/api/v1/errors", 4) => 401,
        _ => 200,
    });
    dokkit::start_with("", &address, "dka_test");
    let attempts = || seen.lock().unwrap().iter().filter(|(p, _)| p == "/api/v1/errors").count();
    dokkit::capture(&std::fmt::Error);
    dokkit::beat("w", 30);
    dokkit::flush();
    assert!(common::bodies(&seen, "/api/v1/report").contains("beat"));
    assert_eq!((attempts(), dokkit::dropped()), (1, 0));

    dokkit::flush();
    assert_eq!((attempts(), dokkit::dropped()), (2, 0));

    dokkit::capture(&std::fmt::Error);
    dokkit::flush();
    assert_eq!((attempts(), dokkit::dropped()), (3, 0));
    dokkit::flush();
    assert_eq!((attempts(), dokkit::dropped()), (4, 0));

    dokkit::capture(&std::fmt::Error);
    dokkit::flush();
    assert_eq!((attempts(), dokkit::dropped()), (5, 1));
}
