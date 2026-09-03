use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;

use crate::error::{AppError, Result};
use crate::graphql::types::StreamSource;

#[derive(Clone)]
pub struct JackettClient {
    http: reqwest::Client,
    catalog_http: reqwest::Client,
    base_url: String,
    api_key: String,
    skip_indexers: Arc<Mutex<HashSet<String>>>,
    indexer_cache: Arc<Mutex<Option<Vec<IndexerInfo>>>>,
}

#[derive(Clone, Debug)]
struct IndexerInfo {
    id: String,
    name: String,
    last_error: String,
}

#[derive(Debug, Deserialize)]
struct JackettResponse {
    #[serde(default, rename = "Results")]
    results: Vec<JackettHit>,
    #[serde(default, rename = "Indexers")]
    indexers: Vec<JackettIndexer>,
}

#[derive(Debug, Deserialize)]
struct JackettIndexer {
    #[serde(default, rename = "ID")]
    id: Option<String>,
    #[serde(default, rename = "Error")]
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct IndexerListItem {
    #[serde(default, alias = "ID")]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default = "default_true")]
    configured: bool,
    #[serde(default, alias = "last_error", alias = "lastError")]
    last_error: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
struct JackettHit {
    #[serde(default, rename = "Title")]
    title: String,
    #[serde(default, rename = "MagnetUri")]
    magnet_uri: Option<String>,
    #[serde(default, rename = "Link")]
    link: Option<String>,
    #[serde(default, rename = "Seeders")]
    seeders: Option<i64>,
    #[serde(default, rename = "Peers")]
    peers: Option<i64>,
    #[serde(default, rename = "Size")]
    size: Option<i64>,
    #[serde(default, rename = "Tracker")]
    tracker: Option<String>,
    #[serde(default, rename = "TrackerId")]
    tracker_id: Option<String>,
    #[serde(default, rename = "Indexer")]
    indexer: Option<String>,
    #[serde(default, rename = "Guid")]
    guid: Option<String>,
}

impl JackettClient {
    pub fn new(http: reqwest::Client, base_url: String, api_key: String) -> Self {
        Self {
            catalog_http: http.clone(),
            http,
            base_url,
            api_key,
            skip_indexers: Arc::new(Mutex::new(HashSet::new())),
            indexer_cache: Arc::new(Mutex::new(None)),
        }
    }

    pub fn from_live(_http: &reqwest::Client, live: &crate::config::LiveSettings) -> Result<Self> {
        let url = live
            .jackett_url()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| jackett_err("Add your Jackett URL in the server console first."))?;
        let key = live
            .jackett_api_key()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| jackett_err("Add your Jackett API key in the server console first."))?;
        let http = reqwest::Client::builder()
            .user_agent("PeanutButter")
            .timeout(Duration::from_secs(45))
            .redirect(reqwest::redirect::Policy::limited(4))
            .build()
            .map_err(|e| AppError::Internal(e.to_string()))?;
        let catalog_http = reqwest::Client::builder()
            .user_agent("PeanutButter")
            .timeout(Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::limited(4))
            .build()
            .map_err(|e| AppError::Internal(e.to_string()))?;
        Ok(Self {
            http,
            catalog_http,
            base_url: normalize_jackett_url(&url)?,
            api_key: key,
            skip_indexers: Arc::new(Mutex::new(HashSet::new())),
            indexer_cache: Arc::new(Mutex::new(None)),
        })
    }

    pub async fn test_connection(&self) -> Result<bool> {
        let url = format!("{}/api/v2.0/indexers", self.base_url);
        let res = self
            .http
            .get(&url)
            .query(&[("apikey", self.api_key.as_str()), ("configured", "true")])
            .send()
            .await
            .map_err(|e| self.redact_err(e))?;
        if res.status().is_success() {
            return Ok(true);
        }
        let status = res.status().as_u16();
        let body = res.text().await.unwrap_or_default();
        Err(jackett_err(http_status_message(status, &body)))
    }

    pub async fn search(
        &self,
        query: &str,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
        preferred_resolution: &str,
        preferred_language: &str,
        imdb_id: Option<&str>,
    ) -> Result<Vec<StreamSource>> {
        let q = build_query(query, kind, season, episode, preferred_language);
        if q.trim().is_empty() {
            return Ok(vec![]);
        }
        // First try Torznab per-indexer search which uses t=movie/tvsearch + imdbid/season/ep.
        // This gives much better results than the /all aggregator for targeted lookups.
        let torznab = self
            .search_torznab_all(
                &q,
                kind,
                season,
                episode,
                imdb_id,
                preferred_resolution,
                preferred_language,
            )
            .await
            .unwrap_or_default();
        let torznab = Self::filter_episode(torznab, season, episode);
        if torznab.len() >= 2 {
            return Ok(torznab);
        }
        // Fallback: /all/results with plain text query.
        // Sending Newznab Category IDs makes Jackett fail many indexers with
        // "build error" when those cats are not mapped, so we skip cat= here.
        let url = format!("{}/api/v2.0/indexers/all/results", self.base_url);
        let res = self
            .http
            .get(&url)
            .query(&[("apikey", self.api_key.as_str()), ("Query", q.as_str())])
            .send()
            .await
            .map_err(|e| self.redact_err(e))?;
        if res.status().is_success() {
            let body: JackettResponse = res.json().await.map_err(|e| {
                if e.is_decode() {
                    jackett_err(
                        "Jackett returned a response we couldn’t read. Check the URL in Settings.",
                    )
                } else {
                    self.redact_err(e)
                }
            })?;
            let mut results = self.transform_results(
                body.results,
                preferred_resolution,
                preferred_language,
                kind,
            );
            // Merge in Torznab hits we already collected
            if !torznab.is_empty() {
                let existing: std::collections::HashSet<String> = results
                    .iter()
                    .filter(|r| r.magnet.starts_with("magnet:"))
                    .map(|r| r.magnet.clone())
                    .collect();
                for s in torznab {
                    if !existing.contains(&s.magnet) {
                        results.push(s);
                    }
                }
                results = crate::jackett::rank_sources(results, preferred_resolution);
            }
            if !results.is_empty() {
                return Ok(Self::filter_episode(results, season, episode));
            }
            let cookie_blocked = body
                .indexers
                .iter()
                .filter_map(|i| i.error.as_deref())
                .any(needs_login);
            if cookie_blocked {
                let fallback = self
                    .search_indexers_individually(&q, preferred_resolution, preferred_language, kind)
                    .await
                    .unwrap_or_default();
                if !fallback.is_empty() {
                    return Ok(Self::filter_episode(fallback, season, episode));
                }
                return Err(jackett_err(INDEXER_LOGIN_MSG));
            }
            if let Some(err) = body
                .indexers
                .iter()
                .filter_map(|i| i.error.as_deref())
                .find(|e| !e.trim().is_empty() && !is_broken_indexer_error(e))
            {
                return Err(jackett_err(indexer_error_message(err)));
            }
            return Ok(Self::filter_episode(results, season, episode));
        }
        let status = res.status().as_u16();
        let body = res.text().await.unwrap_or_default();
        if status == 400 || needs_login(&body) {
            let fallback = self
                .search_indexers_individually(&q, preferred_resolution, preferred_language, kind)
                .await
                .unwrap_or_default();
            if !fallback.is_empty() {
                return Ok(Self::filter_episode(fallback, season, episode));
            }
        }
        Err(jackett_err(http_status_message(status, &body)))
    }

