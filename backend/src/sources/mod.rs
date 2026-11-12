//! Where playable results come from. Every source — Jackett, each enabled
//! Stremio add-on, and whatever kind of add-on comes next — implements
//! [SourceProvider]. A stream search asks all of them at once, each with its
//! own time limit, then [merge]s the answers (one entry per torrent or URL,
//! keeping the best metadata) and [rank::rank]s them with one set of rules.
//!
//! Adding a new kind of source means writing one more [SourceProvider]; the
//! fan-out, merging and ranking don't change.

pub mod rank;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use futures::stream::{FuturesUnordered, StreamExt};

use crate::graphql::types::StreamSource;

/// What every source is asked for.
#[derive(Clone, Debug, Default)]
pub struct SourceQuery {
    /// Catalog title / year / alternative names / IMDb id. Jackett searches
    /// by name; add-ons look titles up by IMDb id.
    pub target: crate::jackett::SearchTarget,
    /// TitleKind::as_db(): "movie" | "series" | "anime".
    pub kind: String,
    pub season: Option<i32>,
    pub episode: Option<i32>,
    /// Comma-separated language codes; empty = all.
    pub languages: String,
    pub resolution: String,
}

impl SourceQuery {
    /// Stremio addresses: ("movie", "tt123") or ("series", "tt123:1:2").
    pub fn stremio_id(&self) -> Option<(&'static str, String)> {
        let imdb = self.target.imdb_id.as_deref()?.trim();
        if !imdb.starts_with("tt") || imdb.len() < 3 || !imdb[2..].bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        match (self.kind.as_str(), self.season, self.episode) {
            ("movie", _, _) => Some(("movie", imdb.to_string())),
            (_, Some(s), Some(e)) => Some(("series", format!("{imdb}:{s}:{e}"))),
            _ => None,
        }
    }
}

/// One place results come from.
pub trait SourceProvider: Send + Sync {
    /// Shown in logs and on results ("Jackett", "Torrentio", …).
    fn label(&self) -> &str;
    /// Longest this source may take before the search goes on without it.
    fn timeout(&self) -> Duration;
    fn find<'a>(&'a self, query: &'a SourceQuery) -> BoxFuture<'a, Result<Vec<StreamSource>, String>>;
}

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Found(usize),
    Failed(String),
    TimedOut,
}

#[derive(Clone, Debug)]
pub struct Report {
    pub label: String,
    pub outcome: Outcome,
    pub elapsed: Duration,
}

/// Ask every provider in parallel and wait for all of them: each answers or
/// reaches its own timeout, and a failure only loses that provider's
/// results. (Stopping early once a few good results were in dropped the
/// slower sources, usually Jackett, from the list.) Results come back tagged
/// with their provider, unmerged.
pub async fn gather(
    providers: &[Box<dyn SourceProvider>],
    query: &SourceQuery,
) -> (Vec<Vec<StreamSource>>, Vec<Report>) {
    let started = Instant::now();
    let mut pending: FuturesUnordered<_> = providers
        .iter()
        .enumerate()
        .map(|(i, p)| async move {
            let r = tokio::time::timeout(p.timeout(), p.find(query)).await;
            (i, r)
        })
        .collect();
    let mut found: Vec<Vec<StreamSource>> = Vec::new();
    let mut reports: Vec<Option<Report>> = vec![None; providers.len()];

    while let Some((i, result)) = pending.next().await {
        let p = &providers[i];
        let outcome = match result {
            Ok(Ok(mut list)) => {
                for s in &mut list {
                    if s.providers.is_empty() {
                        s.providers.push(p.label().to_string());
                    }
                }
                let n = list.len();
                found.push(list);
                Outcome::Found(n)
            }
            Ok(Err(e)) => {
                tracing::warn!(source = p.label(), error = %e, "stream source failed");
                Outcome::Failed(e)
            }
            Err(_) => {
                tracing::warn!(source = p.label(), timeout_s = p.timeout().as_secs(), "stream source timed out");
                Outcome::TimedOut
            }
        };
        reports[i] = Some(Report { label: p.label().to_string(), outcome, elapsed: started.elapsed() });
    }

    // Every future ran to completion, so every provider has a report.
    let reports = reports.into_iter().flatten().collect();
    (found, reports)
}

/// What makes two results the same: the torrent's info hash (hex, lower
/// case, from the magnet's `btih` or the id) or the direct URL.
pub fn dedup_key(s: &StreamSource) -> String {
    if s.is_http() {
        return format!("url:{}", s.url.trim());
    }
    if let Some(h) = info_hash_of(&s.magnet) {
        return format!("btih:{h}");
    }
    if let Some(h) = normalize_hash(&s.id) {
        return format!("btih:{h}");
    }
    format!("id:{}", if s.magnet.trim().is_empty() { s.id.trim() } else { s.magnet.trim() })
}

