struct ConformanceError;

fn main() {
    let tag = std::env::args().nth(1).unwrap();
    dokkit::start("9.9.9");
    dokkit::beat("conf-beat", 60);
    let _ = dokkit::job("conf-job", |_| Ok::<(), ()>(()));
    dokkit::check("conf-check", "ok", Some(1.0), None);
    dokkit::metric("conf.metric", 5.0, Some("n"));
    dokkit::log_fields("info", &format!("conformance {tag}"), &[("tag", tag.as_str().into()), ("n", 1.into())]);
    dokkit::capture(&ConformanceError);
    dokkit::flush();
}