    /// Catalog pass: query a few healthy indexers in parallel and stop once we have
    /// enough seeders. Skips broken definitions (empty-page parse errors) for the rest
    /// of the run instead of waiting on `/all/results`.
    pub async fn search_index(
        &self,
        query: &str,
        kind: &str,
        preferred_resolution: &str,
    ) -> Result<Vec<StreamSource>> {
        let q = build_query(query, kind, None, None, "");
        if q.trim().is_empty() {
            return Ok(vec![]);
        }
        let ids = self.catalog_indexer_ids(kind).await;
        if ids.is_empty() {
            return self
                .search_all_catalog(&q, preferred_resolution, kind)
                .await;
        }
        let mut set = tokio::task::JoinSet::new();
        for id in ids {
            let this = self.clone();
            let q = q.clone();
            let kind2 = kind.to_string();
            set.spawn(async move {
                let result = tokio::time::timeout(
                    Duration::from_secs(8),
                    this.search_one_indexer_catalog(&id, &q, &kind2),
                )
                .await;
                (id, result)
            });
        }
        let mut hits = Vec::new();
        while let Some(joined) = set.join_next().await {
            let Ok((id, timed)) = joined else { continue };
            match timed {
                Ok(Ok(batch)) => {
                    hits.extend(batch);
                    if healthy_hit_count(&hits) >= 2 {
                        set.abort_all();
                        break;
                    }
                }
                Ok(Err(ref err)) if err == "rate_limited" => self.skip_indexer(&id),
                Ok(Err(err)) if is_broken_indexer_error(&err) => self.skip_indexer(&id),
                Err(_) => self.skip_indexer(&id),
                Ok(Err(_)) => {}
            }
        }
        Ok(self.transform_results(hits, preferred_resolution, "", kind))
    }

    fn rank_vec(&self, v: Vec<StreamSource>, preferred_resolution: &str) -> Vec<StreamSource> {
        crate::jackett::rank_sources(v, preferred_resolution)
    }