/// Info hash of a magnet as 40 lower-case hex characters (base32 hashes are converted).
pub fn info_hash_of(magnet: &str) -> Option<String> {
    let lower = magnet.to_ascii_lowercase();
    let start = lower.find("urn:btih:")? + "urn:btih:".len();
    let raw: String = lower[start..].chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
    normalize_hash(&raw)
}

fn normalize_hash(raw: &str) -> Option<String> {
    let h = raw.trim().to_ascii_lowercase();
    if h.len() == 40 && h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(h);
    }
    if h.len() == 32 {
        return base32_to_hex(&h);
    }
    None
}

fn base32_to_hex(s: &str) -> Option<String> {
    let mut bits: u64 = 0;
    let mut nbits = 0;
    let mut out = String::with_capacity(40);
    for c in s.bytes() {
        let v = match c {
            b'a'..=b'z' => c - b'a',
            b'2'..=b'7' => c - b'2' + 26,
            _ => return None,
        } as u64;
        bits = (bits << 5) | v;
        nbits += 5;
        while nbits >= 4 {
            nbits -= 4;
            out.push(char::from_digit(((bits >> nbits) & 0xf) as u32, 16)?);
        }
    }
    (out.len() == 40).then_some(out)
}

/// One entry per torrent / URL across all sources, keeping the best of each
/// field: known seeders over unknown, the higher count, any size and
/// language, every tracker, and every provider that had it.
pub fn merge(lists: Vec<Vec<StreamSource>>) -> Vec<StreamSource> {
    let mut out: Vec<StreamSource> = Vec::new();
    let mut at: HashMap<String, usize> = HashMap::new();
    for src in lists.into_iter().flatten() {
        let key = dedup_key(&src);
        match at.get(&key) {
            Some(&i) => absorb(&mut out[i], src),
            None => {
                at.insert(key, out.len());
                out.push(src);
            }
        }
    }
    out
}

fn absorb(best: &mut StreamSource, other: StreamSource) {
    for p in &other.providers {
        if !best.providers.contains(p) {
            best.providers.push(p.clone());
        }
    }
    let best_known = best.health != "unknown";
    let other_known = other.health != "unknown";
    if other_known && (!best_known || other.seeders > best.seeders) {
        best.seeders = other.seeders;
        best.health = crate::jackett::health_for(other.seeders).into();
        best.rating = crate::jackett::calculate_rating(other.seeders);
        // Label the row after the source that reported the best swarm.
        best.indexer = other.indexer.clone();
        best.tracker = other.tracker.clone();
    }
    best.peers = best.peers.max(other.peers);
    if best.size_bytes == 0 && other.size_bytes > 0 {
        best.size_bytes = other.size_bytes;
        best.size = other.size.clone();
    }
    if (best.language.is_empty() || best.language == "unknown") && !other.language.is_empty() {
        best.language = other.language.clone();
    }
    if rank::detect_resolution(&best.title).is_none() && rank::detect_resolution(&other.title).is_some() {
        best.title = other.title.clone();
    }
    if best.headers.is_empty() {
        best.headers = other.headers.clone();
    }
    if !best.is_http() {
        best.magnet = merge_magnets(&best.magnet, &other.magnet);
    }
}

/// `a` plus the trackers and `so=` (file index) only `b` has.
fn merge_magnets(a: &str, b: &str) -> String {
    if !b.to_ascii_lowercase().starts_with("magnet:") {
        return a.to_string();
    }
    if !a.to_ascii_lowercase().starts_with("magnet:") {
        return b.to_string();
    }
    let params = |m: &str| -> Vec<String> {
        m.split_once('?').map(|(_, q)| q.split('&').map(str::to_string).collect()).unwrap_or_default()
    };
    let have = params(a);
    let mut out = a.to_string();
    let has_so = have.iter().any(|p| p.starts_with("so="));
    for p in params(b) {
        let add = (p.starts_with("tr=") && !have.contains(&p)) || (p.starts_with("so=") && !has_so);
        if add {
            out.push('&');
            out.push_str(&p);
        }
    }
    out
}

/// Most direct links checked per search (they're checked all at once).
const MAX_LINK_CHECKS: usize = 30;
const LINK_CHECK_TIMEOUT: Duration = Duration::from_secs(4);

