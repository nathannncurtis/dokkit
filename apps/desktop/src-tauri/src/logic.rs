use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use url::{Host, Url};

pub fn validate_url(input: &str, allow_http: bool) -> Result<String, String> {
    let url = Url::parse(input.trim()).map_err(|_| "That is not a web address.".to_string())?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("Leave the user name and password out of the address.".into());
    }
    let local = match url.host() {
        Some(Host::Domain(d)) => d == "localhost" || d.ends_with(".local"),
        Some(Host::Ipv4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Some(Host::Ipv6(ip)) => ip.is_loopback(),
        None => return Err("The address has no host.".into()),
    };
    match url.scheme() {
        "https" => {}
        "http" if allow_http && local => {}
        "http" if allow_http => {
            return Err("Plain http is only allowed for localhost and local network addresses.".into())
        }
        "http" => return Err("The address must start with https://.".into()),
        _ => return Err("The address must start with https://.".into()),
    }
    Ok(url.origin().ascii_serialization())
}

pub fn parse_pin(pin: &str) -> Option<[u8; 32]> {
    let hex: String = pin.trim().trim_start_matches("sha256:").chars().filter(|c| *c != ':').collect();
    if hex.len() != 64 || !hex.is_ascii() {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

pub fn normalise_pin(pin: &str) -> Option<String> {
    parse_pin(pin).map(|b| format!("sha256:{}", b.iter().map(|x| format!("{x:02x}")).collect::<String>()))
}

pub fn fingerprint(der: &[u8]) -> String {
    let sum = Sha256::digest(der);
    let hex: String = sum.iter().map(|b| format!("{b:02x}")).collect();
    format!("sha256:{hex}")
}

pub fn pin_matches(pin: &str, der: &[u8]) -> bool {
    parse_pin(pin).is_some_and(|want| want[..] == Sha256::digest(der)[..])
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct Issue {
    pub id: String,
    #[serde(default)]
    pub short_id: String,
    #[serde(default)]
    pub soon: bool,
    #[serde(default)]
    pub title: String,
    pub snoozed_until: Option<String>,
    pub service: Option<String>,
}

fn snoozed(i: &Issue, now: DateTime<Utc>) -> bool {
    i.snoozed_until
        .as_deref()
        .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
        .is_some_and(|t| t > now)
}

/// The web inbox's "Needs you": open, not snoozed, not soon, and not on a service outside production.
/// `production` holds the ids returned by the `environment=production` query.
pub fn needs_you(all: &[Issue], production: &HashSet<String>, now: DateTime<Utc>) -> Vec<Issue> {
    all.iter()
        .filter(|i| !i.soon && !snoozed(i, now) && (i.service.is_none() || production.contains(&i.id)))
        .cloned()
        .collect()
}

pub fn awake(all: &[Issue], now: DateTime<Utc>) -> Vec<Issue> {
    all.iter().filter(|i| !snoozed(i, now)).cloned().collect()
}

/// Issues in `candidates` that were not in the notify set at the last poll. Nothing is new before the first poll.
pub fn fresh(prev: Option<&HashSet<String>>, candidates: &[Issue]) -> Vec<Issue> {
    match prev {
        None => vec![],
        Some(prev) => candidates.iter().filter(|i| !prev.contains(&i.id)).cloned().collect(),
    }
}

#[cfg(any(target_os = "macos", test))]
/// `host:port` of a server address, the key its pinned certificate is stored under.
pub fn pin_key(url: &str) -> Option<String> {
    let u = Url::parse(url).ok()?;
    Some(format!("{}:{}", u.host_str()?.to_lowercase(), u.port_or_known_default()?))
}

pub fn issue_path(i: &Issue) -> String {
    i.service.as_ref().map_or("/".into(), |s| format!("/s/{s}"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Fine,
    Down,
    Needs,
}

pub fn worst(levels: &[Level]) -> Level {
    levels.iter().copied().max().unwrap_or(Level::Fine)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn issue(id: &str, soon: bool, snooze: Option<&str>, service: Option<&str>) -> Issue {
        Issue {
            id: id.into(),
            short_id: String::new(),
            soon,
            title: id.into(),
            snoozed_until: snooze.map(Into::into),
            service: service.map(Into::into),
        }
    }

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-20T12:00:00Z").unwrap().into()
    }

    #[test]
    fn https_only_by_default() {
        assert_eq!(validate_url("https://acme.dokkit.page/", false).unwrap(), "https://acme.dokkit.page");
        assert!(validate_url("http://acme.dokkit.page", false).is_err());
        assert!(validate_url("http://localhost:4000", false).is_err());
        assert!(validate_url("ftp://acme.dokkit.page", true).is_err());
        assert!(validate_url("acme.dokkit.page", false).is_err());
        assert!(validate_url("https://user:pw@acme.dokkit.page", false).is_err());
    }

    #[test]
    fn plain_http_needs_the_tick_and_a_local_host() {
        assert_eq!(validate_url("http://localhost:4000/x", true).unwrap(), "http://localhost:4000");
        assert!(validate_url("http://10.1.2.3", true).is_ok());
        assert!(validate_url("http://192.168.1.5:8080", true).is_ok());
        assert!(validate_url("http://8.8.8.8", true).is_err());
        assert!(validate_url("http://acme.dokkit.page", true).is_err());
    }

    #[test]
    fn pins_parse_and_match() {
        let der = b"certificate bytes";
        let pin = fingerprint(der);
        assert!(pin.starts_with("sha256:") && pin.len() == 71);
        assert!(pin_matches(&pin, der));
        assert!(pin_matches(&pin.to_uppercase().replace("SHA256", "sha256"), der));
        assert!(pin_matches(&pin["sha256:".len()..], der));
        assert!(!pin_matches(&pin, b"other"));
        assert_eq!(normalise_pin(&pin.to_uppercase().replace("SHA256", "sha256")).unwrap(), pin);
        assert!(parse_pin("sha256:abcd").is_none());
        assert!(parse_pin("sha256:zz").is_none());
        let colons: Vec<String> = pin["sha256:".len()..].as_bytes().chunks(2).map(|c| String::from_utf8_lossy(c).into()).collect();
        assert!(pin_matches(&colons.join(":"), der));
    }

    #[test]
    fn needs_you_matches_the_inbox() {
        let all = vec![
            issue("a", false, None, Some("s1")),
            issue("b", true, None, Some("s2")),
            issue("c", false, Some("2026-10-20T13:00:00Z"), Some("s3")),
            issue("d", false, Some("2026-10-20T11:00:00Z"), Some("s4")),
            issue("e", false, None, Some("s5")),
            issue("f", false, None, None),
        ];
        let production: HashSet<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let ids: Vec<_> = needs_you(&all, &production, now()).into_iter().map(|i| i.id).collect();
        assert_eq!(ids, ["a", "d", "f"]);
    }

    #[test]
    fn awake_drops_only_snoozed() {
        let all = vec![issue("a", true, None, None), issue("c", false, Some("2026-10-20T13:00:00Z"), None)];
        assert_eq!(awake(&all, now()).len(), 1);
    }

    #[test]
    fn new_issues_between_polls() {
        let now_issues = vec![issue("a", false, None, None), issue("b", false, None, None)];
        assert!(fresh(None, &now_issues).is_empty());
        let seen: HashSet<String> = ["a".to_string()].into();
        let ids: Vec<_> = fresh(Some(&seen), &now_issues).into_iter().map(|i| i.id).collect();
        assert_eq!(ids, ["b"]);
    }

    #[test]
    fn issues_entering_the_notify_set_are_fresh() {
        let (a, b) = (issue("a", false, None, None), issue("b", false, None, None));
        // b was open but outside the notify set last poll (soon or snoozed), so it is new when it enters
        let last: HashSet<String> = ["a".to_string()].into();
        assert_eq!(fresh(Some(&last), &[a.clone(), b.clone()]), [b.clone()]);
        let now_both: HashSet<String> = ["a".to_string(), "b".to_string()].into();
        assert!(fresh(Some(&now_both), &[a, b]).is_empty());
    }

    #[test]
    fn pins_are_keyed_by_host_and_port() {
        assert_eq!(pin_key("https://Acme.Test").as_deref(), Some("acme.test:443"));
        assert_eq!(pin_key("https://acme.test:8443").as_deref(), Some("acme.test:8443"));
        assert_ne!(pin_key("https://acme.test:8443"), pin_key("https://acme.test:9443"));
    }

    #[test]
    fn issue_pages() {
        assert_eq!(issue_path(&issue("a", false, None, Some("s1"))), "/s/s1");
        assert_eq!(issue_path(&issue("a", false, None, None)), "/");
    }

    #[test]
    fn worst_level_wins() {
        assert_eq!(worst(&[]), Level::Fine);
        assert_eq!(worst(&[Level::Fine, Level::Needs]), Level::Needs);
        assert_eq!(worst(&[Level::Needs, Level::Down, Level::Fine]), Level::Needs);
        assert_eq!(worst(&[Level::Fine, Level::Down]), Level::Down);
    }
}
