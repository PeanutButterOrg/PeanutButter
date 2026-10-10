//! Shared public BitTorrent announce list for every client + the server torrent engine.
//!
//! Source of truth: [ngosang/trackerslist](https://github.com/ngosang/trackerslist)
//! `trackers_best.txt` (daily-checked, sorted by popularity/latency).
//! Clients must merge these into Jackett magnets — indexer `tr=` alone is not enough.

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use reqwest::Client;
use tokio::sync::RwLock;
use tracing::{info, warn};

/// Mirrors for ngosang trackers_best (newline-separated announce URLs).
const SOURCES: &[&str] = &[
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
    "https://ngosang.github.io/trackerslist/trackers_best.txt",
    "https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt",
];

const REFRESH_EVERY: Duration = Duration::from_secs(12 * 60 * 60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(12);

/// Offline / boot fallback — same set as ngosang trackers_best (2026-10-10 snapshot).
const EMBEDDED_BEST: &[&str] = &[
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.skynetcloud.site:6969/announce",
    "udp://tracker.qu.ax:6969/announce",
    "udp://tracker.tryhackx.org:6969/announce",
    "udp://tracker.corpscorp.online:80/announce",
    "udp://tracker.bittor.pw:1337/announce",
    "udp://tracker.nyaa.vc:6969/announce",
    "udp://tracker-udp.gbitt.info:80/announce",
    "udp://tracker.ducks.party:1984/announce",
    "udp://explodie.org:6969/announce",
    "udp://tracker2.dler.org:80/announce",
    "udp://tracker.gmi.gd:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://retracker01-msk-virt.corbina.net:80/announce",
    "http://tracker.dler.com:6969/announce",
    "http://tracker.renfei.net:8080/announce",
];

static GLOBAL: OnceLock<Arc<TrackerList>> = OnceLock::new();

#[derive(Clone)]
pub struct TrackerList {
    http: Client,
    inner: Arc<RwLock<Cache>>,
}

struct Cache {
    trackers: Vec<String>,
    fetched_at: Option<Instant>,
}

impl TrackerList {
    pub fn new(http: Client) -> Arc<Self> {
        let this = Arc::new(Self {
            http,
            inner: Arc::new(RwLock::new(Cache {
                trackers: embedded_best(),
                fetched_at: None,
            })),
        });
        let _ = GLOBAL.set(this.clone());
        this
    }

    /// Non-empty announce list (live cache or embedded).
    pub async fn list(&self) -> Vec<String> {
        let g = self.inner.read().await;
        if g.trackers.is_empty() {
            embedded_best()
        } else {
            g.trackers.clone()
        }
    }

    pub async fn refresh(&self) {
        match fetch_best(&self.http).await {
            Ok(list) if !list.is_empty() => {
                let n = list.len();
                let mut g = self.inner.write().await;
                g.trackers = list;
                g.fetched_at = Some(Instant::now());
                info!(count = n, "refreshed ngosang trackers_best");
            }
            Ok(_) => warn!("ngosang trackers_best was empty — keeping previous list"),
            Err(e) => warn!(error = %e, "failed to refresh ngosang trackers_best"),
        }
    }

    pub fn spawn_refresh_loop(self: &Arc<Self>) {
        let this = self.clone();
        tokio::spawn(async move {
            this.refresh().await;
            let mut tick = tokio::time::interval(REFRESH_EVERY);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                this.refresh().await;
            }
        });
    }
}

/// Sync snapshot for the torrent engine (never empty).
pub fn current() -> Vec<String> {
    if let Some(g) = GLOBAL.get() {
        if let Ok(guard) = g.inner.try_read() {
            if !guard.trackers.is_empty() {
                return guard.trackers.clone();
            }
        }
    }
    embedded_best()
}

pub fn embedded_best() -> Vec<String> {
    EMBEDDED_BEST.iter().map(|s| (*s).to_string()).collect()
}

async fn fetch_best(http: &Client) -> Result<Vec<String>, String> {
    let mut last_err = "no tracker mirrors tried".to_string();
    for url in SOURCES {
        match http.get(*url).timeout(FETCH_TIMEOUT).send().await {
            Ok(res) if res.status().is_success() => match res.text().await {
                Ok(body) => {
                    let list = parse_tracker_list(&body);
                    if !list.is_empty() {
                        return Ok(list);
                    }
                    last_err = format!("{url}: empty body");
                }
                Err(e) => last_err = format!("{url}: {e}"),
            },
            Ok(res) => last_err = format!("{url}: HTTP {}", res.status()),
            Err(e) => last_err = format!("{url}: {e}"),
        }
    }
    Err(last_err)
}

fn parse_tracker_list(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in body.lines() {
        let tr = line.trim();
        if tr.is_empty() || tr.starts_with('#') {
            continue;
        }
        if !(tr.starts_with("udp://")
            || tr.starts_with("http://")
            || tr.starts_with("https://")
            || tr.starts_with("ws://")
            || tr.starts_with("wss://"))
        {
            continue;
        }
        if seen.insert(tr.to_ascii_lowercase()) {
            out.push(tr.to_string());
        }
        if out.len() >= 40 {
            break;
        }
    }
    out
}