    /// Torznab search: hit each configured indexer with proper t= type and structured params.
    /// Returns merged, ranked results. Falls back gracefully if an indexer doesn't support it.
    async fn search_torznab_all(
        &self,
        query: &str,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
        imdb_id: Option<&str>,
        preferred_resolution: &str,
        preferred_language: &str,
    ) -> Result<Vec<StreamSource>> {
        let ids = self.catalog_indexer_ids(kind).await;
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let mut set = tokio::task::JoinSet::new();
        for id in &ids {
            let this = self.clone();
            let id = id.clone();
            let query = query.to_string();
            let kind = kind.to_string();
            let season = season;
            let episode = episode;
            let imdb = imdb_id.map(str::to_string);
            set.spawn(async move {
                tokio::time::timeout(
                    Duration::from_secs(12),
                    this.search_torznab_one(&id, &query, &kind, season, episode, imdb.as_deref()),
                )
                .await
            });
        }
        let mut hits: Vec<JackettHit> = Vec::new();
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok(Ok(Ok(batch))) => hits.extend(batch),
                Ok(Ok(Err(ref e))) if e == "rate_limited" => {}
                Ok(Ok(Err(e))) if is_broken_indexer_error(&e) => {}
                _ => {}
            }
        }
        Ok(self.transform_results(hits, preferred_resolution, preferred_language, kind))
    }

    /// Single-indexer Torznab search with t=movie/tvsearch/search + structured params.
    /// Falls back to plain t=search if the indexer returns nothing with structured params.
    async fn search_torznab_one(
        &self,
        id: &str,
        query: &str,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
        imdb_id: Option<&str>,
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let url = format!("{}/api/v2.0/indexers/{id}/results", self.base_url);
        let cats = kind_categories(kind);

        // Build structured Torznab params
        let t_type = match kind {
            "movie" => "movie",
            "series" | "anime" => "tvsearch",
            _ => "search",
        };

        let mut params: Vec<(&str, String)> = vec![
            ("apikey", self.api_key.clone()),
            ("t", t_type.to_string()),
            // Use categories — all indexers we target are Torznab-compliant
            ("cat", cats.to_string()),
        ];

        // Add IMDB ID for movies (highest precision)
        if kind == "movie" {
            if let Some(imdb) = imdb_id.filter(|s| !s.is_empty()) {
                // Jackett expects plain numeric ID, strip "tt" prefix
                let numeric = imdb.trim_start_matches("tt");
                if !numeric.is_empty() {
                    params.push(("imdbid", numeric.to_string()));
                }
            }
        }

        // Add season/ep for TV — much better than baking it into the query string
        if let (Some(s), Some(e)) = (season, episode) {
            if kind == "series" || kind == "anime" {
                params.push(("season", s.to_string()));
                params.push(("ep", e.to_string()));
            }
        }

        // Always include the text query so indexers that ignore structured params still work
        params.push(("q", query.to_string()));

        let res = self
            .http
            .get(&url)
            .query(&params)
            .send()
            .await
            .map_err(|e| self.redact_text(&e.to_string()))?;

        let status = res.status();
        if !status.is_success() {
            let body = res.text().await.unwrap_or_default();
            if status.as_u16() == 429 {
                return Err("rate_limited".to_string());
            }
            return Err(self.redact_text(&body));
        }
        let body: JackettResponse = res
            .json()
            .await
            .map_err(|e| self.redact_text(&e.to_string()))?;
        if let Some(err) = body
            .indexers
            .iter()
            .filter_map(|i| i.error.as_deref())
            .find(|e| is_broken_indexer_error(e))
        {
            return Err(err.to_string());
        }
        Ok(body.results)
    }

    async fn search_all_catalog(
        &self,
        query: &str,
        preferred_resolution: &str,
        kind: &str,
    ) -> Result<Vec<StreamSource>> {
        let url = format!("{}/api/v2.0/indexers/all/results", self.base_url);
        let res = match tokio::time::timeout(
            Duration::from_secs(10),
            self.catalog_http
                .get(&url)
                .query(&[("apikey", self.api_key.as_str()), ("Query", query)])
                .send(),
        )
        .await
        {
            Ok(Ok(res)) => res,
            _ => return Ok(vec![]),
        };
        if !res.status().is_success() {
            return Ok(vec![]);
        }
        let body: JackettResponse = match res.json().await {
            Ok(body) => body,
            Err(_) => return Ok(vec![]),
        };
        for indexer in &body.indexers {
            if let (Some(id), Some(err)) = (indexer.id.as_deref(), indexer.error.as_deref()) {
                if is_broken_indexer_error(err) {
                    self.skip_indexer(id);
                }
            }
        }
        Ok(self.transform_results(body.results, preferred_resolution, "", kind))
    }

    async fn configured_indexer_ids(&self) -> Result<Vec<String>> {
        Ok(self
            .load_indexers()
            .await
            .into_iter()
            .map(|ix| ix.id)
            .take(12)
            .collect())
    }

    async fn catalog_indexer_ids(&self, kind: &str) -> Vec<String> {
        let skip = self
            .skip_indexers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        self.load_indexers()
            .await
            .into_iter()
            .filter(|ix| !skip.contains(&ix.id))
            .filter(|ix| !is_broken_indexer_error(&ix.last_error))
            .filter(|ix| indexer_fits_kind(&ix.id, &ix.name, kind))
            .map(|ix| ix.id)
            .take(4)
            .collect()
    }

    async fn load_indexers(&self) -> Vec<IndexerInfo> {
        if let Some(rows) = self
            .indexer_cache
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
        {
            return rows;
        }
        let url = format!("{}/api/v2.0/indexers", self.base_url);
        let res = match self
            .http
            .get(&url)
            .header("accept", "application/json")
            .query(&[("apikey", self.api_key.as_str()), ("configured", "true")])
            .send()
            .await
        {
            Ok(res) if res.status().is_success() => res,
            _ => return Vec::new(),
        };
        let rows: Vec<IndexerListItem> = res.json().await.unwrap_or_default();
        let parsed: Vec<IndexerInfo> = rows
            .into_iter()
            .filter(|row| row.configured)
            .filter_map(|row| {
                let id = row.id.filter(|s| !s.is_empty() && s != "all")?;
                Some(IndexerInfo {
                    name: row.name.unwrap_or_default(),
                    last_error: row.last_error.unwrap_or_default(),
                    id,
                })
            })
            .collect();
        if !parsed.is_empty() {
            *self
                .indexer_cache
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = Some(parsed.clone());
        }
        parsed
    }

    fn skip_indexer(&self, id: &str) {
        self.skip_indexers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.to_string());
    }

    async fn search_one_indexer(&self, id: &str, query: &str, kind: &str) -> std::result::Result<Vec<JackettHit>, String> {
        let cats = kind_categories(kind);
        self.search_one_indexer_with(&self.http, id, query, Some(cats)).await
    }

    async fn search_one_indexer_catalog(
        &self,
        id: &str,
        query: &str,
        kind: &str,
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let cats = kind_categories(kind);
        self.search_one_indexer_with(&self.catalog_http, id, query, Some(cats)).await
    }

    async fn search_one_indexer_with(
        &self,
        http: &reqwest::Client,
        id: &str,
        query: &str,
        categories: Option<&str>,
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let url = format!("{}/api/v2.0/indexers/{id}/results", self.base_url);
        let mut params = vec![
            ("apikey", self.api_key.as_str()),
            ("Query", query),
        ];
        // Pass cat= only when categories are provided and non-empty so we don't
        // break indexers that don't support Newznab category filtering.
        let cats_str;
        if let Some(cats) = categories.filter(|s| !s.is_empty()) {
            cats_str = cats.to_string();
            params.push(("cat", &cats_str));
        }
        let res = http
            .get(&url)
            .query(&params)
            .send()
            .await
            .map_err(|e| self.redact_text(&e.to_string()))?;
        let status = res.status();
        if !status.is_success() {
            let body = res.text().await.unwrap_or_default();
            // Treat 429 as a rate-limit marker so the caller can skip this indexer
            // for the rest of the session instead of hammering it further.
            if status.as_u16() == 429 {
                return Err("rate_limited".to_string());
            }
            return Err(self.redact_text(&body));
        }
        let body: JackettResponse = res.json().await.map_err(|e| self.redact_text(&e.to_string()))?;
        if let Some(err) = body
            .indexers
            .iter()
            .filter_map(|i| i.error.as_deref())
            .find(|e| is_broken_indexer_error(e))
        {
            return Err(err.to_string());
        }
        Ok(body.results)
    }

    async fn search_indexers_individually(
        &self,
        query: &str,
        preferred_resolution: &str,
        preferred_language: &str,
        kind: &str,
    ) -> Result<Vec<StreamSource>> {
        let ids = self.configured_indexer_ids().await?;
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let mut set = tokio::task::JoinSet::new();
        for id in ids {
            let this = self.clone();
            let q = query.to_string();
            let kind2 = kind.to_string();
            set.spawn(async move { this.search_one_indexer(&id, &q, &kind2).await });
        }
        let mut hits = Vec::new();
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok(Ok(batch)) => hits.extend(batch),
                Ok(Err(ref e)) if e == "rate_limited" => {}
                _ => {}
            }
        }
        Ok(self.transform_results(hits, preferred_resolution, preferred_language, kind))
    }

    fn redact_text(&self, msg: &str) -> String {
        if self.api_key.is_empty() {
            msg.to_string()
        } else {
            msg.replace(&self.api_key, "***")
        }
    }

    fn filter_episode(
        sources: Vec<StreamSource>,
        season: Option<i32>,
        episode: Option<i32>,
    ) -> Vec<StreamSource> {
        let (Some(s), Some(e)) = (season, episode) else {
            return sources;
        };
        sources
            .into_iter()
            .filter(|src| torrent_usable_for_episode(&src.title, s, e))
            .collect()
    }

    fn transform_results(
        &self,
        results: Vec<JackettHit>,
        preferred_resolution: &str,
        preferred_language: &str,
        kind: &str,
    ) -> Vec<StreamSource> {
        let preferred_res = preferred_resolution.to_ascii_lowercase();
        let preferred_lang = preferred_language.trim().to_ascii_lowercase();
        let mut out: Vec<StreamSource> = results
            .into_iter()
            .filter_map(|hit| {
                let magnet = torrent_locator(&hit)?;
                if looks_like_sample(&hit.title) || looks_like_cam(&padded(&hit.title)) {
                    return None;
                }
                if looks_like_junk_release(&hit.title, kind) {
                    return None;
                }
                let bytes = hit.size.unwrap_or(0).max(0) as u64;
                if !size_plausible(bytes, kind, &hit.title) {
                    return None;
                }
                let seeders = hit.seeders.unwrap_or(0).max(0) as i32;
                // Dead / near-dead swarms almost always fail to start.
                if seeders < 5 {
                    return None;
                }
                let langs = language_codes(&hit.title);
                let peers = hit.peers.unwrap_or(0).max(0) as i32;
                let id = hit
                    .guid
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| magnet.chars().take(80).collect());
                Some(StreamSource {
                    id,
                    title: if hit.title.trim().is_empty() {
                        "Untitled".into()
                    } else {
                        hit.title
                    },
                    magnet,
                    seeders,
                    peers,
                    rating: calculate_rating(seeders),
                    health: health_for(seeders).into(),
                    size: format_size(bytes),
                    tracker: hit
                        .tracker
                        .or(hit.tracker_id)
                        .unwrap_or_else(|| "unknown".into()),
                    indexer: hit.indexer.unwrap_or_else(|| "Jackett".into()),
                    language: stored_language(&langs, kind),
                })
            })
            .collect();
        if !preferred_lang.is_empty() && preferred_lang != "all" {
            let matched: Vec<StreamSource> = out
                .iter()
                .filter(|src| {
                    let found: Vec<&str> = src
                        .language
                        .split([',', '/', '|', '+'])
                        .map(str::trim)
                        .filter(|part| !part.is_empty())
                        .collect();
                    language_matches(&found, &preferred_lang, kind)
                })
                .cloned()
                .collect();
            if !matched.is_empty() {
                out = matched;
            }
        }
        rank_sources(out, &preferred_res)
    }

    fn redact_err(&self, err: reqwest::Error) -> AppError {
        jackett_err(connect_error_message(&err))
    }
}

