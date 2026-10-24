//! Public trackers handed to every app (`serverInfo.streamTrackers`).
//!
//! Most add-on magnets and many Jackett ones carry no (or only dead)
//! trackers, so the apps' engines fall back on DHT, which takes a while to
//! warm up after launch. A fresh list of working trackers lets them find
//! peers in seconds. The list is the community-maintained "best" set,
//! refreshed every 12 hours, with a built-in fallback.

use std::sync::RwLock;
use std::time::Duration;

use tracing::{info, warn};

const SOURCE: &str = "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt";
const REFRESH: Duration = Duration::from_secs(12 * 3600);
const MAX: usize = 30;

/// Used until the first download (and if it ever fails).
const FALLBACK: &[&str] = &[
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://explodie.org:6969/announce",
    "udp://tracker.theoks.net:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://tracker-udp.gbitt.info:80/announce",
    "udp://opentracker.io:6969/announce",
    "https://tracker.tamersunion.org:443/announce",
    "http://tracker.opentrackr.org:1337/announce",
];

fn store() -> &'static RwLock<Vec<String>> {
    static S: std::sync::OnceLock<RwLock<Vec<String>>> = std::sync::OnceLock::new();
    S.get_or_init(|| RwLock::new(FALLBACK.iter().map(|s| s.to_string()).collect()))
}

/// Current list (fresh after the first refresh, the fallback before it).
pub fn current() -> Vec<String> {
    store().read().map(|v| v.clone()).unwrap_or_default()
}

fn parse(body: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in body.lines() {
        let t = line.trim();
        let ok = t.starts_with("udp://") || t.starts_with("http://") || t.starts_with("https://");
        if ok && t.len() < 200 && !out.iter().any(|x| x == t) {
            out.push(t.to_string());
        }
    }
    // Keep a few known-good ones even if the published list drops them.
    for fb in FALLBACK.iter().take(4) {
        if !out.iter().any(|x| x == fb) {
            out.push(fb.to_string());
        }
    }
    out.truncate(MAX);
    out
}

async fn refresh(http: &reqwest::Client) {
    let res = http.get(SOURCE).timeout(Duration::from_secs(15)).send().await;
    match res {
        Ok(r) if r.status().is_success() => match r.text().await {
            Ok(body) => {
                let list = parse(&body);
                if list.len() >= 5 {
                    info!(count = list.len(), "refreshed public tracker list");
                    if let Ok(mut g) = store().write() {
                        *g = list;
                    }
                }
            }
            Err(e) => warn!(error = %e, "tracker list unreadable"),
        },
        Ok(r) => warn!(status = %r.status(), "tracker list download failed"),
        Err(e) => warn!(error = %e, "tracker list download failed"),
    }
}

pub fn spawn_refresh(http: reqwest::Client) {
    tokio::spawn(async move {
        loop {
            refresh(&http).await;
            tokio::time::sleep(REFRESH).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn parses_published_list() {
        let body = "udp://a.example:1337/announce\n\nudp://a.example:1337/announce\nhttp://b.example:80/announce\nwss://skip.example\n";
        let list = parse(body);
        assert_eq!(list[0], "udp://a.example:1337/announce");
        assert_eq!(list[1], "http://b.example:80/announce");
        assert!(!list.iter().any(|t| t.starts_with("wss://")));
        // Fallback anchors are appended.
        assert!(list.iter().any(|t| t.contains("opentrackr")));
    }
}
