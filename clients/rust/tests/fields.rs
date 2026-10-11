mod common;

#[test]
fn fields_go_flat_and_a_long_line_is_cut() {
    let (address, seen) = common::fake(|_, _| 200);
    dokkit::start_with("1.0", &address, "dka_test");
    dokkit::log("info", "plain");
    dokkit::log_fields("info", "paid", &[("order", 42.into()), ("who", "a\"b".into()), ("ok", true.into()), ("t", 1.5.into())]);
    dokkit::log_fields("info", &"é".repeat(40000), &[("order", 7.into())]);
    dokkit::log_fields("info", "many", &(0..3000).map(|i| (Box::leak(format!("key{i}").into_boxed_str()) as &str, "x".repeat(40).into())).collect::<Vec<_>>());
    dokkit::flush();

    let all = common::bodies(&seen, "/api/v1/report");
    for want in [r#""msg":"plain"}"#, r#""msg":"paid","fields":{"order":42,"who":"a\"b","ok":true,"t":1.5}"#, r#""type":"deploy""#] {
        assert!(all.contains(want), "missing {want}");
    }
    let lines: Vec<&str> = all.lines().collect();
    assert!(lines.iter().all(|l| l.len() <= 65536));
    let long = lines.iter().find(|l| l.contains("éé")).unwrap();
    assert!(long.contains(r#" [cut]","fields":{"order":7}"#));
    let many = lines.iter().find(|l| l.contains(r#""msg":"many"#)).unwrap();
    assert!(many.contains(r#""msg":"many [cut]""#) && !many.contains("key1"));
}