pub fn normalize_jackett_url(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(jackett_err(
            "Enter a Jackett URL, for example http://127.0.0.1:9117.",
        ));
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("http://{trimmed}")
    };
    let parsed = reqwest::Url::parse(&with_scheme).map_err(|_| {
        jackett_err("That Jackett URL isn’t valid. Example: http://127.0.0.1:9117")
    })?;
    if parsed.host_str().is_none() {
        return Err(jackett_err(
            "That Jackett URL is missing a host. Example: http://127.0.0.1:9117",
        ));
    }
    let path = parsed.path().trim_end_matches('/');
    let lower = path.to_ascii_lowercase();
    let keep_path = if path.is_empty()
        || path == "/"
        || lower.contains("/api")
        || lower.contains("/ui")
        || lower.contains("/dashboard")
    {
        String::new()
    } else {
        path.to_string()
    };
    let mut out = format!(
        "{}://{}",
        parsed.scheme(),
        parsed.host_str().unwrap_or("127.0.0.1")
    );
    if let Some(port) = parsed.port() {
        out.push(':');
        out.push_str(&port.to_string());
    }
    out.push_str(&keep_path);
    Ok(out.trim_end_matches('/').to_string())
}

fn jackett_err(msg: impl Into<String>) -> AppError {
    AppError::Message(msg.into())
}

fn is_broken_indexer_error(err: &str) -> bool {
    let e = err.to_ascii_lowercase();
    e.contains("didn't match")
        || e.contains("didn\\u0027t match")
        || e.contains("parsing row")
        || e.contains("parsing field")
        || e.contains("tl-empty")
        || e.contains("no torrents found")
        || e.contains("selector")
}

fn indexer_fits_kind(id: &str, name: &str, kind: &str) -> bool {
    if kind == "anime" {
        return true;
    }
    let blob = format!("{id} {name}").to_ascii_lowercase();
    const ANIME_ONLY: &[&str] = &[
        "anirena",
        "nyaa",
        "animetosho",
        "subsplease",
        "horriblesubs",
        "anidex",
        "tokyotosho",
        "shittyanime",
        "animebytes",
        "bakabt",
        "anidub",
    ];
    !ANIME_ONLY.iter().any(|key| blob.contains(key))
}

fn healthy_hit_count(hits: &[JackettHit]) -> usize {
    hits.iter()
        .filter(|hit| hit.seeders.unwrap_or(0) >= 5 && torrent_locator(hit).is_some())
        .count()
}