/// Ask each direct link for its first byte with a Range request, as a player
/// would, and drop the ones the host refuses: expired (403), gone (404),
/// "download only" hosts that reject ranges (400 / 416), server errors. A
/// link that only times out or can't be reached from the server is kept,
/// since the device may still get through. Torrents pass through untouched.
pub async fn check_links(http: &reqwest::Client, sources: Vec<StreamSource>) -> Vec<StreamSource> {
    let checks = sources.iter().enumerate().filter(|(_, s)| s.is_http()).take(MAX_LINK_CHECKS).map(|(i, s)| {
        let mut req = http.get(&s.url).header(reqwest::header::RANGE, "bytes=0-0").timeout(LINK_CHECK_TIMEOUT);
        for h in &s.headers {
            req = req.header(h.name.as_str(), h.value.as_str());
        }
        async move {
            let refused = match req.send().await {
                // The body isn't read; dropping the response closes it.
                Ok(res) => {
                    let st = res.status();
                    (st.is_client_error() || st.is_server_error()).then(|| st.as_u16())
                }
                Err(_) => None,
            };
            (i, refused)
        }
    });
    let refused: HashMap<usize, u16> = futures::future::join_all(checks)
        .await
        .into_iter()
        .filter_map(|(i, r)| r.map(|code| (i, code)))
        .collect();
    if !refused.is_empty() {
        tracing::info!(dropped = refused.len(), "direct links refused by their hosts");
    }
    sources
        .into_iter()
        .enumerate()
        .filter(|(i, _)| !refused.contains_key(i))
        .map(|(_, s)| s)
        .collect()
}

/// Add-ons often list one file once per host (FSL, PixelDrain, …): keep the
/// first working copy of each (same add-on, same size, same name).
pub fn collapse_mirrors(sources: Vec<StreamSource>) -> Vec<StreamSource> {
    let mut seen = std::collections::HashSet::new();
    sources
        .into_iter()
        .filter(|s| {
            if !s.is_http() || s.size_bytes == 0 {
                return true;
            }
            let name: String = s.title.to_ascii_lowercase().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
            seen.insert((s.providers.first().cloned().unwrap_or_default(), s.size_bytes, name))
        })
        .collect()
}

/// Gather, merge and rank: the stream query does these steps itself, with a
/// swarm probe between merging and ranking.
#[cfg(test)]
pub async fn search(
    providers: &[Box<dyn SourceProvider>],
    query: &SourceQuery,
) -> (Vec<StreamSource>, Vec<Report>) {
    let (lists, reports) = gather(providers, query).await;
    let merged = merge(lists);
    (rank::rank(merged, &prefs(query)), reports)
}

