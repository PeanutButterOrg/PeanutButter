//! Stremio stream add-ons (Torrentio and anything that speaks the same API),
//! installed from the console by manifest URL.
//!
//! Torrents come from Jackett, from add-ons, or both — any one is enough.
//! Without Jackett the enabled add-ons are the source. With Jackett they are
//! asked only when it finds nothing reliable (no source with at least
//! `min_seeders`), and their torrents are merged into the same ranked list. Add-ons only return magnets (info hash + trackers); playback
//! still goes through this server's torrent engine, nothing runs on devices.
//!
//! Stremio add-on protocol: GET {base}/manifest.json describes the add-on,
//! GET {base}/stream/{movie|series}/{imdb}[:{season}:{episode}].json lists
//! streams as `{infoHash, title, behaviorHints.filename, sources[]}`.

use std::sync::{OnceLock, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sqlx::PgPool;

use crate::error::{AppError, Result};
use crate::graphql::types::StreamSource;

pub const TORRENTIO_URL: &str = "https://torrentio.strem.fun";
const DEFAULT_MIN_SEEDERS: i32 = 5;
const ADDON_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_PER_ADDON: usize = 30;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Addon {
    pub id: String,
    pub name: String,
    /// Base URL without the trailing `/manifest.json`.
    pub url: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderSettings {
    /// Unused since add-ons became a source of their own (kept so settings
    /// saved by older builds still parse).
    #[serde(default)]
    pub enabled: bool,
    /// Jackett results with fewer seeders than this don't count as reliable.
    #[serde(default = "default_min_seeders")]
    pub min_seeders: i32,
    #[serde(default)]
    pub addons: Vec<Addon>,
}

impl Default for ProviderSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            min_seeders: DEFAULT_MIN_SEEDERS,
            addons: Vec::new(),
        }
    }
}

fn yes() -> bool {
    true
}

fn default_min_seeders() -> i32 {
    DEFAULT_MIN_SEEDERS
}

fn store() -> &'static RwLock<ProviderSettings> {
    static S: OnceLock<RwLock<ProviderSettings>> = OnceLock::new();
    S.get_or_init(|| RwLock::new(ProviderSettings::default()))
}

pub fn snapshot() -> ProviderSettings {
    store().read().expect("providers lock").clone()
}

/// At least one add-on is installed and enabled.
pub fn active() -> bool {
    store().read().expect("providers lock").addons.iter().any(|a| a.enabled)
}

/// Load saved settings at start-up (missing / unreadable = defaults).
pub async fn load(pool: &PgPool) -> Result<()> {
    let row: Option<(Option<serde_json::Value>,)> =
        sqlx::query_as("SELECT stream_providers FROM app_settings WHERE id = 1")
            .fetch_optional(pool)
            .await?;
    let settings = row
        .and_then(|(v,)| v)
        .and_then(|v| serde_json::from_value::<ProviderSettings>(v).ok())
        .unwrap_or_default();
    *store().write().expect("providers lock") = settings;
    Ok(())
}

async fn save(pool: &PgPool, next: ProviderSettings) -> Result<()> {
    let value = serde_json::to_value(&next).map_err(|e| AppError::Internal(e.to_string()))?;
    sqlx::query(
        r#"
        INSERT INTO app_settings (id, stream_providers, updated_at)
        VALUES (1, $1, NOW())
        ON CONFLICT (id) DO UPDATE
        SET stream_providers = EXCLUDED.stream_providers, updated_at = NOW()
        "#,
    )
    .bind(value)
    .execute(pool)
    .await?;
    *store().write().expect("providers lock") = next;
    Ok(())
}

pub async fn set_min_seeders(pool: &PgPool, min_seeders: i32) -> Result<()> {
    let mut next = snapshot();
    next.min_seeders = min_seeders.clamp(1, 500);
    save(pool, next).await
}

pub async fn toggle(pool: &PgPool, id: &str) -> Result<bool> {
    let mut next = snapshot();
    let Some(addon) = next.addons.iter_mut().find(|a| a.id == id) else {
        return Err(AppError::NotFound("That source is no longer installed.".into()));
    };
    addon.enabled = !addon.enabled;
    let now = addon.enabled;
    save(pool, next).await?;
    Ok(now)
}

pub async fn remove(pool: &PgPool, id: &str) -> Result<()> {
    let mut next = snapshot();
    next.addons.retain(|a| a.id != id);
    save(pool, next).await
}

