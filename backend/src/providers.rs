//! Stremio add-ons (Torrentio, HDHub, MediaFusion, one you host, …),
//! installed from the console by manifest URL, and the Stremio add-on
//! protocol client that asks them for streams.
//!
//! Every enabled add-on is a [crate::sources::SourceProvider] next to Jackett:
//! a stream search asks them all in parallel and merges the answers (see
//! `crate::sources`).
//!
//! Protocol (https://github.com/Stremio/stremio-addon-sdk/tree/master/docs):
//! - `GET {base}/manifest.json`: `resources` (strings or `{name, types,
//!   idPrefixes}` objects), `types`, `idPrefixes`, `behaviorHints`
//!   (`configurable`, `configurationRequired`).
//! - `GET {base}/stream/{type}/{id}.json` with `id` = `tt…` for movies and
//!   `tt…:{season}:{episode}` for series, answering `{streams: [Stream]}`.
//! - A Stream is exactly one of `infoHash` (+ `fileIdx`, `sources`), `url`
//!   (direct HTTP video, or a magnet), `ytId` or `externalUrl`; with `name`,
//!   `description` (or the older `title`) and `behaviorHints` (`filename`,
//!   `videoSize`, `bingeGroup`, `notWebReady`, `proxyHeaders.request`, …).
//!
//! Torrents become magnets the apps play with libtorrent. Direct HTTP
//! streams are passed to the apps as `kind: "http"` with their request
//! headers and played as is. `ytId` / `externalUrl` streams open other apps
//! or web pages, so they are left out.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::PgPool;

use crate::error::{AppError, Result};
use crate::graphql::types::{StreamHeader, StreamSource};
use crate::sources::{SourceProvider, SourceQuery};

pub const TORRENTIO_URL: &str = "https://torrentio.strem.fun";
const DEFAULT_MIN_SEEDERS: i32 = 5;
/// Each add-on gets this long per stream request before the search goes on without it.
pub const ADDON_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PER_ADDON: usize = 40;
/// Searches for each preferred language (and the picker's refresh) ask the
/// same add-on the same thing within seconds; reuse the answer briefly.
const RESPONSE_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Addon {
    pub id: String,
    pub name: String,
    /// Base URL without the trailing `/manifest.json`.
    pub url: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// Content types its `stream` resource serves ("movie", "series", …);
    /// empty = not recorded (installed by an older build): ask for anything.
    #[serde(default)]
    pub types: Vec<String>,
    /// Id prefixes its `stream` resource understands ("tt", "kitsu:", …);
    /// empty = any.
    #[serde(default, rename = "idPrefixes")]
    pub id_prefixes: Vec<String>,
    /// Serves the `stream` resource (a stream source). Add-ons saved by
    /// older builds were all stream add-ons.
    #[serde(default = "yes")]
    pub streams: bool,
    /// Title lists it serves ("Netflix" movies, …), mixed into Trending.
    #[serde(default)]
    pub catalogs: Vec<AddonCatalog>,
}

/// One list from an add-on's manifest `catalogs`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AddonCatalog {
    /// "movie" | "series".
    #[serde(rename = "type")]
    pub kind: String,
    pub id: String,
    pub name: String,
}

