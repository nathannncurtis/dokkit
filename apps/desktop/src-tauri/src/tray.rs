use crate::logic::{self, Level};
use crate::{paused, shared};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Result};

const ID: &str = "main";

fn icon(level: Level) -> Image<'static> {
    let bytes: &[u8] = match level {
        Level::Fine => include_bytes!("../../icons/tray-fine.png"),
        Level::Needs => include_bytes!("../../icons/tray-needs.png"),
        Level::Down => include_bytes!("../../icons/tray-down.png"),
    };
    Image::from_bytes(bytes).expect("tray icon")
}

fn menu(app: &AppHandle) -> Result<(Menu<tauri::Wry>, Level, String)> {
    let s = shared(app);
    let servers = s.settings.lock().unwrap().servers.clone();
    let states = s.states.lock().unwrap().clone();
    let menu = Menu::new(app)?;
    let mut levels = vec![];
    let mut lines = vec![];
    for server in &servers {
        let st = states.get(&server.id);
        let level = st.and_then(|st| st.level).unwrap_or(Level::Fine);
        levels.push(level);
        let line = match (st.and_then(|st| st.level), st.map_or(0, |st| st.needs)) {
            (None, _) => format!("{} - checking", server.name),
            (Some(Level::Down), _) => format!("{} - unreachable", server.name),
            (_, 0) => format!("{} - all fine", server.name),
            (_, 1) => format!("{} - 1 needs you", server.name),
            (_, n) => format!("{} - {n} need you", server.name),
        };
        menu.append(&MenuItem::with_id(app, format!("srv:{}", server.id), &line, true, None::<&str>)?)?;
        lines.push(line);
    }
    if !servers.is_empty() {
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    let pause = if paused(app) { "Resume notifications" } else { "Pause notifications for 1 hour" };
    menu.append(&MenuItem::with_id(app, "pause", pause, true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", "Quit Dokkit", true, None::<&str>)?)?;
    let tip = if lines.is_empty() { "Dokkit".to_string() } else { format!("Dokkit\n{}", lines.join("\n")) };
    Ok((menu, logic::worst(&levels), tip))
}

pub fn refresh(app: &AppHandle) {
    let app = app.clone();
    let a = app.clone();
    let _ = a.run_on_main_thread(move || {
        let (Some(tray), Ok((menu, level, tip))) = (app.tray_by_id(ID), menu(&app)) else {
            return;
        };
        let _ = tray.set_menu(Some(menu));
        let _ = tray.set_icon(Some(icon(level)));
        let _ = tray.set_tooltip(Some(tip));
    });
}

pub fn build(app: &AppHandle) -> Result<()> {
    let (menu, level, tip) = menu(app)?;
    TrayIconBuilder::with_id(ID)
        .icon(icon(level))
        .tooltip(tip)
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "quit" => crate::quit(app),
            "settings" => crate::open_settings(app),
            "pause" => {
                crate::toggle_pause(app);
                refresh(app);
            }
            id => {
                if let Some(server) = id.strip_prefix("srv:") {
                    crate::show_server(app, server, None);
                }
            }
        })
        .build(app)?;
    Ok(())
}
