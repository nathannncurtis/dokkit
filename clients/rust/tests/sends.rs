use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

#[test]
fn everything_is_off_until_started_then_sends() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/", listener.local_addr().unwrap());
    let got = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
    let seen = got.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let (mut head, mut length) = (String::new(), 0);
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(n) = line.to_lowercase().strip_prefix("content-length:") {
                    length = n.trim().parse().unwrap();
                }
                if line.trim().is_empty() {
                    break;
                }
                head += &line;
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            seen.lock().unwrap().push((head, String::from_utf8(body).unwrap()));
            stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").unwrap();
        }
    });

    dokkit::beat("ignored", 60);
    dokkit::start_with("2.3.0", &address, "dka_test");
    dokkit::beat("worker", 30);
    dokkit::check("queue-age", "degraded", Some(14.0), Some("oldest item is \"14\" minutes old"));
    dokkit::log("error", "Upload failed");
    let result: Result<(), std::fmt::Error> = dokkit::job("nightly-purge", |run| {
        run.progress(4000, Some(9000));
        Err(std::fmt::Error)
    });
    assert!(result.is_err());
    dokkit::flush();

    let got = got.lock().unwrap();
    let all: String = got.iter().map(|(head, body)| format!("{head}{body}\n")).collect();
    for want in [
        "POST /api/v1/report", "Bearer dka_test", r#"{"type":"deploy","host":"#, r#""version":"2.3.0""#,
        r#""every_seconds":30"#, r#""state":"degraded","value":14"#, r#"oldest item is \"14\" minutes old"#,
        r#""level":"error","msg":"Upload failed""#, r#""event":"start""#, r#""event":"progress","done":4000,"total":9000"#,
        r#""event":"fail","exit_code":1"#, "POST /api/v1/errors", r#""type":"core::fmt::Error","handled":false"#,
        r#""own":true"#, "sends.rs",
    ] {
        assert!(all.contains(want), "missing {want} in\n{all}");
    }
    assert!(!all.contains("ignored"));
}