impl Addon {
    /// Whether this add-on can answer `/stream/{stremio_type}/{id}.json`.
    pub fn serves(&self, stremio_type: &str, id: &str) -> bool {
        (self.types.is_empty() || self.types.iter().any(|t| t == stremio_type))
            && (self.id_prefixes.is_empty() || self.id_prefixes.iter().any(|p| id.starts_with(p.as_str())))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderSettings {
    /// Unused since add-ons became a source of their own (kept so settings
    /// saved by older builds still parse).
    #[serde(default)]
    pub enabled: bool,
    /// Unused since every source is asked at once (add-ons used to be asked
    /// only when Jackett had nothing with this many seeders). Kept so older
    /// settings still parse.
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

/// At least one stream add-on is installed and enabled.
pub fn active() -> bool {
    store().read().expect("providers lock").addons.iter().any(|a| a.enabled && a.streams)
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


/// What the console needs from a manifest to install an add-on.
#[derive(Debug, PartialEq)]
struct Capability {
    name: String,
    /// Stream resource: content types and id prefixes (empty when no streams).
    types: Vec<String>,
    id_prefixes: Vec<String>,
    streams: bool,
    catalogs: Vec<AddonCatalog>,
}

/// Check a manifest per the protocol. It must serve streams for movies or
/// series by IMDb id, or movie / series catalogs that can be listed without
/// extra input (no required search or genre), and not still need configuring.
fn capability(manifest: &Value) -> std::result::Result<Capability, String> {
    let streams = stream_capability(manifest);
    let catalogs = usable_catalogs(manifest);
    let name = manifest
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(|n| n.chars().take(60).collect())
        .unwrap_or_default();
    match streams {
        Ok(cap) => Ok(Capability { catalogs, ..cap }),
        Err(e) if catalogs.is_empty() => Err(e),
        Err(e) if e.contains("configured first") => Err(e),
        Err(_) => Ok(Capability { name, types: vec![], id_prefixes: vec![], streams: false, catalogs }),
    }
}

/// Movie / series catalogs that list without extra input; a catalog whose
/// `extra` marks search / genre / … as required is only for searching.
fn usable_catalogs(manifest: &Value) -> Vec<AddonCatalog> {
    let serves_catalogs = manifest.get("resources").and_then(Value::as_array).is_some_and(|r| {
        r.iter().any(|x| {
            x.as_str() == Some("catalog") || x.get("name").and_then(Value::as_str) == Some("catalog")
        })
    });
    if !serves_catalogs {
        return Vec::new();
    }
    manifest
        .get("catalogs")
        .and_then(Value::as_array)
        .map(|cats| {
            cats.iter()
                .filter_map(|c| {
                    let kind = c.get("type")?.as_str()?;
                    let id = c.get("id")?.as_str()?.trim();
                    if !matches!(kind, "movie" | "series") || id.is_empty() {
                        return None;
                    }
                    let required_extra = c
                        .get("extra")
                        .and_then(Value::as_array)
                        .is_some_and(|e| e.iter().any(|x| x.get("isRequired").and_then(Value::as_bool) == Some(true)))
                        || c.get("extraRequired").and_then(Value::as_array).is_some_and(|e| !e.is_empty());
                    if required_extra {
                        return None;
                    }
                    let name = c
                        .get("name")
                        .and_then(Value::as_str)
                        .map(|n| n.split_whitespace().collect::<Vec<_>>().join(" "))
                        .filter(|n| !n.is_empty())
                        .unwrap_or_else(|| id.to_string());
                    Some(AddonCatalog { kind: kind.into(), id: id.into(), name: name.chars().take(40).collect() })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The `stream` part of [capability]: it must serve streams for movies or
/// series, by IMDb id, and not still need configuring.
fn stream_capability(manifest: &Value) -> std::result::Result<Capability, String> {
    let strings = |v: Option<&Value>| -> Option<Vec<String>> {
        v.and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
    };
    if manifest.pointer("/behaviorHints/configurationRequired").and_then(Value::as_bool) == Some(true) {
        return Err("This add-on has to be configured first. Open its configure page, set it up, and paste the manifest URL it gives you.".into());
    }
    let top_types = strings(manifest.get("types")).unwrap_or_default();
    let top_prefixes = strings(manifest.get("idPrefixes"));
    let resources = manifest.get("resources").and_then(Value::as_array).cloned().unwrap_or_default();
    // A resource is "stream" or {name: "stream", types?, idPrefixes?}; the
    // object form overrides the manifest-wide types / prefixes.
    let stream = resources.iter().find_map(|r| match r {
        Value::String(name) if name == "stream" => Some((top_types.clone(), top_prefixes.clone())),
        Value::Object(o) if o.get("name").and_then(Value::as_str) == Some("stream") => Some((
            strings(o.get("types")).unwrap_or_else(|| top_types.clone()),
            strings(o.get("idPrefixes")).or_else(|| top_prefixes.clone()),
        )),
        _ => None,
    });
    let Some((types, prefixes)) = stream else {
        return Err("This add-on doesn't provide streams, so it can't be used as a source.".into());
    };
    let types: Vec<String> = types.into_iter().filter(|t| t == "movie" || t == "series").collect();
    if types.is_empty() {
        return Err("This add-on has no streams for movies or series.".into());
    }
    let id_prefixes = prefixes.unwrap_or_default();
    if !id_prefixes.is_empty() && !id_prefixes.iter().any(|p| "tt".starts_with(p.as_str()) || p.starts_with("tt")) {
        return Err("This add-on doesn't look titles up by IMDb id, which PeanutButter needs.".into());
    }
    let name = manifest
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(|n| n.chars().take(60).collect())
        .unwrap_or_default();
    Ok(Capability { name, types, id_prefixes, streams: true, catalogs: Vec::new() })
}

/// Fetch and check the add-on's manifest, then install it (enabled).
pub async fn add(pool: &PgPool, http: &reqwest::Client, raw_url: &str) -> Result<String> {
    let base = normalize_url(raw_url)?;
    if snapshot().addons.iter().any(|a| a.url.eq_ignore_ascii_case(&base)) {
        return Err(AppError::BadRequest("That add-on is already installed.".into()));
    }
    let manifest: Value = http
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
    let cap = capability(&manifest).map_err(AppError::BadRequest)?;
    let name = if cap.name.is_empty() {
        reqwest::Url::parse(&base)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_else(|| "Add-on".into())
    } else {
        cap.name
    };
    let mut next = snapshot();
    next.addons.push(Addon {
        id: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(),
        name: name.clone(),
        url: base,
        enabled: true,
        types: cap.types,
        id_prefixes: cap.id_prefixes,
        streams: cap.streams,
        catalogs: cap.catalogs,
    });
    save(pool, next).await?;
    Ok(name)
}

#[derive(Deserialize, Default)]
struct StreamsResponse {
    #[serde(default)]
    streams: Vec<Value>,
}

/// One entry of `streams`, as the protocol defines it. Fields are read
/// leniently: add-ons in the wild send numbers as strings and the like.
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
struct AddonStream {
    #[serde(rename = "infoHash")]
    info_hash: Option<String>,
    /// Which file in the torrent is this episode / movie (season packs).
    #[serde(rename = "fileIdx")]
    file_idx: Option<Value>,
    url: Option<String>,
    #[serde(rename = "ytId")]
    yt_id: Option<String>,
    #[serde(rename = "externalUrl")]
    external_url: Option<String>,
    name: Option<String>,
    /// `description` replaced `title` in the protocol; add-ons send either.
    title: Option<String>,
    description: Option<String>,
    sources: Vec<String>,
    #[serde(rename = "behaviorHints")]
    behavior_hints: Value,
}

fn response_cache() -> &'static Mutex<HashMap<String, (Instant, Vec<Value>)>> {
    static C: OnceLock<Mutex<HashMap<String, (Instant, Vec<Value>)>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

/// `GET {base}/stream/{type}/{id}.json` → the raw `streams` array.
async fn fetch_streams(http: &reqwest::Client, url: &str) -> std::result::Result<Vec<Value>, String> {
    if let Some((at, streams)) = response_cache().lock().expect("addon cache").get(url) {
        if at.elapsed() < RESPONSE_TTL {
            return Ok(streams.clone());
        }
    }
    let res = http
        .get(url)
        .timeout(ADDON_TIMEOUT)
        .send()
        .await
        .map_err(|e| if e.is_timeout() { "timed out".to_string() } else { "unreachable".to_string() })?;
    if !res.status().is_success() {
        return Err(format!("HTTP {}", res.status().as_u16()));
    }
    let body: StreamsResponse = res.json().await.map_err(|_| "not a Stremio streams response".to_string())?;
    let mut cache = response_cache().lock().expect("addon cache");
    cache.retain(|_, (at, _)| at.elapsed() < RESPONSE_TTL);
    if cache.len() < 500 {
        cache.insert(url.to_string(), (Instant::now(), body.streams.clone()));
    }
    Ok(body.streams)
}

/// Ask one add-on for this title. Ok(empty) when it doesn't serve this type
/// or id; Err when it failed (the search goes on without it).
pub async fn find(
    http: &reqwest::Client,
    addon: &Addon,
    query: &SourceQuery,
) -> std::result::Result<Vec<StreamSource>, String> {
    let Some((stremio_type, id)) = query.stremio_id() else {
        return Ok(Vec::new());
    };
    if !addon.serves(stremio_type, &id) {
        return Ok(Vec::new());
    }
    let url = format!("{}/stream/{stremio_type}/{id}.json", addon.url);
    let streams = fetch_streams(http, &url).await?;
    let total = streams.len();
    let out: Vec<StreamSource> = streams
        .into_iter()
        .filter_map(|v| serde_json::from_value::<AddonStream>(v).ok())
        .filter_map(|s| to_source(s, &addon.name, &query.kind, &query.languages))
        .take(MAX_PER_ADDON)
        .collect();
    tracing::debug!(addon = %addon.name, total, kept = out.len(), "add-on streams");
    Ok(out)
}

/// An enabled add-on as a stream source.
pub struct AddonSource {
    pub http: reqwest::Client,
    pub addon: Addon,
}

impl SourceProvider for AddonSource {
    fn label(&self) -> &str {
        &self.addon.name
    }
    fn timeout(&self) -> Duration {
        ADDON_TIMEOUT
    }
    fn find<'a>(&'a self, query: &'a SourceQuery) -> BoxFuture<'a, std::result::Result<Vec<StreamSource>, String>> {
        Box::pin(find(&self.http, &self.addon, query))
    }
}

/// Every enabled add-on, as sources.
pub fn enabled_sources(http: &reqwest::Client) -> Vec<Box<dyn SourceProvider>> {
    snapshot()
        .addons
        .into_iter()
        .filter(|a| a.enabled && a.streams)
        .map(|addon| Box::new(AddonSource { http: http.clone(), addon }) as Box<dyn SourceProvider>)
        .collect()
}

fn hint_str<'a>(hints: &'a Value, key: &str) -> Option<&'a str> {
    hints.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

fn as_u64(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}

fn to_source(s: AddonStream, addon: &str, kind: &str, preferred_language: &str) -> Option<StreamSource> {
    let hints = &s.behavior_hints;
    let text = s
        .description
        .clone()
        .filter(|d| !d.trim().is_empty())
        .or(s.title.clone())
        .unwrap_or_default();
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    // "[FSL] [💾 3.5GB] Troy.2004.1080p…": leading tags name the host and
    // repeat stats; the release name follows.
    let (host_tag, first) = split_leading_tags(lines.next().unwrap_or_default());
    let filename = hint_str(hints, "filename").map(str::to_string);
    // The first line is the release name unless it's a stats line (👤 💾 …).
    let starts_with_stats = first.chars().next().is_some_and(|c| !c.is_ascii() && !c.is_alphanumeric());
    let name_lines: Vec<&str> = s.name.as_deref().unwrap_or("").lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let mut release = if first.is_empty() || starts_with_stats {
        filename.clone().unwrap_or_default()
    } else {
        first
    };
    if release.is_empty() {
        release = name_lines.join(" ");
    }
    // Quality often sits only in `name` ("HDHub\n1080p"); keep it for ranking.
    if crate::sources::rank::detect_resolution(&release).is_none() {
        if let Some(q) = name_lines.iter().find(|l| crate::sources::rank::detect_resolution(l).is_some()) {
            release = format!("{release} [{q}]");
        }
    }
    let seeders = number_after(&text, "👤").map(|n| n as i32);
    let bytes = hints
        .get("videoSize")
        .and_then(as_u64)
        .filter(|b| *b > 0)
        .or_else(|| size_after(&text, "💾"))
        .or_else(|| size_after(&text, "📦"))
        .unwrap_or(0);
    let origin = text
        .split("⚙️")
        .nth(1)
        .map(|rest| rest.lines().next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty());
    let label = match origin {
        Some(o) => format!("{addon} · {o}"),
        None if host_tag.is_some() => format!("{addon} · {}", host_tag.unwrap_or_default()),
        None => match name_lines.first() {
            Some(n) if !n.eq_ignore_ascii_case(addon) && crate::sources::rank::detect_resolution(n).is_none() => {
                format!("{addon} · {n}")
            }
            _ => addon.to_string(),
        },
    };
    let file_idx = s.file_idx.as_ref().and_then(as_u64);
    let with_file = |mut src: StreamSource| {
        // BEP 53 select-only: apps read it to play the exact file of a
        // season pack (and libtorrent itself skips the other files).
        if let Some(i) = file_idx {
            src.magnet.push_str(&format!("&so={i}"));
        }
        src
    };

    if let Some(hash) = s.info_hash.as_deref().map(str::trim).filter(|h| !h.is_empty()) {
        let trackers: Vec<String> = s
            .sources
            .iter()
            .filter_map(|src| src.strip_prefix("tracker:").map(str::to_string))
            .collect();
        return crate::jackett::external_source(&release, hash, &trackers, seeders, bytes, &label, kind, preferred_language)
            .map(with_file);
    }
    let url = s.url.as_deref().map(str::trim).filter(|u| !u.is_empty())?;
    if url.to_ascii_lowercase().starts_with("magnet:") {
        let hash = crate::sources::info_hash_of(url)?;
        let trackers: Vec<String> = magnet_params(url, "tr");
        return crate::jackett::external_source(&release, &hash, &trackers, seeders, bytes, &label, kind, preferred_language)
            .map(with_file);
    }
    let parsed = reqwest::Url::parse(url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    let _ = (&s.yt_id, &s.external_url); // ytId / externalUrl: never with a url; not playable in-app.
    let language = crate::jackett::screen_release(&release, bytes, kind, preferred_language)?;
    let headers: Vec<StreamHeader> = hints
        .pointer("/proxyHeaders/request")
        .and_then(Value::as_object)
        .map(|o| {
            o.iter()
                .filter_map(|(k, v)| v.as_str().map(|v| StreamHeader { name: k.clone(), value: v.to_string() }))
                .collect()
        })
        .unwrap_or_default();
    use sha2::Digest;
    let id = format!("http:{}", &hex::encode(sha2::Sha256::digest(url.as_bytes()))[..20]);
    Some(StreamSource {
        id,
        title: release.trim().to_string(),
        magnet: String::new(),
        seeders: 0,
        peers: 0,
        rating: 4,
        health: "unknown".into(),
        size: if bytes > 0 { crate::jackett::format_size(bytes) } else { "?".into() },
        tracker: label.clone(),
        indexer: label,
        language,
        kind: "http".into(),
        url: url.to_string(),
        headers,
        size_bytes: bytes,
        ..Default::default()
    })
}

/// Leading `[…]` groups off a description line: the first one that isn't
/// stats (💾 / 👤 …) is returned as the host tag, the rest is the release name.
fn split_leading_tags(line: &str) -> (Option<String>, String) {
    let mut rest = line.trim();
    let mut tag = None;
    while let Some(after) = rest.strip_prefix('[') {
        let Some(end) = after.find(']') else { break };
        let inner = after[..end].trim();
        let is_stats = inner.chars().next().is_some_and(|c| !c.is_ascii() && !c.is_alphanumeric());
        if tag.is_none() && !inner.is_empty() && !is_stats {
            tag = Some(inner.chars().take(30).collect());
        }
        rest = after[end + 1..].trim_start();
    }
    if rest.is_empty() {
        // Nothing but tags: keep the line as it was.
        return (None, line.trim().to_string());
    }
    (tag, rest.to_string())
}

/// Values of `key=` in a magnet, percent-decoded.
fn magnet_params(magnet: &str, key: &str) -> Vec<String> {
    let Some((_, query)) = magnet.split_once('?') else { return Vec::new() };
    query
        .split('&')
        .filter_map(|p| p.split_once('='))
        .filter(|(k, _)| *k == key)
        .map(|(_, v)| percent_decode(v))
        .collect()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn stream(v: Value) -> AddonStream {
        serde_json::from_value(v).unwrap()
    }

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
    fn reads_stream_capability_from_manifests() {
        let torrentio = json!({
            "id": "com.stremio.torrentio.addon", "name": "Torrentio",
            "resources": ["stream"], "types": ["movie", "series", "anime", "other"],
            "idPrefixes": ["tt", "kitsu"]
        });
        let cap = stream_capability(&torrentio).unwrap();
        assert_eq!(cap.name, "Torrentio");
        assert_eq!(cap.types, vec!["movie", "series"]);
        assert_eq!(cap.id_prefixes, vec!["tt", "kitsu"]);

        // Object resources override the manifest-wide types / prefixes.
        let hdhub = json!({
            "name": "HDHub", "types": ["movie", "series", "tv"], "catalogs": [],
            "resources": ["catalog", {"name": "stream", "types": ["movie"], "idPrefixes": ["tt"]}]
        });
        let cap = stream_capability(&hdhub).unwrap();
        assert_eq!((cap.types, cap.id_prefixes), (vec!["movie".to_string()], vec!["tt".to_string()]));

        assert!(stream_capability(&json!({"name": "Cat", "resources": ["catalog"], "types": ["movie"]})).is_err());
        assert!(stream_capability(&json!({"resources": ["stream"], "types": ["movie"], "idPrefixes": ["kitsu:"]})).is_err());
        assert!(stream_capability(&json!({"resources": ["stream"], "types": ["tv"]})).is_err());
        let needs_setup = json!({"resources": ["stream"], "types": ["movie"], "behaviorHints": {"configurable": true, "configurationRequired": true}});
        assert!(stream_capability(&needs_setup).unwrap_err().contains("configured first"));
    }

    #[test]
    fn catalog_addons_install_with_their_listable_catalogs() {
        // Streaming Catalogs' manifest (shape as served).
        let m = json!({
            "name": "Streaming Catalogs", "resources": ["catalog"], "types": ["movie", "series"],
            "idPrefixes": ["tt"], "behaviorHints": {"configurable": true},
            "catalogs": [
                {"type": "movie", "id": "nfx", "name": "Netflix"},
                {"type": "series", "id": "amp", "name": "Prime  Video"},
                {"type": "movie", "id": "search", "name": "Search", "extra": [{"name": "search", "isRequired": true}]},
                {"type": "tv", "id": "live", "name": "Live"},
                {"type": "movie", "id": "genre", "name": "By genre", "extraRequired": ["genre"]}
            ]
        });
        let cap = capability(&m).unwrap();
        assert!(!cap.streams);
        assert_eq!(cap.name, "Streaming Catalogs");
        assert_eq!(
            cap.catalogs,
            vec![
                AddonCatalog { kind: "movie".into(), id: "nfx".into(), name: "Netflix".into() },
                AddonCatalog { kind: "series".into(), id: "amp".into(), name: "Prime Video".into() },
            ]
        );
        // Streams and catalogs in one add-on: both kept.
        let both = json!({"name": "B", "resources": ["stream", "catalog"], "types": ["movie"],
            "catalogs": [{"type": "movie", "id": "top", "name": "Top"}]});
        let cap = capability(&both).unwrap();
        assert!(cap.streams && cap.catalogs.len() == 1);
        // HDHub's catalogs list is empty: a stream add-on only.
        let hd = json!({"name": "HdHub", "resources": ["stream", "catalog"], "types": ["movie", "series"], "catalogs": []});
        assert!(capability(&hd).unwrap().catalogs.is_empty());
        // Neither: refused with the stream reason.
        assert!(capability(&json!({"resources": ["meta"], "types": ["movie"]})).is_err());
        // Old saved add-ons are stream add-ons with no catalogs.
        let old: Addon = serde_json::from_value(json!({"id": "t", "name": "T", "url": "https://t"})).unwrap();
        assert!(old.streams && old.catalogs.is_empty());
    }

    #[test]
    fn addons_are_only_asked_for_what_they_serve() {
        let a = Addon {
            id: "x".into(),
            name: "Movies".into(),
            url: "https://x".into(),
            enabled: true,
            types: vec!["movie".into()],
            id_prefixes: vec!["tt".into()],
            streams: true,
            catalogs: vec![],
        };
        assert!(a.serves("movie", "tt123"));
        assert!(!a.serves("series", "tt123:1:1"));
        assert!(!a.serves("movie", "kitsu:1"));
        // Installed by an older build: no record, ask for anything.
        let old: Addon = serde_json::from_value(json!({"id": "t", "name": "T", "url": "https://t"})).unwrap();
        assert!(old.enabled && old.serves("series", "tt1:1:1"));
    }

    #[test]
    fn parses_torrentio_stream() {
        let s = stream(json!({
            "name": "Torrentio\n1080p",
            "title": "Troy.2004.Directors.Cut.1080p.BluRay.x264-AMIABLE\n👤 214 💾 12.3 GB ⚙️ ThePirateBay",
            "infoHash": "0123456789abcdef0123456789abcdef01234567",
            "fileIdx": 0,
            "behaviorHints": { "filename": "Troy.2004.Directors.Cut.1080p.BluRay.x264-AMIABLE.mkv", "bingeGroup": "torrentio|1080p" },
            "sources": ["tracker:udp://tracker.opentrackr.org:1337/announce", "dht:0123456789abcdef0123456789abcdef01234567"]
        }));
        let src = to_source(s, "Torrentio", "movie", "").expect("kept");
        assert!(src.magnet.ends_with("&so=0"), "{}", src.magnet);
        assert_eq!(src.kind, "torrent");
        assert_eq!(src.seeders, 214);
        assert_eq!(src.health, "excellent");
        assert_eq!(src.size, "12.3 GB");
        assert_eq!(src.indexer, "Torrentio · ThePirateBay");
        assert!(src.title.starts_with("Troy.2004"));
        assert!(src.magnet.starts_with("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn="));
        assert!(src.magnet.contains("&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"));
    }

    #[test]
    fn parses_direct_http_streams_with_headers() {
        // HDHub-style: quality in `name`, details in `description`, size in videoSize.
        let s = stream(json!({
            "name": "HDHub\n1080p",
            "description": "Troy (2004) Director's Cut WEB-DL\n💾 2.1 GB",
            "url": "https://cdn.example.net/v/troy.mkv?token=abc",
            "behaviorHints": {
                "notWebReady": true,
                "videoSize": 2254857830u64,
                "filename": "Troy.2004.1080p.WEB-DL.mkv",
                "proxyHeaders": { "request": { "User-Agent": "Mozilla/5.0", "Referer": "https://hdhub.example/" } }
            }
        }));
        let src = to_source(s, "HDHub", "movie", "en").expect("kept");
        assert_eq!(src.kind, "http");
        assert!(src.is_http());
        assert_eq!(src.url, "https://cdn.example.net/v/troy.mkv?token=abc");
        assert!(src.magnet.is_empty());
        assert_eq!(src.title, "Troy (2004) Director's Cut WEB-DL [1080p]");
        assert_eq!(crate::sources::rank::detect_resolution(&src.title), Some(1080));
        assert_eq!(src.size, "2.1 GB");
        assert_eq!(src.health, "unknown");
        assert_eq!(src.indexer, "HDHub");
        assert!(src.id.starts_with("http:"));
        assert_eq!(
            src.headers,
            vec![
                StreamHeader { name: "Referer".into(), value: "https://hdhub.example/".into() },
                StreamHeader { name: "User-Agent".into(), value: "Mozilla/5.0".into() },
            ]
        );
    }

    #[test]
    fn hdhub_descriptions_lose_their_tags() {
        let s = stream(json!({
            "name": "4KHDHub 1080p",
            "description": "[FSL] [💾 3.5GB] Troy.2004.1080p.BluRay.Hindi.English.DD5.1.x264.ESub.mkv\nHindi\nFSL | 4KHDHub",
            "url": "https://r2.example/hub/abc?X-Amz-Signature=1",
            "behaviorHints": { "notWebReady": true, "videoSize": 3758096384u64 }
        }));
        let src = to_source(s, "HdHub", "movie", "en").expect("kept");
        assert_eq!(src.title, "Troy.2004.1080p.BluRay.Hindi.English.DD5.1.x264.ESub.mkv");
        assert_eq!(src.indexer, "HdHub · FSL");
        assert_eq!(src.size, "3.5 GB");
        assert_eq!(split_leading_tags("[💾 1 GB] [PixelDrain] X.mkv"), (Some("PixelDrain".into()), "X.mkv".into()));
        assert_eq!(split_leading_tags("[only tags]"), (None, "[only tags]".into()));
    }

    #[test]
    fn magnet_urls_are_torrents() {
        let s = stream(json!({
            "name": "Some add-on",
            "title": "Troy.2004.720p.BluRay",
            "url": "magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=Troy&tr=udp%3A%2F%2Ft.example%3A80",
            "fileIdx": "3"
        }));
        let src = to_source(s, "X", "movie", "").expect("kept");
        assert_eq!(src.kind, "torrent");
        assert!(src.magnet.starts_with("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"));
        assert!(src.magnet.contains("&tr=udp%3A%2F%2Ft.example%3A80"), "{}", src.magnet);
        assert!(src.magnet.ends_with("&so=3"));
        assert_eq!(src.indexer, "X · Some add-on");
    }

    #[test]
    fn leaves_out_what_cannot_play_in_app() {
        for v in [
            json!({"title": "Troy trailer", "ytId": "abc123"}),
            json!({"title": "Watch on site", "externalUrl": "https://example.com/troy"}),
            json!({"title": "Troy.2004.1080p", "url": "rtmp://example.com/live"}),
            json!({"title": "Troy.2004.1080p", "name": "nothing playable"}),
            json!({"title": "Troy.2004.HDCAM.x264\n👤 900 💾 1.4 GB", "infoHash": "0123456789abcdef0123456789abcdef01234567"}),
            json!({"title": "Troy.2004.HDCAM", "url": "https://cdn.example/troy-cam.mp4"}),
        ] {
            assert!(to_source(stream(v.clone()), "X", "movie", "").is_none(), "{v}");
        }
    }

    #[test]
    fn lenient_with_odd_fields() {
        // Malformed entries are skipped by `find`, not fatal; odd types still parse.
        assert!(serde_json::from_value::<AddonStream>(json!({"fileIdx": null, "behaviorHints": null, "url": "https://a/b.mp4"})).is_ok());
        assert!(serde_json::from_value::<AddonStream>(json!({"infoHash": 5})).is_err());
    }

    /// Network test against the real HDHub add-on (direct links):
    /// `cargo test -- --ignored live_hdhub --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn live_hdhub() {
        let http = reqwest::Client::new();
        let base = "https://hdhub.thevolecitor.qzz.io";
        let manifest: Value = http.get(format!("{base}/manifest.json")).send().await.unwrap().json().await.unwrap();
        let cap = capability(&manifest).expect("installable");
        println!("{} types={:?} prefixes={:?}", cap.name, cap.types, cap.id_prefixes);
        let addon = Addon {
            id: "h".into(),
            name: cap.name,
            url: base.into(),
            enabled: true,
            types: cap.types,
            id_prefixes: cap.id_prefixes,
            streams: true,
            catalogs: vec![],
        };
        let q = SourceQuery {
            target: crate::jackett::SearchTarget { imdb_id: Some("tt0332452".into()), ..Default::default() },
            kind: "movie".into(),
            languages: "en".into(),
            resolution: "1080p".into(),
            ..Default::default()
        };
        let found = find(&http, &addon, &q).await.unwrap();
        let before = found.len();
        let checked = crate::sources::collapse_mirrors(crate::sources::check_links(&http, found).await);
        println!("{before} links, {} after the link check and mirror collapse", checked.len());
        let ranked = crate::sources::rank::rank(checked, &crate::sources::prefs(&q));
        for s in &ranked {
            println!("{:>5} {:<5} {:>9} {:<10} {} | {}", s.score, s.kind, s.size, s.language, s.indexer, s.title);
        }
        assert!(ranked.iter().any(|s| s.is_http()), "no direct links");
    }

    /// Network test against the real Torrentio: `cargo test -- --ignored live_torrentio`.
    #[tokio::test]
    #[ignore]
    async fn live_torrentio() {
        let addon = Addon {
            id: "t".into(),
            name: "Torrentio".into(),
            url: TORRENTIO_URL.into(),
            enabled: true,
            types: vec![],
            id_prefixes: vec![],
            streams: true,
            catalogs: vec![],
        };
        let http = reqwest::Client::new();
        let q = |kind: &str, s: Option<i32>, e: Option<i32>, imdb: &str| SourceQuery {
            target: crate::jackett::SearchTarget { imdb_id: Some(imdb.into()), ..Default::default() },
            kind: kind.into(),
            season: s,
            episode: e,
            languages: "en".into(),
            resolution: "1080p".into(),
            ..Default::default()
        };
        let movie = find(&http, &addon, &q("movie", None, None, "tt0332452")).await.unwrap();
        let episode = find(&http, &addon, &q("series", Some(1), Some(1), "tt0903747")).await.unwrap();
        for src in movie.iter().take(3).chain(episode.iter().take(3)) {
            println!("{:>5} {:>9} {:<28} {}", src.seeders, src.size, src.indexer, src.title);
        }
        assert!(!movie.is_empty(), "no movie results");
        assert!(!episode.is_empty(), "no episode results");
        assert!(movie.iter().all(|s| s.magnet.starts_with("magnet:?xt=urn:btih:")));
        let ranked = crate::sources::rank::rank(movie, &crate::sources::prefs(&q("movie", None, None, "tt0332452")));
        println!("ranked for 1080p / en:");
        for src in ranked.iter().take(5) {
            println!("{:>5} {:>5} {:>9} {}", src.score, src.seeders, src.size, src.title);
        }
    }
}
