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
pub struct Server {
    pub id: String,
    pub name: String,
    pub url: String,
    pub notify: bool,
    pub pin: Option<String>,
    pub allow_http: bool,
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
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)
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
}
