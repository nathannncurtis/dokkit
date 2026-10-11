mod common;

#[test]
fn a_dev_environment_is_on_every_line() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::environment("dev");
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::log("info", "x");
    dokkit::beat("w", 30);
    let _: Result<(), std::fmt::Error> = dokkit::job("j", |_| Ok(()));
    dokkit::flush();
    let all = common::bodies(&seen, "/api/v1/report");
    let lines: Vec<&str> = all.lines().collect();
    assert!(lines.len() >= 5 && lines.iter().all(|l| l.contains(r#""environment":"dev""#)), "{all}");
}