/// `stremio://host/…/manifest.json`, `https://host/…/manifest.json` or a bare
/// base URL → `https://host/…` (no trailing slash, no manifest.json).
pub fn normalize_url(raw: &str) -> Result<String> {
    let mut url = raw.trim().to_string();
    if let Some(rest) = url.strip_prefix("stremio://") {
        url = format!("https://{rest}");
    }
    if !url.contains("://") {
        url = format!("https://{url}");
    }
    let parsed = reqwest::Url::parse(&url)
        .map_err(|_| AppError::BadRequest("That doesn't look like an add-on URL.".into()))?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err(AppError::BadRequest("Add-on URLs must start with http:// or https://.".into()));
    }
    let mut out = url.trim_end_matches('/').to_string();
    if let Some(base) = out.strip_suffix("/manifest.json") {
        out = base.to_string();
    }
    Ok(out.trim_end_matches('/').to_string())
}

#[derive(Deserialize)]
struct Manifest {
    #[serde(default)]
    name: String,
    #[serde(default)]
    resources: Vec<serde_json::Value>,
    #[serde(default)]
    types: Vec<String>,
    #[serde(default, rename = "idPrefixes")]
    id_prefixes: Option<Vec<String>>,
}

/// Fetch and check the add-on's manifest, then install it (enabled).
pub async fn add(pool: &PgPool, http: &reqwest::Client, raw_url: &str) -> Result<String> {
    let base = normalize_url(raw_url)?;
    if snapshot().addons.iter().any(|a| a.url.eq_ignore_ascii_case(&base)) {
        return Err(AppError::BadRequest("That add-on is already installed.".into()));
    }
    let manifest: Manifest = http
        .get(format!("{base}/manifest.json"))
        .timeout(ADDON_TIMEOUT)
        .send()
        .await
        .map_err(|e| AppError::BadRequest(format!("Couldn't reach the add-on: {e}")))?
        .error_for_status()
        .map_err(|e| AppError::BadRequest(format!("The add-on answered with an error: {e}")))?
        .json()
        .await
        .map_err(|_| AppError::BadRequest("That URL isn't a Stremio add-on manifest.".into()))?;

    let has_streams = manifest.resources.iter().any(|r| {
        r.as_str() == Some("stream")
            || r.get("name").and_then(|n| n.as_str()) == Some("stream")
    });
    if !has_streams {
        return Err(AppError::BadRequest(
            "This add-on doesn't provide streams, so it can't be used as a torrent source.".into(),
        ));
    }
    if !manifest.types.iter().any(|t| t == "movie" || t == "series") {
        return Err(AppError::BadRequest("This add-on has no movies or series.".into()));
    }
    if let Some(prefixes) = &manifest.id_prefixes {
        if !prefixes.iter().any(|p| p.starts_with("tt")) {
            return Err(AppError::BadRequest(
                "This add-on doesn't look up titles by IMDb id, which PeanutButter needs.".into(),
            ));
        }
    }
    let name = if manifest.name.trim().is_empty() {
        reqwest::Url::parse(&base)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_else(|| "Add-on".into())
    } else {
        manifest.name.trim().chars().take(60).collect()
    };
    let mut next = snapshot();
    next.addons.push(Addon {
        id: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(),
        name: name.clone(),
        url: base,
        enabled: true,
    });
    save(pool, next).await?;
    Ok(name)
}

/// True when add-ons should be asked: none of `found` (Jackett's results,
/// empty without Jackett) is reliable enough.
pub fn needs_fallback(found: &[StreamSource]) -> bool {
    let s = snapshot();
    if !s.addons.iter().any(|a| a.enabled) {
        return false;
    }
    !found
        .iter()
        .any(|src| src.health != "unknown" && src.seeders >= s.min_seeders)
}

#[derive(Deserialize)]
struct StreamsResponse {
    #[serde(default)]
    streams: Vec<AddonStream>,
}

#[derive(Deserialize)]
struct AddonStream {
    #[serde(default, rename = "infoHash")]
    info_hash: Option<String>,
    /// Which file in the torrent is this episode / movie (season packs).
    #[serde(default, rename = "fileIdx")]
    file_idx: Option<u32>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    sources: Vec<String>,
    #[serde(default, rename = "behaviorHints")]
    behavior_hints: Option<serde_json::Value>,
}

