use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Notify {
    NeedsYou,
    Everything,
    Off,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub url: String,
    pub notify: bool,
    pub pin: Option<String>,
    pub allow_http: bool,
}

impl Default for Server {
    fn default() -> Self {
        Server { id: String::new(), name: String::new(), url: String::new(), notify: true, pin: None, allow_http: false }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub poll_secs: u64,
    pub notify: Notify,
    pub autostart: bool,
    pub servers: Vec<Server>,
}

pub const MIN_POLL_SECS: u64 = 15;
pub const MAX_POLL_SECS: u64 = 3600;

impl Default for Settings {
    fn default() -> Self {
        Settings { poll_secs: 60, notify: Notify::NeedsYou, autostart: true, servers: vec![] }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Settings {
        let Ok(bytes) = std::fs::read(path) else { return Settings::default() };
        match serde_json::from_slice::<Settings>(&bytes) {
            Ok(mut s) => {
                s.servers.retain(|v| !v.id.is_empty() && !v.url.is_empty());
                s
            }
            Err(e) => {
                let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
                let bad = path.with_file_name(format!("settings.json.bad-{stamp}"));
                match std::fs::rename(path, &bad) {
                    Ok(()) => eprintln!("settings file is unreadable ({e}); kept as {}", bad.display()),
                    Err(re) => eprintln!("settings file is unreadable ({e}) and could not be set aside: {re}"),
                }
                Settings::default()
            }
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_file_name("settings.json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        std::fs::rename(&tmp, path)
    }

    pub fn set_poll_secs(&mut self, secs: u64) -> Result<(), String> {
        if !(MIN_POLL_SECS..=MAX_POLL_SECS).contains(&secs) {
            return Err(format!("Check every {MIN_POLL_SECS} to {MAX_POLL_SECS} seconds."));
        }
        self.poll_secs = secs;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_todays_values() {
        let s = Settings::default();
        assert_eq!((s.poll_secs, s.notify, s.autostart), (60, Notify::NeedsYou, true));
        assert!(s.servers.is_empty());
    }

    #[test]
    fn poll_interval_is_bounded() {
        let mut s = Settings::default();
        assert!(s.set_poll_secs(5).is_err());
        assert!(s.set_poll_secs(100_000).is_err());
        assert!(s.set_poll_secs(120).is_ok());
        assert_eq!(s.poll_secs, 120);
    }

    #[test]
    fn file_round_trip_and_missing_fields() {
        let dir = std::env::temp_dir().join("dokkit-desktop-test-settings");
        let path = dir.join("settings.json");
        let mut s = Settings::default();
        s.poll_secs = 90;
        s.save(&path).unwrap();
        assert_eq!(Settings::load(&path), s);
        std::fs::write(&path, br#"{"poll_secs": 30}"#).unwrap();
        let loaded = Settings::load(&path);
        assert_eq!((loaded.poll_secs, loaded.notify, loaded.autostart), (30, Notify::NeedsYou, true));
        assert_eq!(Settings::load(&dir.join("none.json")), Settings::default());
    }

    #[test]
    fn corrupt_file_is_kept_aside() {
        let dir = std::env::temp_dir().join("dokkit-desktop-test-corrupt");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        std::fs::write(&path, b"{ not json").unwrap();
        assert_eq!(Settings::load(&path), Settings::default());
        assert!(!path.exists());
        let kept = std::fs::read_dir(&dir).unwrap().flatten().any(|e| {
            e.file_name().to_string_lossy().starts_with("settings.json.bad-") && std::fs::read(e.path()).unwrap() == b"{ not json"
        });
        assert!(kept);
    }

    #[test]
    fn server_missing_a_field_still_loads() {
        let dir = std::env::temp_dir().join("dokkit-desktop-test-fields");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        std::fs::write(&path, br#"{"servers":[{"id":"x","name":"A","url":"https://a.test"}]}"#).unwrap();
        let s = Settings::load(&path);
        assert_eq!(s.servers.len(), 1);
        assert!(s.servers[0].notify && s.servers[0].pin.is_none() && !s.servers[0].allow_http);
    }
}
