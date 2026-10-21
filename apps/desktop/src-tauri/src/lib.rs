mod logic;
mod net;
mod settings;
mod tray;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod webview_pin;

use logic::{Issue, Level};
use serde::Serialize;
use settings::{Notify, Server, Settings};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tokio::sync::Notify as Wake;

const KEYRING_SERVICE: &str = "dokkit-desktop";
const PAUSE: Duration = Duration::from_secs(3600);

#[derive(Default, Clone)]
pub struct ServerState {
    pub level: Option<Level>,
    pub needs: usize,
    pub error: Option<String>,
    notified: Option<(Notify, HashSet<String>)>,
}

pub struct Shared {
    path: PathBuf,
    settings: Mutex<Settings>,
    states: Mutex<HashMap<String, ServerState>>,
    paused_until: Mutex<Option<Instant>>,
    wake: Wake,
}

pub fn shared(app: &AppHandle) -> &Shared {
    app.state::<Shared>().inner()
}

fn secret(id: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, id).map_err(|e| e.to_string())
}

fn keychain_error(e: keyring::Error) -> String {
    #[cfg(target_os = "linux")]
    if matches!(e, keyring::Error::NoStorageAccess(_) | keyring::Error::PlatformFailure(_)) {
        return linux::KEYCHAIN_HELP.into();
    }
    e.to_string()
}

fn token(id: &str) -> Result<String, String> {
    secret(id)?.get_password().map_err(|e| match e {
        keyring::Error::NoEntry => "No token is stored for this server.".to_string(),
        e => keychain_error(e),
    })
}

pub fn paused(app: &AppHandle) -> bool {
    let mut p = shared(app).paused_until.lock().unwrap();
    if p.is_some_and(|t| t <= Instant::now()) {
        *p = None;
    }
    p.is_some()
}

fn save(app: &AppHandle) -> Result<(), String> {
    let s = shared(app);
    s.settings.lock().unwrap().save(&s.path).map_err(|e| e.to_string())
}

pub fn open_settings(app: &AppHandle) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(w) = app.get_webview_window("settings") {
            let _ = w.show();
            let _ = w.unminimize();
            let _ = w.set_focus();
            return;
        }
        let _ = WebviewWindowBuilder::new(&app, "settings", WebviewUrl::App("index.html".into()))
            .title("Dokkit")
            .inner_size(720.0, 760.0)
            .min_inner_size(480.0, 480.0)
            .build();
        #[cfg(target_os = "macos")]
        macos::dock(&app);
    });
}

pub fn show_server(app: &AppHandle, id: &str, path: Option<String>) {
    let (app, id) = (app.clone(), id.to_string());
    let _ = app.clone().run_on_main_thread(move || {
        let Some(server) = shared(&app).settings.lock().unwrap().servers.iter().find(|s| s.id == id).cloned() else {
            return;
        };
        let Ok(base) = checked(&server) else {
            open_settings(&app);
            return;
        };
        let Ok(target) = url::Url::parse(&format!("{base}{}", path.as_deref().unwrap_or("/"))) else {
            return;
        };
        let label = format!("srv-{id}");
        if let Some(w) = app.get_webview_window(&label) {
            if path.is_some() {
                let _ = w.navigate(target);
            }
            let _ = w.show();
            let _ = w.unminimize();
            let _ = w.set_focus();
            #[cfg(target_os = "macos")]
            macos::dock(&app);
            return;
        }
        let _built = WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(target.clone()))
            .title(format!("{} - Dokkit", server.name))
            .inner_size(1280.0, 860.0)
            .build();
        #[cfg(windows)]
        if let (Ok(w), Some(pin)) = (&_built, &server.pin) {
            webview_pin::apply(w, pin);
        }
        #[cfg(target_os = "macos")]
        {
            if let (Ok(w), Some(pin), Some(key)) = (&_built, &server.pin, logic::pin_key(&server.url)) {
                macos::pin(w, &key, pin);
            }
            macos::dock(&app);
        }
        #[cfg(target_os = "linux")]
        if let (Ok(w), Some(pin)) = (&_built, &server.pin) {
            linux::pin(w, pin);
        }
    });
}

fn toast(app: &AppHandle, server: &Server, issue: &Issue) {
    let title = format!("{}: {}", server.name, issue.short_id);
    let (app2, id, path) = (app.clone(), server.id.clone(), logic::issue_path(issue));
    #[cfg(windows)]
    {
        use tauri_winrt_notification::Toast;
        let app_id = if tauri::is_dev() { Toast::POWERSHELL_APP_ID.to_string() } else { app.config().identifier.clone() };
        let _ = Toast::new(&app_id)
            .title(&title)
            .text1(&issue.title)
            .on_activated(move |_| {
                show_server(&app2, &id, Some(path.clone()));
                Ok(())
            })
            .show();
    }
    #[cfg(target_os = "macos")]
    macos::notify(title, issue.title.clone(), move || show_server(&app2, &id, Some(path)));
    #[cfg(target_os = "linux")]
    linux::notify(&title, &issue.title, move || show_server(&app2, &id, Some(path)));
}

