use crate::logic;
use tauri::WebviewWindow;
use webkit2gtk::glib::prelude::*;
use webkit2gtk::{gio, glib, WebContextExt, WebViewExt};

pub const KEYCHAIN_HELP: &str =
    "No Secret Service is running, so the token cannot be stored. Install and unlock GNOME Keyring or KeePassXC, then try again.";

pub fn notify(title: &str, body: &str, on_click: impl FnOnce() + Send + 'static) {
    let (title, body) = (title.to_string(), body.to_string());
    std::thread::spawn(move || {
        let shown = notify_rust::Notification::new().appname("Dokkit").summary(&title).body(&body).action("default", "Open").show();
        if let Ok(handle) = shown {
            handle.wait_for_action(|action| {
                if action == "default" {
                    on_click();
                }
            });
        }
    });
}

fn host_of(uri: &str) -> Option<String> {
    url::Url::parse(uri).ok()?.host_str().map(String::from)
}

fn der_of(cert: &gio::TlsCertificate) -> Vec<u8> {
    cert.property::<glib::ByteArray>("certificate").to_vec()
}

/// Lets the window accept a certificate the system does not trust, but only the pinned one.
pub fn pin(window: &WebviewWindow, pin: &str) {
    let pin = pin.to_string();
    let _ = window.with_webview(move |webview| {
        webview.inner().connect_load_failed_with_tls_errors(move |view, uri, cert, _| {
            let (Some(host), Some(context)) = (host_of(uri), view.context()) else { return false };
            if !logic::pin_matches(&pin, &der_of(cert)) {
                return false;
            }
            context.allow_tls_certificate_for_host(cert, &host);
            view.load_uri(uri);
            true
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_comes_from_the_failed_uri() {
        assert_eq!(host_of("https://dokkit.example.test:8443/issues/1").as_deref(), Some("dokkit.example.test"));
        assert_eq!(host_of("not a uri"), None);
    }
}
