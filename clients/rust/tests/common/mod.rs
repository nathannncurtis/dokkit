#![allow(dead_code)]
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

pub type Seen = Arc<Mutex<Vec<(String, String)>>>;

// Answers each request with status(path, how many times the path was asked before); 0 never answers.
pub fn fake(status: impl Fn(&str, usize) -> u16 + Send + Sync + 'static) -> (String, Seen) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}/", listener.local_addr().unwrap());
    let seen: Seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    let status = Arc::new(status);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let (log, status) = (log.clone(), status.clone());
            std::thread::spawn(move || {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let (mut path, mut length) = (String::new(), 0);
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(rest) = line.strip_prefix("POST ") {
                    path = rest.split(' ').next().unwrap().to_string();
                }
                if let Some(n) = line.to_lowercase().strip_prefix("content-length:") {
                    length = n.trim().parse().unwrap();
                }
                if line.trim().is_empty() {
                    break;
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let before = log.lock().unwrap().iter().filter(|(p, _)| *p == path).count();
            let code = status(&path, before);
            if code == 0 {
                std::thread::sleep(std::time::Duration::from_secs(30));
                return;
            }
            log.lock().unwrap().push((path, String::from_utf8(body).unwrap()));
            let _ = stream.write_all(format!("HTTP/1.1 {code} X\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{{}}").as_bytes());
            });
        }
    });
    (address, seen)
}

pub fn bodies(seen: &Seen, path: &str) -> String {
    seen.lock().unwrap().iter().filter(|(p, _)| p == path).map(|(_, b)| b.clone()).collect::<Vec<_>>().join("\n")
}
