mod common;

#[test]
fn a_panic_is_an_error_report_with_a_stack_and_no_message() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::catch_unhandled();
    let result = std::panic::catch_unwind(|| {
        let secret = "private text";
        panic!("{secret}");
    });
    assert!(result.is_err());
    let errors = common::bodies(&seen, "/api/v1/errors");
    assert!(errors.contains(r#""type":"panic","handled":false"#), "{errors}");
    assert!(errors.contains("panic.rs") && !errors.contains("private text"), "{errors}");
    assert!(errors.matches(r#""file":"#).count() > 1, "{errors}");
    assert!(!common::bodies(&seen, "/api/v1/report").contains("panic"));
}
