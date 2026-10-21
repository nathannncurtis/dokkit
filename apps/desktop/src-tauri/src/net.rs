use crate::logic::{self, Issue};
use chrono::Utc;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, DigitallySignedStruct, SignatureScheme};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

// With no pin it accepts any certificate: only the add-server step uses that, to read the fingerprint.
#[derive(Debug)]
struct Verifier {
    provider: Arc<CryptoProvider>,
    pin: Option<[u8; 32]>,
    seen: Arc<Mutex<Option<Vec<u8>>>>,
}

impl ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        *self.seen.lock().unwrap() = Some(end_entity.to_vec());
        match self.pin {
            Some(want) if want[..] != Sha256::digest(end_entity)[..] => {
                Err(rustls::Error::InvalidCertificate(CertificateError::ApplicationVerificationFailure))
            }
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(m, c, d, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

fn custom(pin: Option<[u8; 32]>, seen: Arc<Mutex<Option<Vec<u8>>>>) -> Result<reqwest::Client, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Verifier { provider, pin, seen }))
        .with_no_client_auth();
    builder().use_preconfigured_tls(config).build().map_err(|e| e.to_string())
}

fn builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder().timeout(Duration::from_secs(20)).user_agent("dokkit-desktop")
}

pub fn client(pin: Option<&str>) -> Result<reqwest::Client, String> {
    match pin {
        None => builder().build().map_err(|e| e.to_string()),
        Some(p) => {
            let want = logic::parse_pin(p).ok_or("The pinned certificate is not a sha256 fingerprint.")?;
            custom(Some(want), Arc::default())
        }
    }
}

/// The fingerprint of the certificate a server presents, whether or not it is publicly trusted.
pub async fn presented_fingerprint(url: &str) -> Result<String, String> {
    let seen = Arc::new(Mutex::new(None));
    let c = custom(None, seen.clone())?;
    c.get(url).send().await.map_err(|e| e.to_string())?;
    let der = seen.lock().unwrap().clone().ok_or("The server presented no certificate.")?;
    Ok(logic::fingerprint(&der))
}

/// A short sentence for why a request failed, from the whole cause chain.
pub fn explain(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        return "The server did not answer in time.".into();
    }
    let mut msgs = vec![];
    let mut refused = false;
    let mut cur: Option<&(dyn std::error::Error + 'static)> = Some(e);
    while let Some(x) = cur {
        msgs.push(x.to_string());
        refused |= x.downcast_ref::<std::io::Error>().is_some_and(|i| i.kind() == std::io::ErrorKind::ConnectionRefused);
        cur = x.source();
    }
    let all = msgs.join(" | ").to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| all.contains(w));
    if has(&["applicationverificationfailure"]) {
        "The server's certificate does not match the pinned one.".into()
    } else if has(&["unknownissuer", "unknown issuer", "invalid peer certificate", "certificate"]) {
        "The server's certificate is not trusted.".into()
    } else if has(&["dns error", "failed to lookup", "no such host", "name or service not known", "nodename nor servname"]) {
        "The server's name could not be found.".into()
    } else if refused || has(&["connection refused", "actively refused"]) {
        "The server refused the connection.".into()
    } else {
        msgs.last().cloned().unwrap_or_else(|| e.to_string())
    }
}

#[derive(Debug)]
pub struct Snapshot {
    pub all: Vec<Issue>,
    pub needs: Vec<Issue>,
}

#[derive(Deserialize)]
struct List {
    items: Vec<Issue>,
}

async fn list(c: &reqwest::Client, base: &str, token: &str, query: &str) -> Result<Vec<Issue>, String> {
    let res = c
        .get(format!("{base}/api/v1/issues?limit=500{query}"))
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| explain(&e.without_url()))?;
    match res.status().as_u16() {
        200 => Ok(res.json::<List>().await.map_err(|e| e.without_url().to_string())?.items),
        401 => Err("The token was not accepted.".into()),
        403 => Err("The token may not read.".into()),
        n => Err(format!("The server answered {n}.")),
    }
}

pub async fn snapshot(base: &str, token: &str, pin: Option<&str>) -> Result<Snapshot, String> {
    let c = client(pin)?;
    let all = list(&c, base, token, "").await?;
    let production: HashSet<String> =
        list(&c, base, token, "&environment=production").await?.into_iter().map(|i| i.id).collect();
    let needs = logic::needs_you(&all, &production, Utc::now());
    Ok(Snapshot { all, needs })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const BODY: &str = r#"{"items":[{"id":"a","short_id":"DOK-1","soon":false,"title":"x is down","snoozed_until":null,"service":"s1"},{"id":"b","short_id":"DOK-2","soon":true,"title":"y soon","snoozed_until":null,"service":"s2"}],"next":null}"#;

    async fn serve() -> (String, Vec<u8>) {
        let key = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let der = key.cert.der().to_vec();
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![key.cert.der().clone()],
                rustls::pki_types::PrivateKeyDer::Pkcs8(key.key_pair.serialize_der().into()),
            )
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = listener.accept().await else { return };
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    let Ok(mut tls) = acceptor.accept(tcp).await else { return };
                    let mut buf = vec![0u8; 4096];
                    let n = tls.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                    let head = if req.contains("bearer dku_good") { "200 OK" } else { "401 Unauthorized" };
                    let _ = tls
                        .write_all(
                            format!(
                                "HTTP/1.1 {head}
content-type: application/json
content-length: {}
connection: close

{BODY}",
                                BODY.len()
                            )
                            .as_bytes(),
                        )
                        .await;
                    let _ = tls.shutdown().await;
                });
            }
        });
        (format!("https://localhost:{port}"), der)
    }

    #[tokio::test]
    async fn self_signed_server_is_pinned_not_trusted_by_default() {
        let (url, der) = serve().await;
        let untrusted = client(None).unwrap().get(&url).send().await.unwrap_err();
        assert_eq!(explain(&untrusted), "The server's certificate is not trusted.");
        let fp = presented_fingerprint(&url).await.unwrap();
        assert_eq!(fp, logic::fingerprint(&der));
        assert!(client(Some(&fp)).unwrap().get(&url).bearer_auth("dku_good").send().await.is_ok());
        let wrong = logic::fingerprint(b"another certificate");
        let mismatch = client(Some(&wrong)).unwrap().get(&url).send().await.unwrap_err();
        assert_eq!(explain(&mismatch), "The server's certificate does not match the pinned one.");
        assert_eq!(snapshot(&url, "dku_bad", Some(&fp)).await.unwrap_err(), "The token was not accepted.");
    }

    #[tokio::test]
    async fn refused_connection_is_explained() {
        let port = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap().port();
        let e = client(None).unwrap().get(format!("https://127.0.0.1:{port}")).send().await.unwrap_err();
        assert_eq!(explain(&e), "The server refused the connection.");
    }

    #[tokio::test]
    async fn snapshot_reads_issues_and_keeps_needs_you() {
        let (url, der) = serve().await;
        let snap = snapshot(&url, "dku_good", Some(&logic::fingerprint(&der))).await.unwrap();
        assert_eq!(snap.all.len(), 2);
        assert_eq!(snap.needs.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["a"]);
    }
}
