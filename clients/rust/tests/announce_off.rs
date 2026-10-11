mod common;

#[test]
fn the_deploy_line_can_be_turned_off() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::announce_version(false);
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::beat("w", 30);
    dokkit::flush();
    let all = common::bodies(&seen, "/api/v1/report");
    assert!(all.contains("beat") && !all.contains("deploy"), "{all}");
}