fn checked(server: &Server) -> Result<String, String> {
    logic::validate_url(&server.url, server.allow_http).map_err(|e| format!("The saved address is not allowed: {e}"))
}

async fn poll_all(app: &AppHandle) {
    let (servers, mode) = {
        let s = shared(app).settings.lock().unwrap();
        (s.servers.clone(), s.notify)
    };
    for server in servers {
        let result = match checked(&server).and_then(|url| token(&server.id).map(|t| (url, t))) {
            Ok((url, t)) => net::snapshot(&url, &t, server.pin.as_deref()).await,
            Err(e) => Err(e),
        };
        let mut fresh = vec![];
        {
            let mut states = shared(app).states.lock().unwrap();
            if !shared(app).settings.lock().unwrap().servers.iter().any(|s| s.id == server.id) {
                continue;
            }
            let st = states.entry(server.id.clone()).or_default();
            match result {
                Ok(snap) => {
                    let candidates = match mode {
                        Notify::NeedsYou => snap.needs.clone(),
                        Notify::Everything => logic::awake(&snap.all, chrono::Utc::now()),
                        Notify::Off => vec![],
                    };
                    let prev = st.notified.as_ref().filter(|(m, _)| *m == mode).map(|(_, ids)| ids);
                    fresh = logic::fresh(prev, &candidates);
                    st.notified = Some((mode, candidates.iter().map(|i| i.id.clone()).collect()));
                    st.needs = snap.needs.len();
                    st.level = Some(if st.needs > 0 { Level::Needs } else { Level::Fine });
                    st.error = None;
                }
                Err(e) => {
                    st.level = Some(Level::Down);
                    st.error = Some(e);
                }
            }
        }
        if server.notify && !paused(app) {
            for issue in &fresh {
                toast(app, &server, issue);
            }
        }
    }
    let ids: HashSet<String> = shared(app).settings.lock().unwrap().servers.iter().map(|s| s.id.clone()).collect();
    shared(app).states.lock().unwrap().retain(|id, _| ids.contains(id));
    tray::refresh(app);
}

#[derive(Serialize)]
struct View {
    settings: Settings,
    defaults: Settings,
    states: Vec<StateView>,
    paused: bool,
}

#[derive(Serialize)]
struct StateView {
    id: String,
    level: Option<&'static str>,
    needs: usize,
    error: Option<String>,
}

#[tauri::command]
async fn get_state(app: AppHandle) -> View {
    let s = shared(&app);
    let states = s
        .states
        .lock()
        .unwrap()
        .iter()
        .map(|(id, st)| StateView {
            id: id.clone(),
            level: st.level.map(|l| match l {
                Level::Fine => "fine",
                Level::Needs => "needs",
                Level::Down => "down",
            }),
            needs: st.needs,
            error: st.error.clone(),
        })
        .collect();
    let settings = s.settings.lock().unwrap().clone();
    View { settings, defaults: Settings::default(), states, paused: paused(&app) }
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum Added {
    Added,
    Untrusted { fingerprint: String },
}

#[tauri::command]
async fn add_server(
    app: AppHandle,
    name: String,
    url: String,
    token: String,
    allow_http: bool,
    pin: Option<String>,
) -> Result<Added, String> {
    let url = logic::validate_url(&url, allow_http)?;
    let pin = pin.filter(|p| !p.trim().is_empty());
    if let Some(p) = &pin {
        logic::parse_pin(p).ok_or("The fingerprint must look like sha256:<64 hex digits>.")?;
    }
    if shared(&app).settings.lock().unwrap().servers.iter().any(|s| s.url == url) {
        return Err("That server is already added.".into());
    }
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err("Paste the token from the server's Settings page.".into());
    }
    if let Err(e) = net::client(pin.as_deref())?.get(&url).send().await {
        if pin.is_none() {
            if let Ok(fingerprint) = net::presented_fingerprint(&url).await {
                return Ok(Added::Untrusted { fingerprint });
            }
        }
        return Err(net::explain(&e.without_url()));
    }
    net::snapshot(&url, &token, pin.as_deref()).await?;
    let id = uuid::Uuid::new_v4().to_string();
    secret(&id)?.set_password(&token).map_err(keychain_error)?;
    let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(String::from)).unwrap_or_default();
    let name = Some(name.trim().to_string()).filter(|n| !n.is_empty()).unwrap_or(host);
    shared(&app).settings.lock().unwrap().servers.push(Server {
        id: id.clone(),
        name,
        url,
        notify: true,
        pin: pin.map(|p| logic::normalise_pin(&p).unwrap_or(p)),
        allow_http,
    });
    save(&app)?;
    shared(&app).wake.notify_one();
    show_server(&app, &id, None);
    Ok(Added::Added)
}

