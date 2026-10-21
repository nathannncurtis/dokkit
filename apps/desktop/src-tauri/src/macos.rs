use crate::logic;
use block2::Block;
use objc2::runtime::AnyObject;
use objc2::{class, msg_send};
use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr};
use std::sync::Mutex;
use tauri::{ActivationPolicy, AppHandle, Manager, WebviewWindow};

static PINS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

type Handler = Block<dyn Fn(isize, *mut AnyObject)>;

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecTrustGetCertificateAtIndex(trust: *mut c_void, index: isize) -> *mut c_void;
    fn SecCertificateCopyData(cert: *mut c_void) -> *mut c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFDataGetLength(data: *mut c_void) -> isize;
    fn CFDataGetBytePtr(data: *mut c_void) -> *const u8;
    fn CFRelease(obj: *mut c_void);
}

#[link(name = "objc")]
extern "C" {
    fn object_getClass(obj: *mut AnyObject) -> *mut c_void;
    fn sel_registerName(name: *const c_char) -> *mut c_void;
    fn class_replaceMethod(cls: *mut c_void, sel: *mut c_void, imp: *const c_void, types: *const c_char) -> *const c_void;
}

unsafe fn text(s: *mut AnyObject) -> String {
    if s.is_null() {
        return String::new();
    }
    let p: *const c_char = msg_send![s, UTF8String];
    CStr::from_ptr(p).to_string_lossy().into_owned()
}

unsafe fn leaf_der(trust: *mut c_void) -> Option<Vec<u8>> {
    let cert = SecTrustGetCertificateAtIndex(trust, 0);
    if cert.is_null() {
        return None;
    }
    let data = SecCertificateCopyData(cert);
    if data.is_null() {
        return None;
    }
    let der = std::slice::from_raw_parts(CFDataGetBytePtr(data), CFDataGetLength(data) as usize).to_vec();
    CFRelease(data);
    Some(der)
}

extern "C" fn challenge(_this: *mut AnyObject, _sel: *mut c_void, _view: *mut AnyObject, challenge: *mut AnyObject, handler: *const Handler) {
    unsafe {
        let space: *mut AnyObject = msg_send![challenge, protectionSpace];
        let method: *mut AnyObject = msg_send![space, authenticationMethod];
        let host: *mut AnyObject = msg_send![space, host];
        let trust: *mut c_void = msg_send![space, serverTrust];
        let pin = PINS.lock().unwrap().as_ref().and_then(|m| m.get(&text(host).to_lowercase()).cloned());
        let accept = text(method) == "NSURLAuthenticationMethodServerTrust"
            && !trust.is_null()
            && pin.is_some_and(|pin| leaf_der(trust).is_some_and(|der| logic::pin_matches(&pin, &der)));
        if accept {
            let cred: *mut AnyObject = msg_send![class!(NSURLCredential), credentialForTrust: trust];
            (*handler).call((0, cred));
        } else {
            (*handler).call((1, std::ptr::null_mut()));
        }
    }
}

/// Teaches the window's navigation delegate to accept the pinned certificate for this host and nothing else.
pub fn pin(window: &WebviewWindow, host: &str, pin: &str) {
    PINS.lock().unwrap().get_or_insert_with(HashMap::new).insert(host.to_lowercase(), pin.to_string());
    let _ = window.with_webview(|webview| unsafe {
        let view = webview.inner() as *mut AnyObject;
        let delegate: *mut AnyObject = msg_send![view, navigationDelegate];
        if delegate.is_null() {
            return;
        }
        class_replaceMethod(
            object_getClass(delegate),
            sel_registerName(c"webView:didReceiveAuthenticationChallenge:completionHandler:".as_ptr()),
            challenge as *const c_void,
            c"v@:@@@?".as_ptr(),
        );
    });
}

pub fn notify(title: String, body: String, open: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        let sent = mac_notification_sys::Notification::new().title(&title).message(&body).wait_for_click(true).send();
        if matches!(sent, Ok(mac_notification_sys::NotificationResponse::Click)) {
            open();
        }
    });
}

pub fn set_bundle(identifier: &str) {
    let _ = mac_notification_sys::set_application(identifier);
}

/// No Dock icon while only the menu-bar icon is showing; a normal app while a window is open.
pub fn dock(app: &AppHandle) {
    let open = app.webview_windows().values().any(|w| w.is_visible().unwrap_or(false));
    let _ = app.set_activation_policy(if open { ActivationPolicy::Regular } else { ActivationPolicy::Accessory });
}