fn connect_error_message(err: &reqwest::Error) -> String {
    if err.is_timeout() {
        return "Jackett took too long to respond. Make sure it’s running, then try again.".into();
    }
    if err.is_connect() {
        return "Can’t reach Jackett at this URL. Make sure Jackett is running and the URL in Settings is correct.".into();
    }
    let msg = err.to_string();
    if msg.contains("builder error") || msg.contains("relative URL") {
        return "Can’t reach Jackett. Use a full URL like http://127.0.0.1:9117.".into();
    }
    if msg.to_ascii_lowercase().contains("dns")
        || msg.contains("failed to lookup")
        || msg.contains("Name or service not known")
        || msg.contains("No such host")
    {
        return "Can’t find that Jackett host. Check the URL in Settings.".into();
    }
    if msg.contains("Connection refused") || msg.contains("connection refused") {
        return "Jackett isn’t accepting connections. Start Jackett and check the port in Settings.".into();
    }
    "Can’t reach Jackett at this URL. Make sure Jackett is running and the URL in Settings is correct.".into()
}

fn http_status_message(status: u16, body: &str) -> String {
    if needs_login(body) {
        return INDEXER_LOGIN_MSG.into();
    }
    match status {
        401 | 403 => {
            "Jackett rejected the API key. Copy it from Jackett and paste it in Settings.".into()
        }
        404 => "That Jackett URL was not found. Use the base address, like http://127.0.0.1:9117.".into(),
        429 => "Jackett is rate-limited right now. Wait a minute and try again.".into(),
        500..=599 => "Jackett had a problem. Make sure it’s running, then try again.".into(),
        _ => indexer_error_message(body),
    }
}

fn needs_login(raw: &str) -> bool {
    let lower = raw.to_ascii_lowercase();
    lower.contains("cookie") || lower.contains("login required") || lower.contains("sign in")
}

const INDEXER_LOGIN_MSG: &str =
    "A Jackett indexer needs a login. Open Jackett, sign in to that indexer or update its cookies, then try again.";