#[tauri::command]
async fn remove_server(app: AppHandle, id: String) -> Result<(), String> {
    let _ = secret(&id).and_then(|e| e.delete_credential().map_err(|e| e.to_string()));
    let _removed = {
        let mut s = shared(&app).settings.lock().unwrap();
        let removed = s.servers.iter().find(|s| s.id == id).cloned();
        s.servers.retain(|s| s.id != id);
        removed
    };
    #[cfg(target_os = "macos")]
    if let Some(key) = _removed.and_then(|s| logic::pin_key(&s.url)) {
        macos::unpin(&key);
    }
    shared(&app).states.lock().unwrap().remove(&id);
    save(&app)?;
    let label = format!("srv-{id}");
    let a = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = a.get_webview_window(&label) {
            let _ = w.destroy();
        }
    });
    tray::refresh(&app);
    Ok(())
}

#[tauri::command]
async fn set_server_notify(app: AppHandle, id: String, notify: bool) -> Result<(), String> {
    if let Some(s) = shared(&app).settings.lock().unwrap().servers.iter_mut().find(|s| s.id == id) {
        s.notify = notify;
    }
    save(&app)
}

#[tauri::command]
async fn set_settings(app: AppHandle, poll_secs: u64, notify: Notify, autostart: bool) -> Result<(), String> {
    {
        let mut s = shared(&app).settings.lock().unwrap();
        s.set_poll_secs(poll_secs)?;
        s.notify = notify;
        s.autostart = autostart;
    }
    apply_autostart(&app, autostart);
    shared(&app).wake.notify_one();
    save(&app)
}

#[tauri::command]
async fn open_server(app: AppHandle, id: String) {
    show_server(&app, &id, None);
}

fn apply_autostart(app: &AppHandle, on: bool) {
    use tauri_plugin_autostart::ManagerExt;
    if tauri::is_dev() {
        return;
    }
    let launch = app.autolaunch();
    let _ = if on { launch.enable() } else { launch.disable() };
}

pub fn quit(app: &AppHandle) {
    use tauri_plugin_window_state::{AppHandleExt, StateFlags};
    let _ = app.save_window_state(StateFlags::all() & !StateFlags::VISIBLE);
    app.exit(0);
}

pub fn toggle_pause(app: &AppHandle) {
    let mut p = shared(app).paused_until.lock().unwrap();
    *p = if p.is_some() { None } else { Some(Instant::now() + PAUSE) };
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use tauri_plugin_window_state::StateFlags;
    let hidden = std::env::args().any(|a| a == "--hidden");
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            let first = shared(app).settings.lock().unwrap().servers.first().map(|s| s.id.clone());
            match first {
                Some(id) => show_server(app, &id, None),
                None => open_settings(app),
            }
        }))
        .plugin(tauri_plugin_window_state::Builder::default().with_state_flags(StateFlags::all() & !StateFlags::VISIBLE).build())
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec!["--hidden"])))
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                #[cfg(target_os = "macos")]
                macos::dock(window.app_handle());
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            add_server,
            remove_server,
            set_server_notify,
            set_settings,
            open_server
        ])
        .setup(move |app| {
            let path = app.path().app_config_dir()?.join("settings.json");
            let settings = Settings::load(&path);
            let (autostart, ids) = (settings.autostart, settings.servers.iter().map(|s| s.id.clone()).collect::<Vec<_>>());
            app.manage(Shared {
                path,
                settings: Mutex::new(settings),
                states: Mutex::default(),
                paused_until: Mutex::default(),
                wake: Wake::new(),
            });
            #[cfg(target_os = "macos")]
            {
                if !tauri::is_dev() {
                    macos::set_bundle(&app.config().identifier);
                }
                macos::dock(app.handle());
            }
            tray::build(app.handle())?;
            apply_autostart(app.handle(), autostart);
            if ids.is_empty() {
                open_settings(app.handle());
            } else if !hidden {
                for id in &ids {
                    show_server(app.handle(), id, None);
                }
            }
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    poll_all(&handle).await;
                    let secs = shared(&handle).settings.lock().unwrap().poll_secs;
                    let _ = tokio::time::timeout(Duration::from_secs(secs), shared(&handle).wake.notified()).await;
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("run dokkit");
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn missing_secret_service_gets_a_clear_message() {
        let e = keyring::Error::NoStorageAccess("no bus".into());
        assert!(keychain_error(e).contains("Secret Service"));
        assert_eq!(keychain_error(keyring::Error::TooLong("x".into(), 1)), keyring::Error::TooLong("x".into(), 1).to_string());
    }
}