/// Ask every enabled add-on for this title in parallel; slow or broken
/// add-ons are skipped after a few seconds.
pub async fn search(
    http: &reqwest::Client,
    imdb_id: &str,
    // TitleKind::as_db(): "movie" | "series" | "anime".
    kind: &str,
    season: Option<i32>,
    episode: Option<i32>,
    preferred_language: &str,
) -> Vec<StreamSource> {
    let imdb = imdb_id.trim();
    if !imdb.starts_with("tt") || !imdb[2..].bytes().all(|b| b.is_ascii_digit()) {
        return Vec::new();
    }
    let (stremio_type, id) = match (kind, season, episode) {
        ("movie", _, _) => ("movie", imdb.to_string()),
        (_, Some(s), Some(e)) => ("series", format!("{imdb}:{s}:{e}")),
        _ => return Vec::new(),
    };
    let addons: Vec<Addon> = snapshot().addons.into_iter().filter(|a| a.enabled).collect();
    let calls = addons.iter().map(|addon| {
        let url = format!("{}/stream/{stremio_type}/{id}.json", addon.url);
        async move {
            let res = http.get(&url).timeout(ADDON_TIMEOUT).send().await;
            let parsed = match res {
                Ok(r) if r.status().is_success() => r.json::<StreamsResponse>().await.ok(),
                Ok(r) => {
                    tracing::warn!(addon = %addon.name, status = %r.status(), "fallback source error");
                    None
                }
                Err(e) => {
                    tracing::warn!(addon = %addon.name, error = %e, "fallback source unreachable");
                    None
                }
            };
            parsed
                .map(|p| {
                    p.streams
                        .into_iter()
                        .filter_map(|s| to_source(s, &addon.name, kind, preferred_language))
                        .take(MAX_PER_ADDON)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        }
    });
    futures::future::join_all(calls).await.into_iter().flatten().collect()
}

fn to_source(s: AddonStream, addon: &str, kind: &str, preferred_language: &str) -> Option<StreamSource> {
    // Direct HTTP links (debrid, hosters) aren't torrents; skip them.
    let hash = s.info_hash?;
    let text = s.title.or(s.description).unwrap_or_default();
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.next().unwrap_or_default().to_string();
    let filename = s
        .behavior_hints
        .as_ref()
        .and_then(|h| h.get("filename"))
        .and_then(|f| f.as_str())
        .map(str::to_string);
    let release = if first.is_empty() || first.starts_with('👤') {
        filename.clone().unwrap_or_default()
    } else {
        first
    };
    let seeders = number_after(&text, "👤").map(|n| n as i32);
    let bytes = size_after(&text, "💾").unwrap_or(0);
    let origin = text
        .split("⚙️")
        .nth(1)
        .map(|rest| rest.lines().next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty());
    let label = match origin {
        Some(o) => format!("{addon} · {o}"),
        None => match s.name.as_deref().map(|n| n.lines().next().unwrap_or("").trim()) {
            Some(n) if !n.is_empty() && !n.eq_ignore_ascii_case(addon) => format!("{addon} · {n}"),
            _ => addon.to_string(),
        },
    };
    let trackers: Vec<String> = s
        .sources
        .iter()
        .filter_map(|src| src.strip_prefix("tracker:").map(str::to_string))
        .collect();
    let file_idx = s.file_idx;
    crate::jackett::external_source(
        &release,
        &hash,
        &trackers,
        seeders,
        bytes,
        &label,
        kind,
        preferred_language,
    )
    .map(|mut src| {
        // BEP 53 select-only: apps read it to play the exact file of a
        // season pack (and libtorrent itself skips the other files).
        if let Some(i) = file_idx {
            src.magnet.push_str(&format!("&so={i}"));
        }
        src
    })
}

fn number_after(text: &str, marker: &str) -> Option<u64> {
    let rest = text.split(marker).nth(1)?.trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn size_after(text: &str, marker: &str) -> Option<u64> {
    let rest = text.split(marker).nth(1)?.trim_start();
    let num: String = rest
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.' || *c == ',')
        .collect();
    let value: f64 = num.replace(',', ".").parse().ok()?;
    let unit = rest[num.len()..].trim_start().to_ascii_uppercase();
    let mult = if unit.starts_with("TB") {
        1024f64.powi(4)
    } else if unit.starts_with("GB") {
        1024f64.powi(3)
    } else if unit.starts_with("MB") {
        1024f64.powi(2)
    } else if unit.starts_with("KB") {
        1024.0
    } else {
        return None;
    };
    Some((value * mult) as u64)
}

/// Info hash of a magnet (lower-case), for merging duplicate results.
pub fn info_hash_of(magnet: &str) -> Option<String> {
    let lower = magnet.to_ascii_lowercase();
    let start = lower.find("urn:btih:")? + "urn:btih:".len();
    let hash: String = lower[start..].chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
    (!hash.is_empty()).then_some(hash)
}

/// Jackett results plus add-on results, one entry per torrent, best first.
pub fn merge(mut primary: Vec<StreamSource>, extra: Vec<StreamSource>, preferred_res: &str) -> Vec<StreamSource> {
    let mut seen: std::collections::HashSet<String> =
        primary.iter().filter_map(|s| info_hash_of(&s.magnet)).collect();
    for src in extra {
        let key = info_hash_of(&src.magnet).unwrap_or_else(|| src.id.clone());
        if seen.insert(key) {
            primary.push(src);
        }
    }
    crate::jackett::rank_sources(primary, preferred_res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_manifest_urls() {
        assert_eq!(
            normalize_url("stremio://torrentio.strem.fun/manifest.json").unwrap(),
            "https://torrentio.strem.fun"
        );
        assert_eq!(
            normalize_url("https://torrentio.strem.fun/providers=yts,eztv/manifest.json").unwrap(),
            "https://torrentio.strem.fun/providers=yts,eztv"
        );
        assert_eq!(normalize_url("torrentio.strem.fun/").unwrap(), "https://torrentio.strem.fun");
        assert!(normalize_url("ftp://x/manifest.json").is_err());
    }

    #[test]
    fn parses_torrentio_stream() {
        let s: AddonStream = serde_json::from_value(serde_json::json!({
            "name": "Torrentio\n1080p",
            "title": "Troy.2004.Directors.Cut.1080p.BluRay.x264-AMIABLE\n👤 214 💾 12.3 GB ⚙️ ThePirateBay",
            "infoHash": "0123456789abcdef0123456789abcdef01234567",
            "fileIdx": 0,
            "behaviorHints": { "filename": "Troy.2004.Directors.Cut.1080p.BluRay.x264-AMIABLE.mkv" },
            "sources": ["tracker:udp://tracker.opentrackr.org:1337/announce", "dht:0123456789abcdef0123456789abcdef01234567"]
        }))
        .unwrap();
        let src = to_source(s, "Torrentio", "movie", "").expect("kept");
        assert!(src.magnet.ends_with("&so=0"), "{}", src.magnet);
        assert_eq!(src.seeders, 214);
        assert_eq!(src.health, "excellent");
        assert_eq!(src.size, "12.3 GB");
        assert_eq!(src.indexer, "Torrentio · ThePirateBay");
        assert!(src.title.starts_with("Troy.2004"));
        assert!(src.magnet.starts_with("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn="));
        assert!(src.magnet.contains("&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"));
    }

    #[test]
    fn skips_http_only_and_cam_streams() {
        let http: AddonStream = serde_json::from_value(serde_json::json!({
            "title": "Troy.2004.1080p.WEB\n👤 9", "url": "https://example.com/a.mkv"
        }))
        .unwrap();
        assert!(to_source(http, "X", "movie", "").is_none());
        let cam: AddonStream = serde_json::from_value(serde_json::json!({
            "title": "Troy.2004.HDCAM.x264\n👤 900 💾 1.4 GB",
            "infoHash": "0123456789abcdef0123456789abcdef01234567"
        }))
        .unwrap();
        assert!(to_source(cam, "X", "movie", "").is_none());
    }

    /// Network test against the real Torrentio: `cargo test -- --ignored live_torrentio`.
    #[tokio::test]
    #[ignore]
    async fn live_torrentio() {
        *store().write().unwrap() = ProviderSettings {
            enabled: false,
            min_seeders: 5,
            addons: vec![Addon {
                id: "t".into(),
                name: "Torrentio".into(),
                url: TORRENTIO_URL.into(),
                enabled: true,
            }],
        };
        let http = reqwest::Client::new();
        let movie = search(&http, "tt0332452", "movie", None, None, "en").await;
        let episode = search(&http, "tt0903747", "series", Some(1), Some(1), "en").await;
        for src in movie.iter().take(3).chain(episode.iter().take(3)) {
            println!("{:>5} {:>9} {:<28} {}", src.seeders, src.size, src.indexer, src.title);
        }
        assert!(!movie.is_empty(), "no movie results");
        assert!(!episode.is_empty(), "no episode results");
        assert!(movie.iter().all(|s| s.magnet.starts_with("magnet:?xt=urn:btih:")));
    }

    #[test]
    fn merge_drops_duplicate_hashes() {
        let a = crate::jackett::external_source(
            "Troy.2004.1080p.BluRay.x264", "0123456789abcdef0123456789abcdef01234567",
            &[], Some(3), 0, "Jackett", "movie", "",
        )
        .unwrap();
        let mut b = a.clone();
        b.indexer = "Torrentio".into();
        b.seeders = 50;
        let merged = merge(vec![a], vec![b], "1080p");
        assert_eq!(merged.len(), 1);
    }
}