fn indexer_error_message(raw: &str) -> String {
    let text = raw
        .replace(['\n', '\r'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let text = text.trim().trim_matches('"');
    let text = text.strip_prefix("error:").unwrap_or(text).trim();
    let lower = text.to_ascii_lowercase();
    if needs_login(text) || lower.contains("http 400") {
        return INDEXER_LOGIN_MSG.into();
    }
    if text.is_empty() || lower == "build error" {
        return "Jackett’s indexers didn’t return results. Open Jackett and make sure they still work.".into();
    }
    if lower.contains("flaresolver") || lower.contains("cloudflare") {
        return "A Jackett indexer is blocked by Cloudflare. Check FlareSolverr in Jackett.".into();
    }
    if lower.contains("rate limit") || lower.contains("too many") {
        return "Jackett is being rate-limited. Wait a minute and try again.".into();
    }
    if lower.contains("timeout") || lower.contains("timed out") {
        return "Jackett timed out talking to an indexer. Try again in a moment.".into();
    }
    if lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("api key")
    {
        return "Jackett rejected the API key. Copy it from Jackett and paste it in Settings.".into();
    }
    "Jackett’s indexers didn’t return results. Open Jackett and make sure they still work.".into()
}

pub fn torrent_matches_episode(title: &str, season: i32, episode: i32) -> bool {
    if season <= 0 || episode <= 0 {
        return false;
    }
    let Ok(re) = regex::Regex::new(&format!(
        r"(?i)(?:^|[^a-z0-9])(?:s0*{season}e0*{episode}|0*{season}x0*{episode}|season[ ._-]*0*{season}[ ._-]*(?:episode[ ._-]*)?0*{episode})(?:[^0-9]|$)"
    )) else {
        return false;
    };
    re.is_match(title)
}

/// True for the exact episode or a season pack that can contain it (not a different episode).
pub fn torrent_usable_for_episode(title: &str, season: i32, episode: i32) -> bool {
    if season <= 0 || episode <= 0 {
        return false;
    }
    if torrent_matches_episode(title, season, episode) {
        return true;
    }
    if torrent_has_other_episode(title, season, episode) {
        return false;
    }
    torrent_is_season_pack(title, season)
}

fn torrent_has_other_episode(title: &str, season: i32, episode: i32) -> bool {
    let Ok(re) = regex::Regex::new(
        r"(?i)(?:^|[^a-z0-9])(?:s(\d{1,2})e(\d{1,3})|(\d{1,2})x(\d{1,3}))(?:[^0-9]|$)",
    ) else {
        return false;
    };
    for caps in re.captures_iter(title) {
        let (s, e) = if let (Some(a), Some(b)) = (caps.get(1), caps.get(2)) {
            (
                a.as_str().parse::<i32>().unwrap_or(0),
                b.as_str().parse::<i32>().unwrap_or(0),
            )
        } else if let (Some(a), Some(b)) = (caps.get(3), caps.get(4)) {
            (
                a.as_str().parse::<i32>().unwrap_or(0),
                b.as_str().parse::<i32>().unwrap_or(0),
            )
        } else {
            continue;
        };
        if s == season && e != episode {
            return true;
        }
        if s != season {
            return true;
        }
    }
    false
}

fn torrent_named_seasons(title: &str) -> Vec<i32> {
    let mut out = Vec::new();
    let h = padded(title);
    // Match " s01 " / " s1 " style tokens from the padded title.
    let Ok(re) = regex::Regex::new(r" s(\d{1,2}) ") else {
        return out;
    };
    for caps in re.captures_iter(&h) {
        if let Ok(n) = caps[1].parse::<i32>() {
            if n > 0 && !out.contains(&n) {
                out.push(n);
            }
        }
    }
    let Ok(re2) = regex::Regex::new(r" season (\d{1,2}) ") else {
        return out;
    };
    for caps in re2.captures_iter(&h) {
        if let Ok(n) = caps[1].parse::<i32>() {
            if n > 0 && !out.contains(&n) {
                out.push(n);
            }
        }
    }
    out
}

fn torrent_is_season_pack(title: &str, season: i32) -> bool {
    let h = padded(title);
    let seasons = torrent_named_seasons(title);
    if seasons.iter().any(|&s| s != season) && !seasons.contains(&season) {
        return false;
    }
    if seasons.contains(&season) {
        return true;
    }
    (has_token(&h, "complete") || has_token(&h, "pack")) && seasons.is_empty() && season == 1
}

fn looks_like_junk_release(title: &str, kind: &str) -> bool {
    let h = padded(title);
    const JUNK: &[&str] = &["xxx", "porn", "erotic", "adult"];
    if JUNK.iter().any(|t| has_token(&h, t)) {
        return true;
    }
    // Movies shouldn't come back as TV packs / episodes.
    if kind == "movie" {
        let Ok(tv) = regex::Regex::new(r"(?i)(?:^|[^a-z0-9])(?:s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3}|season[ ._-]*\d+)(?:[^0-9]|$)")
        else {
            return false;
        };
        if tv.is_match(title) {
            return true;
        }
    }
    false
}

fn size_plausible(bytes: u64, kind: &str, title: &str) -> bool {
    if bytes == 0 {
        // Jackett sometimes omits size; keep the hit and let ranking decide.
        return true;
    }
    let h = padded(title);
    let season_pack = has_token(&h, "complete")
        || has_token(&h, "pack")
        || has_token(&h, "season")
        || regex::Regex::new(r"(?i)(?:^|[^a-z0-9])s\d{1,2}(?!e\d)")
            .map(|re| re.is_match(title))
            .unwrap_or(false);
    const MB: u64 = 1024 * 1024;
    const GB: u64 = 1024 * MB;
    match kind {
        "movie" => bytes >= 350 * MB && bytes <= 40 * GB,
        "series" | "anime" if season_pack => bytes >= 200 * MB && bytes <= 100 * GB,
        "series" | "anime" => bytes >= 80 * MB && bytes <= 8 * GB,
        _ => bytes >= 80 * MB && bytes <= 40 * GB,
    }
}

/// Newznab/Torznab category IDs derived from the user's actual Jackett indexer list.
/// Using every relevant ID maximises hits across heterogeneous indexers.
fn kind_categories(kind: &str) -> &'static str {
    match kind {
        "movie" => {
            // Standard Newznab 2000-range + all known custom movie IDs from configured indexers
            "2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,\
             112696,100467,138189,128776,126854,106958,136609,133730,154011,122149,\
             110477,126839,162856,157842,131676,110210,114292,101316,117016,151624,\
             139470,153196,3100000,3107000,3106000,3104000,3105000,3101000,3108000,\
             3102000,3103000,125870,102000,100201,100501,100202,100502,100211,100507,\
             131538,101535,131001,135672,112170,108211,104516,124884,107093,158611,\
             145382,100044,100045,100046,100047"
        }
        "series" => {
            // Standard Newznab 5000-range + all known custom TV/series IDs
            "5000,5010,5020,5030,5040,5045,5050,5060,5080,\
             143862,112972,100208,100212,111963,158099,113405,149728,131655,144345,\
             100795,144174,105852"
        }
        "anime" => {
            // Anime-specific IDs from all known indexers — broadest coverage
            "5070,\
             100028,100078,100079,100080,100081,100001,146065,151474,117370,135022,\
             124996,125940,143839,131371,120491,101078,6100000,6103000,6102000,\
             6108000,6104000,6101000,105070,140679,125996,127720,131088,134634,\
             164586,139278,125620,\
             100001,100002,100004,100007,100008,100009,100010,100011,100012,100013,\
             100014,100015"
        }
        _ => "",
    }
}

fn build_query(
    query: &str,
    kind: &str,
    season: Option<i32>,
    episode: Option<i32>,
    language: &str,
) -> String {
    let mut q = query.trim().to_string();
    if let (Some(s), Some(e)) = (season, episode) {
        let tag = format!("S{s:02}E{e:02}");
        if !q.to_ascii_uppercase().contains(&tag) {
            q.push(' ');
            q.push_str(&tag);
        }
    } else if kind == "series" || kind == "anime" {
        // keep title-only; season chips can pass S/E later
    }
    if !language.contains(',') {
        if let Some(term) = language_query_term(language) {
            if !(kind == "anime" && language.eq_ignore_ascii_case("ja")) {
                q.push(' ');
                q.push_str(term);
            }
        }
    }
    q
}

fn torrent_locator(hit: &JackettHit) -> Option<String> {
    for raw in [hit.magnet_uri.as_deref(), hit.link.as_deref()]
        .into_iter()
        .flatten()
    {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let lower = trimmed.to_ascii_lowercase();
        if lower.starts_with("magnet:") || lower.starts_with("http://") || lower.starts_with("https://")
        {
            return Some(trimmed.to_string());
        }
    }
    None
}

fn looks_like_sample(title: &str) -> bool {
    let h = padded(title);
    [
        "sample", "trailer", "extra", "extras", "featurette", "featurettes", "bonus", "promo",
    ]
    .iter()
    .any(|t| has_token(&h, t))
}

fn padded(title: &str) -> String {
    let mut out = String::from(" ");
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(' ');
        }
    }
    out.push(' ');
    out
}

fn has_token(haystack: &str, token: &str) -> bool {
    haystack.contains(&format!(" {token} "))
}