pub fn prefs(query: &SourceQuery) -> rank::RankPrefs<'_> {
    rank::RankPrefs {
        resolution: &query.resolution,
        languages: &query.languages,
        kind: &query.kind,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HASH: &str = "0123456789abcdef0123456789abcdef01234567";

    fn src(provider: &str, hash: &str, title: &str, seeders: Option<i32>) -> StreamSource {
        let mut s = crate::jackett::external_source(title, hash, &[format!("udp://{provider}.example:80")], seeders, 0, provider, "movie", "")
            .expect("valid");
        s.providers = vec![provider.into()];
        s
    }

    struct Fake {
        label: &'static str,
        delay: Duration,
        result: Result<Vec<StreamSource>, String>,
        timeout: Duration,
    }

    impl SourceProvider for Fake {
        fn label(&self) -> &str {
            self.label
        }
        fn timeout(&self) -> Duration {
            self.timeout
        }
        fn find<'a>(&'a self, _q: &'a SourceQuery) -> BoxFuture<'a, Result<Vec<StreamSource>, String>> {
            Box::pin(async move {
                tokio::time::sleep(self.delay).await;
                self.result.clone()
            })
        }
    }

    fn fake(label: &'static str, delay_s: u64, timeout_s: u64, result: Result<Vec<StreamSource>, String>) -> Box<dyn SourceProvider> {
        Box::new(Fake { label, delay: Duration::from_secs(delay_s), timeout: Duration::from_secs(timeout_s), result })
    }

    fn movie_query() -> SourceQuery {
        SourceQuery { kind: "movie".into(), resolution: "1080p".into(), ..Default::default() }
    }

    #[test]
    fn same_torrent_from_two_sources_is_one_row_with_the_best_metadata() {
        let mut jackett = src("Jackett", HASH, "Troy.2004.BluRay.x264", Some(3));
        jackett.size_bytes = 9 * 1024 * 1024 * 1024;
        jackett.size = "9.0 GB".into();
        let mut addon = src("Torrentio", &HASH.to_uppercase(), "Troy.2004.1080p.BluRay.x264", Some(214));
        addon.magnet.push_str("&so=2");
        addon.language = "en".into();
        let merged = merge(vec![vec![jackett], vec![addon]]);
        assert_eq!(merged.len(), 1);
        let m = &merged[0];
        assert_eq!(m.seeders, 214);
        assert_eq!(m.health, "excellent");
        assert_eq!(m.indexer, "Torrentio");
        assert_eq!(m.size, "9.0 GB");
        assert_eq!(m.language, "en");
        assert_eq!(m.title, "Troy.2004.1080p.BluRay.x264");
        assert_eq!(m.providers, vec!["Jackett", "Torrentio"]);
        assert!(m.magnet.contains("udp%3A%2F%2FJackett") && m.magnet.contains("udp%3A%2F%2FTorrentio"), "{}", m.magnet);
        assert!(m.magnet.ends_with("&so=2"));
    }

    #[test]
    fn known_seeders_beat_unknown_even_when_lower() {
        let unknown = src("A", HASH, "Troy.2004.1080p.WEB", None);
        let known = src("B", HASH, "Troy.2004.1080p.WEB", Some(2));
        let m = merge(vec![vec![unknown], vec![known]]);
        assert_eq!((m[0].seeders, m[0].health.as_str()), (2, "poor"));
    }

    #[test]
    fn base32_and_hex_hashes_dedupe() {
        // Same 20 bytes, base32 vs hex.
        let hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4";
        let b32 = "4OYMIQUY7QOBJGX36TEJS35ZEQT24QPE";
        assert_eq!(base32_to_hex(&b32.to_ascii_lowercase()).as_deref(), Some(hex));
        let a = src("A", hex, "Troy.2004.1080p.WEB", Some(5));
        let mut b = a.clone();
        b.magnet = format!("magnet:?xt=urn:btih:{b32}&dn=x");
        b.id = b32.to_ascii_lowercase();
        assert_eq!(merge(vec![vec![a], vec![b]]).len(), 1);
    }

    #[test]
    fn http_streams_dedupe_by_url_and_stay_apart_from_torrents() {
        let http = StreamSource {
            id: "http:x".into(),
            title: "Troy.2004.1080p.WEB".into(),
            kind: "http".into(),
            url: "https://cdn.example/troy.mkv".into(),
            health: "unknown".into(),
            ..Default::default()
        };
        let merged = merge(vec![vec![http.clone(), src("A", HASH, "Troy.2004.1080p.WEB", Some(5))], vec![http]]);
        assert_eq!(merged.len(), 2);
    }

    fn link(url: String, title: &str, size: u64) -> StreamSource {
        StreamSource {
            id: url.clone(),
            title: title.into(),
            kind: "http".into(),
            url,
            health: "unknown".into(),
            providers: vec!["HdHub".into()],
            size_bytes: size,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn refused_direct_links_are_dropped() {
        use axum::{http::{HeaderMap, StatusCode}, routing::get, Router};
        async fn ranged(h: HeaderMap) -> (StatusCode, &'static str) {
            if h.get("range").is_some() { (StatusCode::PARTIAL_CONTENT, "x") } else { (StatusCode::OK, "xx") }
        }
        async fn needs_agent(h: HeaderMap) -> StatusCode {
            if h.get("user-agent").and_then(|v| v.to_str().ok()) == Some("Special/1.0") {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::FORBIDDEN
            }
        }
        let app = Router::new()
            .route("/ok", get(ranged))
            .route("/expired", get(|| async { StatusCode::FORBIDDEN }))
            .route("/download-only", get(|| async { StatusCode::BAD_REQUEST }))
            .route("/agent", get(needs_agent));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let mut with_agent = link(format!("{base}/agent"), "d", 1);
        with_agent.headers = vec![crate::graphql::types::StreamHeader { name: "User-Agent".into(), value: "Special/1.0".into() }];
        let list = vec![
            link(format!("{base}/ok"), "a", 1),
            link(format!("{base}/expired"), "b", 1),
            link(format!("{base}/download-only"), "c", 1),
            with_agent,
            // Unreachable from here: kept, the device may still reach it.
            link("http://127.0.0.1:9/nothing".into(), "e", 1),
            src("Jackett", HASH, "Troy.2004.1080p.BluRay", Some(5)),
        ];
        let kept = check_links(&reqwest::Client::new(), list).await;
        let titles: Vec<&str> = kept.iter().map(|s| s.title.as_str()).collect();
        assert_eq!(titles, vec!["a", "d", "e", "Troy.2004.1080p.BluRay"]);
    }

    #[test]
    fn mirrors_of_one_file_collapse_to_the_first() {
        let gb = 3 * 1024 * 1024 * 1024;
        let kept = collapse_mirrors(vec![
            link("https://fsl/a".into(), "Troy.2004.1080p.BluRay.mkv", gb),
            link("https://pixeldrain/a".into(), "Troy.2004.1080p.BluRay.mkv", gb),
            link("https://fsl/b".into(), "Troy.2004.720p.BluRay.mkv", gb / 2),
            link("https://other/a".into(), "Troy 2004 1080p BluRay (mkv)", gb),
        ]);
        let urls: Vec<&str> = kept.iter().map(|s| s.url.as_str()).collect();
        assert_eq!(urls, vec!["https://fsl/a", "https://fsl/b"]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_failing_source_does_not_break_the_others() {
        let providers = vec![
            fake("Broken", 0, 5, Err("HTTP 500".into())),
            fake("Good", 1, 5, Ok(vec![src("Good", HASH, "Troy.2004.1080p.BluRay", Some(50))])),
        ];
        let (found, reports) = search(&providers, &movie_query()).await;
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].providers, vec!["Good"]);
        assert_eq!(reports[0].outcome, Outcome::Failed("HTTP 500".into()));
        assert_eq!(reports[1].outcome, Outcome::Found(1));
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_source_times_out_without_losing_the_rest() {
        let providers = vec![
            fake("Slow", 120, 8, Ok(vec![src("Slow", HASH, "Troy.2004.1080p.BluRay", Some(50))])),
            fake("Fast", 1, 8, Ok(vec![src("Fast", "1123456789abcdef0123456789abcdef01234567", "Troy.2004.720p.WEB", Some(9))])),
        ];
        let t0 = tokio::time::Instant::now();
        let (found, reports) = search(&providers, &movie_query()).await;
        assert!(t0.elapsed() <= Duration::from_secs(9), "waited {:?}", t0.elapsed());
        assert_eq!(found.len(), 1);
        assert_eq!(reports[0].outcome, Outcome::TimedOut);
        assert_eq!(reports[1].outcome, Outcome::Found(1));
    }

    #[tokio::test(start_paused = true)]
    async fn slow_sources_are_waited_for_even_when_others_have_plenty() {
        let plenty: Vec<StreamSource> = (0..5)
            .map(|i| src("Fast", &format!("{i}123456789abcdef0123456789abcdef01234567"), &format!("Troy.2004.1080p.WEB.{i}"), Some(40)))
            .collect();
        let providers = vec![
            fake("Jackett", 50, 60, Ok(vec![src("Jackett", HASH, "Troy.2004.1080p.BluRay", Some(500))])),
            fake("Fast", 2, 10, Ok(plenty)),
        ];
        let t0 = tokio::time::Instant::now();
        let (found, reports) = search(&providers, &movie_query()).await;
        let waited = t0.elapsed();
        // Jackett answers after 50 s, within its own 60 s limit: its result
        // is in the list, not dropped because Fast already had five.
        assert!(waited >= Duration::from_secs(50) && waited < Duration::from_secs(51), "waited {waited:?}");
        assert_eq!(reports[0].outcome, Outcome::Found(1));
        // Same torrent as one of Fast's: one row that both sources found.
        assert_eq!(found.len(), 5);
        assert!(found.iter().any(|s| s.providers.iter().any(|p| p == "Jackett")));
    }

    #[tokio::test(start_paused = true)]
    async fn results_from_all_sources_are_merged_and_ranked() {
        let shared = "2123456789abcdef0123456789abcdef01234567";
        let providers = vec![
            fake("Jackett", 3, 60, Ok(vec![
                src("Jackett", shared, "Troy.2004.1080p.BluRay.x264", Some(4)),
                src("Jackett", "3123456789abcdef0123456789abcdef01234567", "Troy.2004.720p.WEB", Some(30)),
            ])),
            fake("Torrentio", 1, 10, Ok(vec![src("Torrentio", shared, "Troy.2004.1080p.BluRay.x264", Some(120))])),
        ];
        let (found, _) = search(&providers, &movie_query()).await;
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].title, "Troy.2004.1080p.BluRay.x264");
        assert_eq!(found[0].seeders, 120);
        assert_eq!(found[0].providers, vec!["Torrentio", "Jackett"]);
        assert!(found[0].score > found[1].score);
    }
}
