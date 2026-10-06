use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

#[test]
fn stats_stay_on_one_line_and_a_panicking_job_fails() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/", listener.local_addr().unwrap());
    let got = Arc::new(Mutex::new(String::new()));
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
            seen.lock()
                .unwrap()
                .push_str(&format!("{head}{}\n", String::from_utf8(body).unwrap()));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
                .unwrap();
        }
    });

    dokkit::start_with("", &address, "dka_test");
    dokkit::stats("{\r\n  \"cpu\": 1\r\n}");
    let caught = std::panic::catch_unwind(|| {
        let _: Result<(), ()> = dokkit::job("crash", |_| panic!("boom"));
    });
    assert!(caught.is_err());

    let all = got.lock().unwrap();
    assert!(all.contains(r#"{"type":"stats","host":"#), "{all}");
    assert!(all.contains(r#""document":{    "cpu": 1  }"#), "{all}");
    assert!(all.contains(r#""event":"fail","exit_code":1"#), "{all}");
    assert!(all.contains(r#""type":"panic","handled":false"#), "{all}");
    assert!(
        all.contains("more::stats_stay_on_one_line_and_a_panicking_job_fails"),
        "{all}"
    );
}