fn language_codes(title: &str) -> Vec<&'static str> {
    let h = padded(title);
    let mut out = Vec::new();
    let mut push = |code: &'static str, tokens: &[&str]| {
        if out.contains(&code) {
            return;
        }
        if tokens.iter().any(|t| has_token(&h, t)) {
            out.push(code);
        }
    };
    push("hi", &["hindi", "hin"]);
    push("ja", &["japanese", "nihongo", "jpn", "jap"]);
    push("ko", &["korean", "korea", "kor"]);
    push("zh", &["chinese", "mandarin", "cantonese", "chs", "cht"]);
    push("es", &["spanish", "espanol", "latino", "castellano", "latam"]);
    push("fr", &["french", "francais", "vff", "vfi", "truefrench"]);
    push("de", &["german", "deutsch"]);
    push("it", &["italian", "italiano", "ita"]);
    push("pt", &["portuguese", "brazilian", "ptbr", "brasil"]);
    push("ar", &["arabic"]);
    push("tr", &["turkish", "turkce"]);
    push("ru", &["russian", "rus"]);
    push("th", &["thai"]);
    push("id", &["indonesian", "bahasa"]);
    push("en", &["english", "eng"]);
    if has_token(&h, "multi") || has_token(&h, "dual") {
        if !out.contains(&"multi") {
            out.push("multi");
        }
    }
    out
}

pub fn languages_for_title(title: &str) -> String {
    language_codes(title).join(",")
}

fn language_matches(found: &[&str], preferred: &str, kind: &str) -> bool {
    let wanted: Vec<String> = preferred
        .split([',', '/', '|', '+'])
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| !part.is_empty() && part != "all")
        .collect();
    if wanted.is_empty() {
        return true;
    }
    if found.iter().any(|c| *c == "multi") {
        return true;
    }
    if found.iter().any(|c| wanted.iter().any(|w| w == c)) {
        return true;
    }
    if found.is_empty() {
        return wanted
            .iter()
            .any(|w| w == "en" || (w == "ja" && kind == "anime"));
    }
    false
}

fn stored_language(found: &[&str], kind: &str) -> String {
    if found.is_empty() {
        return if kind == "anime" {
            "ja".into()
        } else {
            "en".into()
        };
    }
    found.join(",")
}

fn language_query_term(code: &str) -> Option<&'static str> {
    match code.trim().to_ascii_lowercase().as_str() {
        "" | "all" | "en" => None,
        "ja" => Some("Japanese"),
        "ko" => Some("Korean"),
        "zh" => Some("Chinese"),
        "hi" => Some("Hindi"),
        "es" => Some("Spanish"),
        "fr" => Some("French"),
        "de" => Some("German"),
        "it" => Some("Italian"),
        "pt" => Some("Portuguese"),
        "ar" => Some("Arabic"),
        "tr" => Some("Turkish"),
        "ru" => Some("Russian"),
        "th" => Some("Thai"),
        "id" => Some("Indonesian"),
        _ => None,
    }
}

pub fn calculate_rating(seeders: i32) -> i32 {
    match seeders {
        0 => 1,
        1..=4 => 2,
        5..=19 => 3,
        20..=49 => 4,
        _ => 5,
    }
}

pub fn health_for(seeders: i32) -> &'static str {
    match seeders {
        0 => "dead",
        1..=4 => "poor",
        5..=19 => "decent",
        20..=49 => "good",
        _ => "excellent",
    }
}

/// Rank playable torrents: magnets + quality + seeders, drop weak swarms.
pub fn rank_sources(mut out: Vec<StreamSource>, preferred_resolution: &str) -> Vec<StreamSource> {
    let preferred_res = preferred_resolution.trim().to_ascii_lowercase();
    // Prefer real magnets — raw .torrent HTTP links often fail to start.
    let magnets: Vec<StreamSource> = out
        .iter()
        .filter(|s| s.magnet.to_ascii_lowercase().starts_with("magnet:"))
        .cloned()
        .collect();
    if magnets.len() >= 2 {
        out = magnets;
    }
    out.retain(|s| s.seeders >= 5 && source_quality_score(&s.title) >= 2);
    out.sort_by(|a, b| {
        let a_magnet = a.magnet.to_ascii_lowercase().starts_with("magnet:") as i32;
        let b_magnet = b.magnet.to_ascii_lowercase().starts_with("magnet:") as i32;
        let a_exact = episode_specificity(&a.title);
        let b_exact = episode_specificity(&b.title);
        b_magnet
            .cmp(&a_magnet)
            .then(b_exact.cmp(&a_exact))
            .then(
                resolution_rank(&b.title, &preferred_res)
                    .cmp(&resolution_rank(&a.title, &preferred_res)),
            )
            .then(source_quality_score(&b.title).cmp(&source_quality_score(&a.title)))
            .then(b.seeders.cmp(&a.seeders))
            .then(b.peers.cmp(&a.peers))
    });
    let strong: Vec<StreamSource> = out
        .iter()
        .filter(|s| {
            s.seeders >= 10
                && source_quality_score(&s.title) >= 3
                && resolution_rank(&s.title, &preferred_res) >= 1
        })
        .cloned()
        .collect();
    if strong.len() >= 2 {
        return strong.into_iter().take(8).collect();
    }
    let matching: Vec<StreamSource> = out
        .iter()
        .filter(|s| s.seeders >= 8 && resolution_rank(&s.title, &preferred_res) >= 2)
        .cloned()
        .collect();
    if !matching.is_empty() {
        return matching.into_iter().take(8).collect();
    }
    let proper: Vec<StreamSource> = out
        .iter()
        .filter(|s| s.seeders >= 8 && source_quality_score(&s.title) >= 3)
        .cloned()
        .collect();
    if proper.len() >= 2 {
        return proper.into_iter().take(8).collect();
    }
    let healthy: Vec<StreamSource> = out.iter().filter(|s| s.seeders >= 5).cloned().collect();
    healthy.into_iter().take(8).collect()
}

/// Prefer single-episode releases over season packs when both are listed.
fn episode_specificity(title: &str) -> i32 {
    if regex::Regex::new(r"(?i)(?:^|[^a-z0-9])s\d{1,2}e\d{1,3}(?:[^0-9]|$)")
        .map(|re| re.is_match(title))
        .unwrap_or(false)
    {
        return 2;
    }
    if regex::Regex::new(r"(?i)(?:^|[^a-z0-9])\d{1,2}x\d{1,3}(?:[^0-9]|$)")
        .map(|re| re.is_match(title))
        .unwrap_or(false)
    {
        return 2;
    }
    1
}

