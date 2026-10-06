#![cfg(feature = "log")]
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

// At debug level the HTTP client logs about every request. Those lines must not be queued.
#[test]
fn the_logger_does_not_feed_on_its_own_sending() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/", listener.local_addr().unwrap());
    let posts = Arc::new(AtomicUsize::new(0));
    let seen = posts.clone();
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
            reader.read_exact(&mut vec![0; length]).unwrap();
            seen.fetch_add(1, Ordering::SeqCst);
            stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").unwrap();
        }
    });

    log::set_logger(&dokkit::Logger).unwrap();
    log::set_max_level(log::LevelFilter::Debug);
    dokkit::start_with("1.0.0", &address, "dka_test");
    log::info!("one app line");
    dokkit::flush();
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    dokkit::flush();
    dokkit::flush();
    assert_eq!(posts.load(Ordering::SeqCst), 1);
}
