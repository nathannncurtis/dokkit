use crate::logic;
use base64::Engine;
use tauri::WebviewWindow;
use webview2_com::Microsoft::Web::WebView2::Win32::{
    ICoreWebView2_14, COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW,
};
use webview2_com::{take_pwstr, ServerCertificateErrorDetectedEventHandler};
use windows_core::Interface;

fn der_of(pem: &str) -> Option<Vec<u8>> {
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
    base64::engine::general_purpose::STANDARD.decode(body.trim()).ok()
}

/// Lets the window accept a certificate the system does not trust, but only the pinned one.
pub fn apply(window: &WebviewWindow, pin: &str) {
    let pin = pin.to_string();
    let _ = window.with_webview(move |webview| unsafe {
        let Ok(core) = webview.controller().CoreWebView2() else { return };
        let Ok(core) = core.cast::<ICoreWebView2_14>() else { return };
        let handler = ServerCertificateErrorDetectedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            let mut pem = windows_core::PWSTR::null();
            args.ServerCertificate()?.ToPemEncoding(&mut pem)?;
            if der_of(&take_pwstr(pem)).is_some_and(|der| logic::pin_matches(&pin, &der)) {
                args.SetAction(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW)?;
            }
            Ok(())
        }));
        let mut token = Default::default();
        let _ = core.add_ServerCertificateErrorDetected(&handler, &mut token);
    });
}
