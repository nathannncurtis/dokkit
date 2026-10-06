#![cfg(feature = "log")]
// cargo test --features log
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

#[test]
fn the_log_crate_sends_through_log() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/", listener.local_addr().unwrap());
    let got = Arc::new(Mutex::new(String::new()));
    let seen = got.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(n) = line.to_lowercase().strip_prefix("content-length:") {
                    length = n.trim().parse().unwrap();
                }
                if line.trim().is_empty() {
                    break;
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            seen.lock().unwrap().push_str(&String::from_utf8(body).unwrap());
            stream
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
                .unwrap();
        }
    });

    dokkit::start_with("", &address, "dka_test");
    log::set_logger(&dokkit::Logger).unwrap();
    log::set_max_level(log::LevelFilter::Info);
    log::warn!("slow {}", "query");
    log::debug!("not sent");
    dokkit::flush();

    let all = got.lock().unwrap();
    assert!(all.contains(r#""level":"warn","msg":"slow query""#), "{all}");
    assert!(!all.contains("not sent"), "{all}");
}