pub fn cache_is_strong(sources: &[StreamSource], preferred_resolution: &str) -> bool {
    let preferred_res = preferred_resolution.trim().to_ascii_lowercase();
    let proper: Vec<&StreamSource> = sources
        .iter()
        .filter(|s| s.seeders >= 5 && source_quality_score(&s.title) >= 3)
        .collect();
    if proper.len() >= 2 && proper.iter().any(|s| s.seeders >= 25) {
        return true;
    }
    sources
        .iter()
        .filter(|s| {
            s.seeders >= 5
                && !preferred_res.is_empty()
                && s.title.to_ascii_lowercase().contains(&preferred_res)
        })
        .count()
        >= 2
}

fn source_quality_score(title: &str) -> i32 {
    let h = padded(title);
    if looks_like_cam(&h) {
        return 0;
    }
    if has_token(&h, "remux") {
        return 6;
    }
    if has_token(&h, "bluray")
        || has_token(&h, "bdrip")
        || has_token(&h, "bdremux")
        || has_token(&h, "uhd")
        || (has_token(&h, "blu") && has_token(&h, "ray"))
    {
        return 5;
    }
    if has_token(&h, "webdl")
        || has_token(&h, "webrip")
        || (has_token(&h, "web") && (has_token(&h, "dl") || has_token(&h, "rip")))
    {
        return 4;
    }
    if has_token(&h, "hdtv") {
        return 3;
    }
    2
}

fn looks_like_cam(padded_title: &str) -> bool {
    [
        "cam", "camrip", "hdcam", "hdts", "telesync", "telecine", "hd-ts", "hd-tc", "screener",
        "dvdscr", "r5",
    ]
    .iter()
    .any(|t| has_token(padded_title, t))
        || has_token(padded_title, "ts")
        || has_token(padded_title, "tc")
}

fn resolution_rank(title: &str, preferred: &str) -> i32 {
    let t = title.to_ascii_lowercase();
    if !preferred.is_empty() && t.contains(preferred) {
        return 2;
    }
    if t.contains("2160p") || t.contains("1080p") || t.contains("720p") {
        return 1;
    }
    0
}

fn format_size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let n = bytes as f64;
    if n >= GB {
        format!("{:.1} GB", n / GB)
    } else if n >= MB {
        format!("{:.0} MB", n / MB)
    } else if n >= KB {
        format!("{:.0} KB", n / KB)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_jackett_url;

    #[test]
    fn adds_scheme() {
        assert_eq!(
            normalize_jackett_url("127.0.0.1:9117").unwrap(),
            "http://127.0.0.1:9117"
        );
    }

    #[test]
    fn strips_dashboard() {
        assert_eq!(
            normalize_jackett_url("http://127.0.0.1:9117/UI/Dashboard").unwrap(),
            "http://127.0.0.1:9117"
        );
    }

    #[test]
    fn strips_torznab_feed() {
        assert_eq!(
            normalize_jackett_url(
                "http://10.0.0.5:9117/api/v2.0/indexers/all/results/torznab"
            )
            .unwrap(),
            "http://10.0.0.5:9117"
        );
    }

    #[test]
    fn maps_build_error() {
        assert!(super::indexer_error_message("build error").contains("indexers"));
    }

    #[test]
    fn episode_pattern_matches_common_names() {
        assert!(super::torrent_matches_episode("Show.Name.S02E05.1080p.WEB", 2, 5));
        assert!(super::torrent_matches_episode("Show Name 2x05 BluRay", 2, 5));
        assert!(!super::torrent_matches_episode("Show.Name.S02E15.1080p", 2, 5));
        assert!(!super::torrent_matches_episode("Show.Name.S12E05.1080p", 2, 5));
    }

    #[test]
    fn season_packs_are_usable_for_episodes() {
        assert!(super::torrent_usable_for_episode(
            "Show.Name.S02.Complete.1080p.WEB",
            2,
            5
        ));
        assert!(super::torrent_usable_for_episode("Show Name Season 2 Pack", 2, 1));
        assert!(!super::torrent_usable_for_episode("Show.Name.S02E04.1080p", 2, 5));
        assert!(!super::torrent_usable_for_episode("Show.Name.S01.Complete", 2, 5));
    }

    #[test]
    fn rejects_cam_and_tv_leaks_for_movies() {
        assert!(super::looks_like_cam(&super::padded("Movie.2024.HDCam.x264")));
        assert!(super::looks_like_junk_release("Show.S01E01.1080p", "movie"));
        assert!(!super::looks_like_junk_release("Movie.2024.1080p.BluRay", "movie"));
    }

    #[test]
    fn maps_http_unauthorized() {
        assert!(super::http_status_message(401, "").contains("API key"));
    }

    #[test]
    fn maps_cookies_required() {
        assert!(super::http_status_message(400, "cookies required").contains("login"));
        assert!(super::indexer_error_message("Jackett: HTTP 400: cookies required").contains("login"));
    }

    #[test]
    fn unlabeled_title_is_english() {
        let found = super::language_codes("Dune.2024.1080p.BluRay.x264");
        assert!(found.is_empty());
        assert!(super::language_matches(&found, "en", "movie"));
        assert!(!super::language_matches(&found, "hi", "movie"));
    }

    #[test]
    fn hindi_tag_matches_hindi_only() {
        let found = super::language_codes("Dune 2024 Hindi 1080p");
        assert!(found.contains(&"hi"));
        assert!(super::language_matches(&found, "hi", "movie"));
        assert!(!super::language_matches(&found, "en", "movie"));
    }

    #[test]
    fn unlabeled_anime_matches_japanese() {
        let found = super::language_codes("Shogun S01E01 1080p WEB-DL");
        assert!(found.is_empty());
        assert!(super::language_matches(&found, "ja", "anime"));
        assert!(!super::language_matches(&found, "ja", "movie"));
    }

    #[test]
    fn language_query_skips_english() {
        assert_eq!(super::language_query_term("en"), None);
        assert_eq!(super::language_query_term("hi"), Some("Hindi"));
        assert!(super::build_query("Dune", "movie", None, None, "hi").contains("Hindi"));
        assert!(!super::build_query("Dune", "movie", None, None, "en").contains("English"));
    }
}
