use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;

use crate::error::{AppError, Result};
use crate::graphql::types::StreamSource;

/// A stream search gets up to a minute of Jackett before the Stremio add-ons
/// are asked (slow indexers used to be cut at 5–8 s, so Torrentio answered
/// while Jackett still had results coming). The three passes below add up to
/// [STREAM_SEARCH_BUDGET]; each still returns early once the picker has enough.
pub const STREAM_SEARCH_BUDGET: Duration = Duration::from_secs(60);
const STREAM_TORZNAB_BUDGET: Duration = Duration::from_secs(25);
const STREAM_INDEXER_BUDGET: Duration = Duration::from_secs(15);
const STREAM_ALL_BUDGET: Duration = Duration::from_secs(20);

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
    /// Newznab category IDs (e.g. 2000 movie, 5000 TV, 6000 XXX).
    #[serde(default, rename = "Category")]
    category: Vec<i32>,
    #[serde(default, rename = "CategoryDesc")]
    category_desc: Option<String>,
    /// Found by an exact IMDb-id search — skips the title/year check.
    #[serde(skip)]
    id_matched: bool,
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
        // Streaming searches: Jackett /all can take 20–50s on a cold query.
        // Old 18s client timeout returned "took too long" while Jackett still
        // finished and cached (visible in Jackett logs).
        let http = reqwest::Client::builder()
            .user_agent("PeanutButter")
            .timeout(Duration::from_secs(90))
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
        target: &SearchTarget,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
        preferred_resolution: &str,
        preferred_language: &str,
    ) -> Result<Vec<StreamSource>> {
        let q = build_query(&target.title, kind, season, episode, None, preferred_language);
        if q.trim().is_empty() {
            return Ok(vec![]);
        }
        let strict = |v: Vec<StreamSource>| -> Vec<StreamSource> {
            v.into_iter().filter(|s| target.matches(&s.title, kind)).collect()
        };

        // Fast path only: parallel Torznab against a small ranked indexer set.
        // Do NOT race `/all/results` at the same time — that hammered Jackett and
        // made every search wait on the slowest indexer (20–50s).
        let torznab = self
            .search_torznab_all(
                target,
                kind,
                season,
                episode,
                preferred_resolution,
                preferred_language,
            )
            .await
            .unwrap_or_default();
        let mut found = Self::filter_episode(torznab, season, episode);
        if picker_ready(&found) {
            return Ok(found);
        }

        // Thin Torznab result → quick Query+Category pass (still early-exits).
        let plain = self
            .search_indexers_individually(&q, preferred_resolution, preferred_language, kind, Some(target))
            .await
            .unwrap_or_default();
        found = merge_ranked(
            found,
            Self::filter_episode(plain, season, episode),
            preferred_resolution,
        );
        if picker_ready(&found) {
            return Ok(found);
        }

        // Last resort: aggregate search with what's left of the minute.
        let all = match tokio::time::timeout(
            STREAM_ALL_BUDGET,
            self.search_all_results(&q, kind, preferred_resolution, preferred_language),
        )
        .await
        {
            Ok(Ok(v)) => Self::filter_episode(strict(v), season, episode),
            _ => Vec::new(),
        };
        Ok(merge_ranked(found, all, preferred_resolution))
    }

    async fn search_all_results(
        &self,
        query: &str,
        kind: &str,
        preferred_resolution: &str,
        preferred_language: &str,
    ) -> Result<Vec<StreamSource>> {
        let url = format!("{}/api/v2.0/indexers/all/results", self.base_url);
        // Jackett binds Category as int[] — comma-joined strings are ignored and
        // the search falls back to every category (including XXX).
        let mut req = self.http.get(&url).query(&[
            ("apikey", self.api_key.as_str()),
            ("Query", query),
        ]);
        for cat in kind_category_ids(kind) {
            req = req.query(&[("Category", cat.to_string())]);
        }
        let res = match tokio::time::timeout(STREAM_ALL_BUDGET, req.send()).await {
            Ok(Ok(res)) => res,
            Ok(Err(e)) => return Err(self.redact_err(e)),
            Err(_) => {
                return Err(jackett_err(
                    "Jackett took too long to respond. Try again in a moment.",
                ));
            }
        };
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
            let results = self.transform_results(
                body.results,
                preferred_resolution,
                preferred_language,
                kind,
            );
            if !results.is_empty() {
                return Ok(results);
            }
            let cookie_blocked = body
                .indexers
                .iter()
                .filter_map(|i| i.error.as_deref())
                .any(needs_login);
            if cookie_blocked {
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
            return Ok(results);
        }
        let status = res.status().as_u16();
        let body = res.text().await.unwrap_or_default();
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
        let q = build_query(query, kind, None, None, None, "");
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

    /// Torznab search: hit kind-matching indexers in parallel and stop once we have
    /// enough healthy releases. Falls back gracefully if an indexer doesn't support it.
    async fn search_torznab_all(
        &self,
        target: &SearchTarget,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
        preferred_resolution: &str,
        preferred_language: &str,
    ) -> Result<Vec<StreamSource>> {
        let caps = self.indexer_caps().await;
        let mut ids = self.ranked_indexer_ids(kind, 10).await;
        if ids.is_empty() {
            return Ok(vec![]);
        }
        // Movies: indexers that take an IMDb id give exact matches — ask them first.
        if kind == "movie" && target.imdb().is_some() {
            ids.sort_by_key(|id| !caps.get(id).is_some_and(|c| c.movie_imdb));
        }
        ids.truncate(7);
        // Exact-match indexers still running: don't stop early on text hits
        // while one of them may return the best (correct) releases.
        let mut id_pending: HashSet<String> = if kind == "movie" && target.imdb().is_some() {
            ids.iter()
                .filter(|id| caps.get(*id).is_some_and(|c| c.movie_imdb))
                .cloned()
                .collect()
        } else {
            HashSet::new()
        };
        let mut set = tokio::task::JoinSet::new();
        for id in &ids {
            let this = self.clone();
            let id = id.clone();
            let kind = kind.to_string();
            let caps = caps.get(&id).cloned();
            let target = target.clone();
            set.spawn(async move {
                let result = tokio::time::timeout(
                    STREAM_TORZNAB_BUDGET,
                    this.search_torznab_one(&id, caps.as_ref(), &target, &kind, season, episode),
                )
                .await;
                (id, result)
            });
        }
        let mut hits: Vec<JackettHit> = Vec::new();
        while let Some(joined) = set.join_next().await {
            let Ok((id, timed)) = joined else { continue };
            id_pending.remove(&id);
            match timed {
                Ok(Ok(mut batch)) => {
                    // Only releases of *this* title count toward stopping early.
                    batch.retain(|h| h.id_matched || target.matches(&h.title, kind));
                    hits.extend(batch);
                    // Return as soon as we have a usable picker set.
                    if id_pending.is_empty()
                        && (healthy_hit_count(&hits) >= 2 || magnet_hit_count(&hits) >= 8)
                    {
                        set.abort_all();
                        break;
                    }
                }
                Ok(Err(ref e)) if e == "rate_limited" => self.skip_indexer(&id),
                Ok(Err(e)) if is_broken_indexer_error(&e) => self.skip_indexer(&id),
                Err(_) => {}
                Ok(Err(_)) => {}
            }
        }
        Ok(self.transform_results(hits, preferred_resolution, preferred_language, kind))
    }

    async fn fetch_indexer_results(
        &self,
        url: &str,
        params: &[(&str, String)],
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let res = self
            .http
            .get(url)
            .query(params)
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
            {
                let mut req = self.catalog_http.get(&url).query(&[
                    ("apikey", self.api_key.as_str()),
                    ("Query", query),
                ]);
                for cat in kind_category_ids(kind) {
                    req = req.query(&[("Category", cat.to_string())]);
                }
                req.send()
            },
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

    async fn catalog_indexer_ids(&self, kind: &str) -> Vec<String> {
        self.ranked_indexer_ids(kind, 4).await
    }

    /// Live Play searches: few ranked indexers — more just slows Jackett.
    async fn stream_indexer_ids(&self, kind: &str) -> Vec<String> {
        self.ranked_indexer_ids(kind, 6).await
    }

    async fn ranked_indexer_ids(&self, kind: &str, limit: usize) -> Vec<String> {
        let skip = self
            .skip_indexers
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let mut rows: Vec<(i32, String)> = self
            .load_indexers()
            .await
            .into_iter()
            .filter(|ix| !skip.contains(&ix.id))
            .filter(|ix| !is_broken_indexer_error(&ix.last_error))
            .filter(|ix| indexer_fits_kind(&ix.id, &ix.name, kind))
            .map(|ix| {
                let rank = indexer_priority(&ix.id, &ix.name, kind);
                (rank, ix.id)
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        rows.into_iter().map(|(_, id)| id).take(limit).collect()
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
            // A Jackett admin password makes this JSON endpoint redirect to
            // the login page even with the API key; the Torznab indexer list
            // accepts the key. Without this every search fell through to the
            // slow aggregate /all/results.
            _ => return self.load_indexers_torznab().await,
        };
        let rows: Vec<IndexerListItem> = match res.json().await {
            Ok(rows) => rows,
            Err(_) => return self.load_indexers_torznab().await,
        };
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
        let mut req = http.get(&url).query(&[
            ("apikey", self.api_key.as_str()),
            ("Query", query),
        ]);
        // Prefer explicit Category[] ints. Fall back to parsing a comma list.
        if let Some(cats) = categories.filter(|s| !s.is_empty()) {
            for part in cats.split(',') {
                let part = part.trim();
                if !part.is_empty() {
                    req = req.query(&[("Category", part)]);
                }
            }
        }
        let res = req
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
        target: Option<&SearchTarget>,
    ) -> Result<Vec<StreamSource>> {
        let ids = self.stream_indexer_ids(kind).await;
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let mut set = tokio::task::JoinSet::new();
        for id in ids {
            let this = self.clone();
            let q = query.to_string();
            let kind2 = kind.to_string();
            set.spawn(async move {
                let result = tokio::time::timeout(
                    STREAM_INDEXER_BUDGET,
                    this.search_one_indexer(&id, &q, &kind2),
                )
                .await;
                (id, result)
            });
        }
        let mut hits = Vec::new();
        while let Some(joined) = set.join_next().await {
            let Ok((id, timed)) = joined else { continue };
            match timed {
                Ok(Ok(mut batch)) => {
                    if let Some(t) = target {
                        batch.retain(|h| t.matches(&h.title, kind));
                    }
                    hits.extend(batch);
                    if healthy_hit_count(&hits) >= 2 || magnet_hit_count(&hits) >= 8 {
                        set.abort_all();
                        break;
                    }
                }
                Ok(Err(ref e)) if e == "rate_limited" => self.skip_indexer(&id),
                Ok(Err(e)) if is_broken_indexer_error(&e) => self.skip_indexer(&id),
                Err(_) => {}
                Ok(Err(_)) => {}
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
                if looks_like_sign_language(&hit.title) {
                    return None;
                }
                if looks_like_junk_release(&hit.title, kind) {
                    return None;
                }
                if !hit_category_allowed(&hit, kind) {
                    return None;
                }
                let bytes = hit.size.unwrap_or(0).max(0) as u64;
                if !size_plausible(bytes, kind, &hit.title) {
                    return None;
                }
                // Jackett uses missing / negative Seeders when the indexer doesn't
                // report swarm stats (common on TPB, Lime, Knaben, …). Many public
                // trackers also report 0 even for live swarms — don't hard-drop here;
                // rank_sources prefers real seeders and falls back to unknowns.
                let seeders_raw = hit.seeders.unwrap_or(-1);
                let seeders_unknown = seeders_raw < 0;
                let seeders = seeders_raw.max(0) as i32;
                let peers = hit.peers.unwrap_or(0).max(0) as i32;
                let langs = language_codes(&hit.title);
                let id = hit
                    .guid
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| magnet.chars().take(80).collect());
                // Rank unknown-seeder magnets as "poor but tryable" (1), not dead (0).
                let rank_seeders = if seeders_unknown { 1 } else { seeders };
                Some(StreamSource {
                    id,
                    title: if hit.title.trim().is_empty() {
                        "Untitled".into()
                    } else {
                        hit.title
                    },
                    magnet,
                    seeders: rank_seeders,
                    peers,
                    rating: calculate_rating(rank_seeders),
                    health: if seeders_unknown {
                        "unknown".into()
                    } else {
                        health_for(seeders).into()
                    },
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
            // Preferred languages + multi. Untagged Western releases ≈ English.
            out = out
                .into_iter()
                .filter(|src| {
                    let found: Vec<&str> = src
                        .language
                        .split([',', '/', '|', '+'])
                        .map(str::trim)
                        .filter(|part| !part.is_empty() && *part != "unknown")
                        .collect();
                    language_matches(&found, &preferred_lang, kind)
                })
                .collect();
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
    let blob = format!("{id} {name}").to_ascii_lowercase();
    const ANIME_ONLY: &[&str] = &[
        "anirena",
        "nyaa",
        "animetosho",
        "subsplease",
        "horriblesubs",
        "anidex",
        "tokyotosho",
        "tokyo toshokan",
        "shittyanime",
        "animebytes",
        "bakabt",
        "anidub",
        "bangumi",
        "nekobt",
        "shanaproject",
        "shana project",
    ];
    const MOVIE_ONLY: &[&str] = &["yts", "yify"];
    const TV_ONLY: &[&str] = &["eztv", "showrss"];

    match kind {
        "anime" => true,
        "movie" => {
            !ANIME_ONLY.iter().any(|key| blob.contains(key))
                && !TV_ONLY.iter().any(|key| blob.contains(key))
        }
        "series" => {
            !ANIME_ONLY.iter().any(|key| blob.contains(key))
                && !MOVIE_ONLY.iter().any(|key| blob.contains(key))
        }
        _ => !ANIME_ONLY.iter().any(|key| blob.contains(key)),
    }
}

/// Lower is better. Prefer kind-specialized public trackers first.
fn indexer_priority(id: &str, name: &str, kind: &str) -> i32 {
    let blob = format!("{id} {name}").to_ascii_lowercase();
    let prefers = match kind {
        "movie" => &["yts", "1337x", "piratebay", "torrentgalaxy", "rarbg", "limetorrents"][..],
        "series" => &["eztv", "showrss", "1337x", "piratebay", "torrentgalaxy", "rarbg", "limetorrents"][..],
        "anime" => &["nyaa", "subsplease", "animetosho", "anirena", "tokyotosho", "bangumi"][..],
        _ => &[][..],
    };
    for (i, key) in prefers.iter().enumerate() {
        if blob.contains(key) {
            return i as i32;
        }
    }
    100
}

fn healthy_hit_count(hits: &[JackettHit]) -> usize {
    hits.iter()
        .filter(|hit| hit.seeders.unwrap_or(0) >= 3 && torrent_locator(hit).is_some())
        .count()
}

fn magnet_hit_count(hits: &[JackettHit]) -> usize {
    hits.iter().filter(|hit| torrent_locator(hit).is_some()).count()
}

/// Enough results to show the picker without waiting on slower indexers.
fn picker_ready(sources: &[StreamSource]) -> bool {
    if sources.len() >= 4 {
        return true;
    }
    sources.iter().filter(|s| s.seeders >= 3).count() >= 2
}

fn merge_ranked(
    a: Vec<StreamSource>,
    b: Vec<StreamSource>,
    preferred_resolution: &str,
) -> Vec<StreamSource> {
    if b.is_empty() {
        return a;
    }
    if a.is_empty() {
        return b;
    }
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(a.len() + b.len());
    for src in a.into_iter().chain(b) {
        let key = src.magnet.trim().to_ascii_lowercase();
        if key.is_empty() || !seen.insert(key) {
            continue;
        }
        out.push(src);
    }
    rank_sources(out, preferred_resolution)
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
        r"(?i)(?:^|[^a-z0-9])(?:s0*{season}[ ._-]?e0*{episode}|0*{season}x0*{episode}|season[ ._-]*0*{season}[ ._-]*(?:episode[ ._-]*)?0*{episode})(?:[^0-9]|$)"
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
    const JUNK: &[&str] = &[
        "xxx", "porn", "erotic", "adult", "hentai", "jav ", " jave ", "nsfw", "onlyfans",
        "pussy", "blowjob", "anal", "fetish", "brazzers", "realitykings",
    ];
    if JUNK.iter().any(|t| has_token(&h, t.trim()) || h.contains(t)) {
        return true;
    }
    // Movies shouldn't come back as TV packs / episodes.
    if kind == "movie" {
        let Ok(tv) = regex::Regex::new(
            r"(?i)(?:^|[^a-z0-9])(?:s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3}|season[ ._-]*\d+)(?:[^0-9]|$)",
        ) else {
            return false;
        };
        if tv.is_match(title) {
            return true;
        }
    }
    // Series shouldn't come back as standalone movie rips (year + no SxxExx).
    // Anime often ships film OVAs with a year and no episode tag — leave those.
    if kind == "series" {
        let has_ep = regex::Regex::new(
            r"(?i)(?:^|[^a-z0-9])(?:s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3}|season[ ._-]*\d+|complete|pack)(?:[^0-9]|$)",
        )
        .map(|re| re.is_match(title))
        .unwrap_or(false);
        let has_year = regex::Regex::new(r"(?i)(?:^|[^a-z0-9])(?:19|20)\d{2}(?:[^0-9]|$)")
            .map(|re| re.is_match(title))
            .unwrap_or(false);
        // Keep season packs / episodes; drop bare "Title.2024.1080p" movie dumps.
        if has_year && !has_ep {
            return true;
        }
    }
    false
}

/// True when Jackett tagged the hit with an allowed Newznab category for [kind].
/// Always reject XXX (6000–6999). Empty categories → keep (title filters apply).
fn hit_category_allowed(hit: &JackettHit, kind: &str) -> bool {
    let cats = &hit.category;
    if cats.iter().any(|c| is_xxx_category(*c)) {
        return false;
    }
    if let Some(desc) = hit.category_desc.as_deref() {
        let d = desc.to_ascii_lowercase();
        if d.contains("xxx") || d.contains("adult") || d.contains("porn") {
            return false;
        }
    }
    if cats.is_empty() {
        return true;
    }
    let allowed = kind_category_ids(kind);
    cats.iter().any(|c| category_matches_allowed(*c, &allowed))
}

fn is_xxx_category(c: i32) -> bool {
    (6000..7000).contains(&c)
}

fn category_matches_allowed(c: i32, allowed: &[i32]) -> bool {
    if allowed.contains(&c) {
        return true;
    }
    // Parent bucket (e.g. 2000) covers children 2010–2099 when listed.
    for &a in allowed {
        if a % 1000 == 0 && c > a && c < a + 1000 {
            return true;
        }
        // Child implies parent was requested.
        if c % 1000 == 0 && a > c && a < c + 1000 {
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
        // Keep small 720p encodes; still drop tiny fakes / enormous dumps.
        "movie" => bytes >= 250 * MB && bytes <= 50 * GB,
        "series" | "anime" if season_pack => bytes >= 150 * MB && bytes <= 120 * GB,
        "series" | "anime" => bytes >= 60 * MB && bytes <= 10 * GB,
        _ => bytes >= 60 * MB && bytes <= 50 * GB,
    }
}

/// Newznab/Torznab categories from the user's Jackett install (movies / TV only).
fn kind_categories(kind: &str) -> &'static str {
    match kind {
        // Movies: 2000 + HD/SD/UHD/3D/DVD children — never XXX (6000+)
        "movie" => "2000,2010,2020,2030,2040,2045,2060,2070",
        // TV only — never movies (2000) or XXX
        "series" => "5000,5020,5030,5040,5045,5050,5060,5070,5080",
        // Anime: Torznab anime + overlapping TV cats
        "anime" => "5070,5000,5040,5045,5080",
        _ => "",
    }
}

fn kind_category_ids(kind: &str) -> Vec<i32> {
    kind_categories(kind)
        .split(',')
        .filter_map(|s| s.trim().parse::<i32>().ok())
        .collect()
}

fn build_query(
    query: &str,
    kind: &str,
    season: Option<i32>,
    episode: Option<i32>,
    year: Option<i32>,
    language: &str,
) -> String {
    // Strip client-baked SxxExx / year so we don't double them up.
    let mut q = strip_episode_tag(query.trim());
    q = strip_trailing_year(&q);
    if q.is_empty() {
        return String::new();
    }

    if let (Some(s), Some(e)) = (season, episode) {
        let tag = format!("S{s:02}E{e:02}");
        if !q.to_ascii_uppercase().contains(&tag) {
            q.push(' ');
            q.push_str(&tag);
        }
    }

    // Never bake year or language into the query — both wipe healthy Jackett hits.
    let _ = (kind, year, language);
    q
}

fn strip_episode_tag(raw: &str) -> String {
    let re = regex::Regex::new(
        r"(?i)(?:^|\s)(?:s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3})(?:\s|$)",
    )
    .ok();
    let Some(re) = re else {
        return raw.to_string();
    };
    re.replace_all(raw, " ").to_string().split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_trailing_year(raw: &str) -> String {
    let re = regex::Regex::new(r"(?i)(?:^|\s)((?:19|20)\d{2})\s*$").ok();
    let Some(re) = re else {
        return raw.to_string();
    };
    re.replace(raw, "").to_string().trim().to_string()
}

fn primary_language_term(language: &str) -> Option<&'static str> {
    for part in language.split([',', '/', '|', '+']) {
        if let Some(term) = language_query_term(part.trim()) {
            return Some(term);
        }
    }
    None
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

/// Drop ASL / BSL / "sign language" releases — they look untagged English to
/// language filters and are useless for spoken-language playback.
fn looks_like_sign_language(title: &str) -> bool {
    let t = title.to_ascii_lowercase();
    if t.contains("sign language")
        || t.contains("signlanguage")
        || t.contains("signed english")
        || t.contains("deaf")
    {
        return true;
    }
    let h = padded(title);
    has_token(&h, "asl")
        || has_token(&h, "bsl")
        || has_token(&h, "signed")
        || (has_token(&h, "sign") && (has_token(&h, "lang") || has_token(&h, "language")))
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
    push("hi", &["hindi", "hin", "hind"]);
    push("ja", &["japanese", "nihongo", "jpn", "jap"]);
    push("ko", &["korean", "korea", "kor"]);
    push("zh", &["chinese", "mandarin", "cantonese", "chs", "cht", "cn"]);
    push("es", &["spanish", "espanol", "español", "latino", "castellano", "latam", "spa"]);
    push("fr", &["french", "francais", "français", "vff", "vfi", "truefrench", "vfq", "fra"]);
    push("de", &["german", "deutsch", "ger", "deu"]);
    push("it", &["italian", "italiano", "ita"]);
    push("pt", &["portuguese", "brazilian", "ptbr", "brasil", "brazil", "por"]);
    push("ar", &["arabic", "arab"]);
    push("tr", &["turkish", "turkce", "turk"]);
    push("ru", &["russian", "rus"]);
    push("th", &["thai"]);
    push("id", &["indonesian", "bahasa", "indo"]);
    push("nl", &["dutch", "nederlands", "holland"]);
    push("pl", &["polish", "polski", "pol"]);
    push("sv", &["swedish", "svenska"]);
    push("no", &["norwegian", "norsk"]);
    push("da", &["danish", "dansk"]);
    push("fi", &["finnish", "suomi"]);
    push("cs", &["czech", "cesky"]);
    push("hu", &["hungarian", "magyar"]);
    push("ro", &["romanian", "romana"]);
    push("el", &["greek"]);
    push("he", &["hebrew"]);
    push("vi", &["vietnamese"]);
    push("uk", &["ukrainian", "ukr"]);
    push("bn", &["bengali", "bangla"]);
    push("ta", &["tamil"]);
    push("te", &["telugu"]);
    push("ml", &["malayalam"]);
    push("mr", &["marathi"]);
    push("gu", &["gujarati"]);
    push("kn", &["kannada"]);
    push("pa", &["punjabi"]);
    push("en", &["english", "eng"]);
    // Nordic packs often omit a specific language tag.
    if has_token(&h, "nordic") || has_token(&h, "scandinavian") {
        for code in ["sv", "no", "da"] {
            if !out.contains(&code) {
                out.push(code);
            }
        }
    }
    if has_token(&h, "multi") || has_token(&h, "dual") || has_token(&h, "dualaudio") {
        if !out.contains(&"multi") {
            out.push("multi");
        }
    }
    out
}

pub fn languages_for_title(title: &str) -> String {
    language_codes(title).join(",")
}

/// Match preferred languages against tags in the release name.
///
/// Untagged titles are treated as English when `en` is in the preference list —
/// nearly all Western WEB-DL/BluRay names omit "English", and requiring the tag
/// left the app with ~2 hits while Jackett returned hundreds.
/// Explicit foreign tags (Hindi, Spanish, …) still must match the preference.
fn language_matches(found: &[&str], preferred: &str, _kind: &str) -> bool {
    let wanted: Vec<String> = preferred
        .split([',', '/', '|', '+'])
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| !part.is_empty() && part != "all")
        .collect();
    if wanted.is_empty() {
        return true;
    }
    // Multi / dual-audio packs are always allowed with any preference set.
    if found.iter().any(|c| *c == "multi") {
        return true;
    }
    // Explicit language tag must intersect the preference list.
    if found
        .iter()
        .any(|c| *c != "multi" && wanted.iter().any(|w| w == c))
    {
        return true;
    }
    // No language tag in the title → assume English (only when English is wanted).
    let wants_english = wanted.iter().any(|w| w == "en");
    found.is_empty() && wants_english
}

fn stored_language(found: &[&str], _kind: &str) -> String {
    if found.is_empty() {
        return "unknown".into();
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

/// Rank playable torrents: most seeders first (peers are only a weak tiebreak).
pub fn rank_sources(mut out: Vec<StreamSource>, preferred_resolution: &str) -> Vec<StreamSource> {
    let preferred_res = preferred_resolution.trim().to_ascii_lowercase();
    // Prefer real magnets when any exist — but don't throw away the whole list
    // if every magnet has unknown seeders while .torrent links would remain.
    let magnets: Vec<StreamSource> = out
        .iter()
        .filter(|s| s.magnet.to_ascii_lowercase().starts_with("magnet:"))
        .cloned()
        .collect();
    if !magnets.is_empty() {
        out = magnets;
    }

    out.retain(|s| source_quality_score(&s.title) >= 2);

    // Prefer known healthy swarms when available. Public indexers often report
    // Seeders=0 for live torrents — fall back to those rather than showing nothing.
    let with_seeders: Vec<StreamSource> = out
        .iter()
        .filter(|s| s.seeders >= 2 && s.health != "unknown" && s.health != "dead")
        .cloned()
        .collect();
    if !with_seeders.is_empty() {
        out = with_seeders;
    } else {
        let tryable: Vec<StreamSource> = out
            .iter()
            .filter(|s| s.health == "unknown" || s.seeders >= 1)
            .cloned()
            .collect();
        if !tryable.is_empty() {
            out = tryable;
        }
        // else keep all quality-ok rows (including explicit 0) so the picker isn't empty
    }

    out.sort_by(|a, b| {
        let a_magnet = a.magnet.to_ascii_lowercase().starts_with("magnet:") as i32;
        let b_magnet = b.magnet.to_ascii_lowercase().starts_with("magnet:") as i32;
        let a_exact = episode_specificity(&a.title);
        let b_exact = episode_specificity(&b.title);
        let a_known = (a.health != "unknown") as i32;
        let b_known = (b.health != "unknown") as i32;
        b_magnet
            .cmp(&a_magnet)
            .then(b_known.cmp(&a_known))
            // Seeders first — that is what actually starts streams.
            .then(b.seeders.cmp(&a.seeders))
            .then(b_exact.cmp(&a_exact))
            .then(
                resolution_rank(&b.title, &preferred_res)
                    .cmp(&resolution_rank(&a.title, &preferred_res)),
            )
            .then(source_quality_score(&b.title).cmp(&source_quality_score(&a.title)))
            // Peers only break ties between equal-seeder magnets.
            .then(b.peers.cmp(&a.peers))
    });

    // Wider picker: best first, but don't hide solid mid-seed magnets.
    out.into_iter().take(24).collect()
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
        .filter(|s| s.seeders >= 8 && source_quality_score(&s.title) >= 3)
        .collect();
    if proper.len() >= 2 && proper.iter().any(|s| s.seeders >= 20) {
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

/// A torrent found outside Jackett (fallback add-ons such as Torrentio),
/// put through the same CAM / sample / junk / size / language rules as a
/// Jackett hit so the picker can't tell the difference.
#[allow(clippy::too_many_arguments)]
pub(crate) fn external_source(
    title: &str,
    info_hash: &str,
    trackers: &[String],
    seeders: Option<i32>,
    bytes: u64,
    source_label: &str,
    kind: &str,
    preferred_language: &str,
) -> Option<StreamSource> {
    let hash = info_hash.trim().to_ascii_lowercase();
    let hash_ok = (hash.len() == 40 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
        || (hash.len() == 32 && hash.bytes().all(|b| b.is_ascii_alphanumeric()));
    let title = title.trim();
    if !hash_ok || title.is_empty() {
        return None;
    }
    if looks_like_sample(title)
        || looks_like_cam(&padded(title))
        || looks_like_sign_language(title)
        || looks_like_junk_release(title, kind)
    {
        return None;
    }
    if bytes > 0 && !size_plausible(bytes, kind, title) {
        return None;
    }
    let langs = language_codes(title);
    let language = stored_language(&langs, kind);
    let preferred = preferred_language.trim().to_ascii_lowercase();
    if !preferred.is_empty() && preferred != "all" {
        let found: Vec<&str> = language
            .split([',', '/', '|', '+'])
            .map(str::trim)
            .filter(|part| !part.is_empty() && *part != "unknown")
            .collect();
        if !language_matches(&found, &preferred, kind) {
            return None;
        }
    }
    let mut magnet = format!("magnet:?xt=urn:btih:{hash}&dn={}", percent_encode(title));
    for tr in trackers.iter().take(12) {
        magnet.push_str("&tr=");
        magnet.push_str(&percent_encode(tr));
    }
    let seeders_unknown = seeders.is_none();
    let seeders = seeders.unwrap_or(0).max(0);
    let rank_seeders = if seeders_unknown { 1 } else { seeders };
    Some(StreamSource {
        id: hash,
        title: title.to_string(),
        magnet,
        seeders: rank_seeders,
        peers: 0,
        rating: calculate_rating(rank_seeders),
        health: if seeders_unknown {
            "unknown".into()
        } else {
            health_for(seeders).into()
        },
        size: if bytes > 0 { format_size(bytes) } else { "?".into() },
        tracker: source_label.to_string(),
        indexer: source_label.to_string(),
        language,
    })
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
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
    fn kind_categories_are_standard_newznab() {
        assert_eq!(
            super::kind_categories("movie"),
            "2000,2010,2020,2030,2040,2045,2060,2070"
        );
        assert_eq!(
            super::kind_categories("series"),
            "5000,5020,5030,5040,5045,5050,5060,5070,5080"
        );
        assert!(super::kind_categories("anime").contains("5070"));
        assert!(!super::kind_categories("movie").contains("2050"));
        assert!(!super::kind_categories("series").contains("5010"));
        assert!(!super::kind_categories("movie").contains("6000"));
        assert!(!super::kind_categories("series").contains("2000"));
        assert_eq!(super::kind_category_ids("movie").len(), 8);
    }

    #[test]
    fn rejects_xxx_and_cross_kind() {
        assert!(super::is_xxx_category(6000));
        assert!(super::is_xxx_category(6040));
        assert!(!super::is_xxx_category(2000));
        assert!(super::looks_like_junk_release("Show.S01E01.XXX.1080p", "series"));
        assert!(super::looks_like_junk_release("Random.Movie.2024.1080p.BluRay", "series"));
        assert!(!super::looks_like_junk_release("Show.S01E01.1080p.WEB", "series"));
        assert!(super::looks_like_junk_release("Show.S01E01.1080p", "movie"));
    }

    #[test]
    fn category_match_allows_parent_child() {
        let movie = super::kind_category_ids("movie");
        assert!(super::category_matches_allowed(2000, &movie));
        assert!(super::category_matches_allowed(2040, &movie));
        assert!(!super::category_matches_allowed(5000, &movie));
        assert!(!super::category_matches_allowed(6000, &movie));
        let tv = super::kind_category_ids("series");
        assert!(super::category_matches_allowed(5000, &tv));
        assert!(super::category_matches_allowed(5040, &tv));
        assert!(!super::category_matches_allowed(2000, &tv));
    }

    #[test]
    fn indexer_kind_filters_anime_and_movie_only() {
        assert!(!super::indexer_fits_kind("nyaasi", "Nyaa.si", "series"));
        assert!(!super::indexer_fits_kind("bangumimoe", "Bangumi Moe", "movie"));
        assert!(!super::indexer_fits_kind("yts", "YTS", "series"));
        assert!(!super::indexer_fits_kind("eztv", "EZTV", "movie"));
        assert!(super::indexer_fits_kind("eztv", "EZTV", "series"));
        assert!(super::indexer_fits_kind("thepiratebay", "The Pirate Bay", "movie"));
        assert!(super::indexer_fits_kind("nyaasi", "Nyaa.si", "anime"));
    }

    #[test]
    fn episode_pattern_matches_common_names() {
        assert!(super::torrent_matches_episode("Show.Name.S02E05.1080p.WEB", 2, 5));
        assert!(super::torrent_matches_episode("Show Name 2x05 BluRay", 2, 5));
        assert!(!super::torrent_matches_episode("Show.Name.S02E15.1080p", 2, 5));
        assert!(!super::torrent_matches_episode("Show.Name.S12E05.1080p", 2, 5));
        assert!(super::torrent_matches_episode("Show S02 E05 x", 2, 5));
        assert!(!super::torrent_matches_episode("Show.S02E10.mkv", 2, 1));
        assert!(!super::torrent_matches_episode("Show.12x05.mkv", 2, 5));
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
    fn unlabeled_title_assumed_english_when_en_preferred() {
        let found = super::language_codes("Dune.2024.1080p.BluRay.x264");
        assert!(found.is_empty());
        // Preferred includes English → untagged Western WEB-DL/BluRay is kept.
        assert!(super::language_matches(&found, "en,hi", "movie"));
        assert!(super::language_matches(&found, "en", "movie"));
        // Hindi-only still requires an explicit Hindi/multi tag.
        assert!(!super::language_matches(&found, "hi", "movie"));
    }

    #[test]
    fn hindi_tag_matches_hindi_only() {
        let found = super::language_codes("Dune 2024 Hindi 1080p");
        assert!(found.contains(&"hi"));
        assert!(super::language_matches(&found, "hi", "movie"));
        assert!(super::language_matches(&found, "en,hi", "movie"));
        assert!(!super::language_matches(&found, "en", "movie"));
    }

    #[test]
    fn multi_always_matches_when_prefs_set() {
        let found = super::language_codes("Movie 2024 MULTI 1080p");
        assert!(found.contains(&"multi"));
        assert!(super::language_matches(&found, "en", "movie"));
        assert!(super::language_matches(&found, "hi", "movie"));
        assert!(super::language_matches(&found, "en,hi", "movie"));
    }

    #[test]
    fn spanish_does_not_match_english_hindi_prefs() {
        let found = super::language_codes("Movie 2024 Spanish Latino 1080p");
        assert!(found.contains(&"es"));
        assert!(!super::language_matches(&found, "en,hi", "movie"));
    }

    #[test]
    fn english_tag_matches_en_pref() {
        let found = super::language_codes("Movie 2024 English 1080p BluRay");
        assert!(found.contains(&"en"));
        assert!(super::language_matches(&found, "en,hi", "movie"));
    }

    #[test]
    fn unlabeled_title_not_assumed_japanese() {
        let found = super::language_codes("Shogun S01E01 1080p WEB-DL");
        assert!(found.is_empty());
        assert!(!super::language_matches(&found, "ja", "anime"));
        assert!(super::language_matches(&found, "en,hi", "anime"));
        assert!(!super::language_matches(&found, "hi", "anime"));
    }

    #[test]
    fn multi_alone_matches_any_preference() {
        let found = ["multi"];
        assert!(super::language_matches(&found, "en", "movie"));
        assert!(super::language_matches(&found, "hi", "movie"));
        assert!(super::language_matches(&found, "en,multi", "movie"));
    }

    #[test]
    fn rejects_sign_language_releases() {
        assert!(super::looks_like_sign_language(
            "Movie.2020.1080p.Sign.Language.WEB-DL"
        ));
        assert!(super::looks_like_sign_language("Show S01E01 ASL 720p"));
        assert!(super::looks_like_sign_language("Film BSL BluRay"));
        assert!(!super::looks_like_sign_language("Dune.2021.1080p.BluRay.x264"));
    }

    #[test]
    fn language_query_skips_english() {
        assert_eq!(super::language_query_term("en"), None);
        assert_eq!(super::language_query_term("hi"), Some("Hindi"));
        // Year and language names are never baked into the query.
        let movie = super::build_query("Dune", "movie", None, None, Some(2021), "hi");
        assert!(!movie.contains("2021"));
        assert!(!movie.contains("Hindi"));
        assert!(!super::build_query("Dune", "movie", None, None, None, "en").contains("English"));
        let tv = super::build_query(
            "House of the Dragon S03E07",
            "series",
            Some(3),
            Some(7),
            Some(2022),
            "hi",
        );
        assert!(tv.contains("S03E07"));
        assert!(!tv.contains("2022"));
        assert!(!tv.contains("Hindi"));
        assert_eq!(tv.matches("S03E07").count(), 1);
    }
}

// ── Accurate matching: IMDb / season-episode Torznab search + strict titles ──

/// What the user actually asked for. Built from catalog metadata so text
/// results can be checked against the real title and year.
#[derive(Clone, Debug, Default)]
pub struct SearchTarget {
    pub title: String,
    /// Original / client-sent titles that releases may use instead.
    pub alt_titles: Vec<String>,
    pub year: Option<i32>,
    /// `tt…` IMDb id (exact movie search on indexers that support `imdbid`).
    pub imdb_id: Option<String>,
}

impl SearchTarget {
    fn imdb(&self) -> Option<&str> {
        self.imdb_id
            .as_deref()
            .map(str::trim)
            .filter(|s| s.starts_with("tt") && s.len() > 2)
    }

    /// Token lists a release name may start with, and whether that candidate
    /// is only a shortened form (text before ':' / ' - ') which then needs an
    /// exact year in the release to count.
    fn candidates(&self) -> Vec<(Vec<String>, bool)> {
        let mut out: Vec<(Vec<String>, bool)> = Vec::new();
        let mut push = |tokens: Vec<String>, needs_year: bool| {
            if !tokens.is_empty() && !out.iter().any(|(t, _)| *t == tokens) {
                out.push((tokens, needs_year));
            }
        };
        for name in std::iter::once(&self.title).chain(self.alt_titles.iter()) {
            let full = title_tokens(name);
            push(full.clone(), false);
            if full.first().is_some_and(|t| t == "the") {
                push(full[1..].to_vec(), false);
            }
            if let Some(short) = name.split([':', '–']).next().filter(|s| s.len() < name.len()) {
                push(title_tokens(short), true);
            }
        }
        out
    }

    /// Strict check for releases found by *text* search. Rejects other titles
    /// that merely contain the words ("Kleo S02E03 The Bear", "Dune Part Two
    /// 2024" when looking for Dune 2021).
    pub fn matches(&self, release: &str, kind: &str) -> bool {
        let rel = title_tokens(strip_release_prefix(release));
        if rel.is_empty() {
            return false;
        }
        let rel_variants: Vec<&[String]> = if rel[0] == "the" && rel.len() > 1 {
            vec![&rel[..], &rel[1..]]
        } else {
            vec![&rel[..]]
        };
        for (cand, needs_year) in self.candidates() {
            for r in &rel_variants {
                if r.len() >= cand.len() && r[..cand.len()] == cand[..] {
                    if self.rest_ok(&r[cand.len()..], kind, needs_year) {
                        return true;
                    }
                }
            }
        }
        false
    }

    fn year_ok(&self, found: i32, exact: bool) -> bool {
        match self.year {
            Some(want) if exact => found == want,
            Some(want) => (found - want).abs() <= 1,
            None => true,
        }
    }

    fn rest_ok(&self, rest: &[String], kind: &str, needs_year: bool) -> bool {
        if kind == "movie" {
            // The release year, if present, sits before the quality tags.
            for tok in rest {
                if is_release_tag(tok) {
                    break;
                }
                if let Some(y) = year_token(tok) {
                    return self.year_ok(y, needs_year);
                }
            }
            if needs_year {
                return false;
            }
            // No year: only quality tags may follow ("Dune 1080p"), not more
            // title words ("Dune Messiah", "Dune Part Two").
            return rest.first().is_none_or(|t| is_release_tag(t));
        }
        // Series / anime: the show title must be followed by an episode or
        // season marker (or a show year, then the marker).
        let Some(first) = rest.first() else {
            return false;
        };
        if let Some(y) = year_token(first) {
            if !self.year_ok(y, needs_year) {
                return false;
            }
            return rest.get(1).is_none_or(|t| is_episode_marker(t, kind) || is_release_tag(t));
        }
        if needs_year {
            return false;
        }
        is_episode_marker(first, kind) || matches!(first.as_str(), "season" | "complete" | "series")
    }
}

/// Lowercase alphanumeric tokens; `&` → "and", apostrophes dropped so
/// "Marvel's" and "Marvels" match.
fn title_tokens(raw: &str) -> Vec<String> {
    let mut s = String::with_capacity(raw.len());
    for c in raw.chars() {
        match c {
            '\'' | '’' | '`' => {}
            '&' => s.push_str(" and "),
            c if c.is_alphanumeric() => s.extend(c.to_lowercase()),
            _ => s.push(' '),
        }
    }
    s.split_whitespace().map(str::to_owned).collect()
}

/// Drop leading "[Group]" / "(tag)" blocks and "www.site.org - " prefixes.
fn strip_release_prefix(raw: &str) -> &str {
    let mut s = raw.trim();
    loop {
        let before = s;
        for (open, close) in [('[', ']'), ('(', ')'), ('【', '】')] {
            if s.starts_with(open) {
                if let Some(end) = s.find(close) {
                    s = s[end + close.len_utf8()..].trim_start();
                }
            }
        }
        let lower = s.to_ascii_lowercase();
        if lower.starts_with("www.") {
            if let Some(idx) = s.find(" - ") {
                s = s[idx + 3..].trim_start();
            }
        }
        s = s.trim_start_matches(['-', ' ', '.', '_']);
        if s == before {
            return s;
        }
    }
}

fn year_token(tok: &str) -> Option<i32> {
    if tok.len() != 4 {
        return None;
    }
    let y: i32 = tok.parse().ok()?;
    (1900..=2099).contains(&y).then_some(y)
}

fn is_episode_marker(tok: &str, kind: &str) -> bool {
    let b = tok.as_bytes();
    // s02, s02e03, s2e3
    if b.first() == Some(&b's') && b.len() > 1 {
        let rest = &tok[1..];
        let (s, e) = rest.split_once('e').unwrap_or((rest, ""));
        let digits = |x: &str| !x.is_empty() && x.len() <= 3 && x.bytes().all(|c| c.is_ascii_digit());
        return digits(s) && (e.is_empty() || digits(e));
    }
    // 2x03
    if let Some((s, e)) = tok.split_once('x') {
        return !s.is_empty() && !e.is_empty() && s.len() <= 2 && e.len() <= 3
            && s.bytes().all(|c| c.is_ascii_digit()) && e.bytes().all(|c| c.is_ascii_digit());
    }
    // Anime absolute numbering: "Frieren - 05"
    kind == "anime" && tok.len() <= 4 && tok.bytes().all(|c| c.is_ascii_digit())
}

fn is_release_tag(tok: &str) -> bool {
    if tok.len() >= 4 && tok.ends_with('p') && tok[..tok.len() - 1].bytes().all(|c| c.is_ascii_digit()) {
        return true; // 1080p, 2160p
    }
    matches!(
        tok,
        "4k" | "8k" | "uhd" | "hd" | "fhd" | "hdr" | "hdr10" | "dv" | "dovi" | "sdr" | "3d"
            | "web" | "webrip" | "webdl" | "dl" | "bluray" | "blu" | "brrip" | "bdrip" | "bdremux"
            | "remux" | "hdrip" | "dvdrip" | "dvd" | "hdtv" | "hdcam" | "x264" | "x265" | "h264"
            | "h265" | "hevc" | "avc" | "av1" | "10bit" | "8bit" | "aac" | "ac3" | "dts" | "ddp"
            | "dd" | "atmos" | "truehd" | "proper" | "repack" | "extended" | "unrated" | "imax"
            | "remastered" | "multi" | "dual" | "dubbed" | "subbed" | "yts" | "yify" | "rarbg"
            | "internal" | "limited" | "nf" | "amzn" | "dsnp" | "hulu" | "atvp" | "hmax"
    )
}

// ── Torznab plumbing ──

#[derive(Clone, Debug, Default)]
struct IndexerCaps {
    movie_search: bool,
    movie_imdb: bool,
    tv_search: bool,
    tv_season_ep: bool,
}

type CapsMap = std::collections::HashMap<String, IndexerCaps>;

/// Per-Jackett-URL capability map, refreshed every 6h. One `t=indexers`
/// request covers every configured indexer.
fn caps_cache() -> &'static Mutex<Option<(std::time::Instant, String, CapsMap)>> {
    static CACHE: std::sync::OnceLock<Mutex<Option<(std::time::Instant, String, CapsMap)>>> =
        std::sync::OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

fn torznab_regex(pattern: &'static str, slot: &'static std::sync::OnceLock<regex::Regex>) -> &'static regex::Regex {
    slot.get_or_init(|| regex::Regex::new(pattern).expect("static regex"))
}

fn xml_unescape(raw: &str) -> String {
    let s = raw.trim();
    let s = s
        .strip_prefix("<![CDATA[")
        .and_then(|x| x.strip_suffix("]]>"))
        .unwrap_or(s);
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let tail = &rest[i..];
        let Some(end) = tail.find(';').filter(|e| *e <= 10) else {
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        let entity = &tail[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            e if e.starts_with("#x") || e.starts_with("#X") => {
                u32::from_str_radix(&e[2..], 16).ok().and_then(char::from_u32)
            }
            e if e.starts_with('#') => e[1..].parse::<u32>().ok().and_then(char::from_u32),
            _ => None,
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &tail[end + 1..];
            }
            None => {
                out.push('&');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn parse_caps(xml: &str) -> CapsMap {
    static INDEXER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static SEARCH: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let indexer = torznab_regex(r#"(?s)<indexer\s+id="([^"]+)".*?</indexer>"#, &INDEXER);
    let search = torznab_regex(
        r#"<(movie-search|tv-search)\s+available="(\w+)"\s+supportedParams="([^"]*)""#,
        &SEARCH,
    );
    let mut map = CapsMap::new();
    for m in indexer.captures_iter(xml) {
        let mut caps = IndexerCaps::default();
        for s in search.captures_iter(&m[0]) {
            let on = &s[2] == "yes";
            let params: Vec<&str> = s[3].split(',').map(str::trim).collect();
            match &s[1] {
                "movie-search" => {
                    caps.movie_search = on;
                    caps.movie_imdb = on && params.contains(&"imdbid");
                }
                _ => {
                    caps.tv_search = on;
                    caps.tv_season_ep = on && params.contains(&"season") && params.contains(&"ep");
                }
            }
        }
        map.insert(m[1].to_string(), caps);
    }
    map
}

fn parse_torznab_items(xml: &str, id_matched: bool) -> std::result::Result<Vec<JackettHit>, String> {
    static ERROR: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ITEM: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static ATTR: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static CAT: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    static INDEXER: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let error = torznab_regex(r#"<error\s+code="(\d+)"\s+description="([^"]*)""#, &ERROR);
    if let Some(e) = error.captures(xml) {
        return Err(xml_unescape(&e[2]));
    }
    let item = torznab_regex(r"(?s)<item>(.*?)</item>", &ITEM);
    let attr = torznab_regex(r#"<torznab:attr\s+name="([^"]+)"\s+value="([^"]*)""#, &ATTR);
    let cat = torznab_regex(r"<category>(\d+)</category>", &CAT);
    let jidx = torznab_regex(r#"<jackettindexer\s+id="([^"]*)">([^<]*)</jackettindexer>"#, &INDEXER);
    let tag = |body: &str, name: &str| -> Option<String> {
        let open = format!("<{name}>");
        let close = format!("</{name}>");
        let start = body.find(&open)? + open.len();
        let end = body[start..].find(&close)? + start;
        Some(xml_unescape(&body[start..end])).filter(|s| !s.is_empty())
    };
    let mut hits = Vec::new();
    for m in item.captures_iter(xml) {
        let body = &m[1];
        let mut seeders = None;
        let mut peers = None;
        let mut magnet = None;
        let mut infohash = None;
        for a in attr.captures_iter(body) {
            let v = xml_unescape(&a[2]);
            match &a[1] {
                "seeders" => seeders = v.parse().ok(),
                "peers" => peers = v.parse().ok(),
                "magneturl" if v.starts_with("magnet:") => magnet = Some(v),
                "infohash" if !v.is_empty() => infohash = Some(v),
                _ => {}
            }
        }
        let title = tag(body, "title").unwrap_or_default();
        if magnet.is_none() {
            if let Some(h) = infohash {
                magnet = Some(format!("magnet:?xt=urn:btih:{h}"));
            }
        }
        let (indexer_id, indexer_name) = jidx
            .captures(body)
            .map(|c| (Some(c[1].to_string()), Some(xml_unescape(&c[2]))))
            .unwrap_or((None, None));
        hits.push(JackettHit {
            title,
            magnet_uri: magnet,
            link: tag(body, "link"),
            seeders,
            peers,
            size: tag(body, "size").and_then(|s| s.parse().ok()),
            tracker: indexer_name.clone(),
            tracker_id: indexer_id,
            indexer: indexer_name,
            guid: tag(body, "guid"),
            category: cat.captures_iter(body).filter_map(|c| c[1].parse().ok()).collect(),
            category_desc: None,
            id_matched,
        });
    }
    Ok(hits)
}

impl JackettClient {
    async fn indexer_caps(&self) -> CapsMap {
        {
            let guard = caps_cache().lock().unwrap_or_else(|e| e.into_inner());
            if let Some((at, base, map)) = guard.as_ref() {
                if *base == self.base_url && at.elapsed() < Duration::from_secs(6 * 3600) {
                    return map.clone();
                }
            }
        }
        let url = format!(
            "{}/api/v2.0/indexers/all/results/torznab/api",
            self.base_url
        );
        let fetched = tokio::time::timeout(
            Duration::from_secs(8),
            self.http
                .get(&url)
                .query(&[
                    ("apikey", self.api_key.as_str()),
                    ("t", "indexers"),
                    ("configured", "true"),
                ])
                .send(),
        )
        .await;
        let map = match fetched {
            Ok(Ok(res)) if res.status().is_success() => {
                parse_caps(&res.text().await.unwrap_or_default())
            }
            _ => CapsMap::new(),
        };
        if !map.is_empty() {
            *caps_cache().lock().unwrap_or_else(|e| e.into_inner()) =
                Some((std::time::Instant::now(), self.base_url.clone(), map.clone()));
        }
        map
    }

    async fn load_indexers_torznab(&self) -> Vec<IndexerInfo> {
        static ROW: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
        let row = torznab_regex(
            r#"(?s)<indexer\s+id="([^"]+)"[^>]*>\s*<title>([^<]*)</title>"#,
            &ROW,
        );
        let url = format!("{}/api/v2.0/indexers/all/results/torznab/api", self.base_url);
        let Ok(Ok(res)) = tokio::time::timeout(
            Duration::from_secs(8),
            self.http
                .get(&url)
                .query(&[
                    ("apikey", self.api_key.as_str()),
                    ("t", "indexers"),
                    ("configured", "true"),
                ])
                .send(),
        )
        .await
        else {
            return Vec::new();
        };
        if !res.status().is_success() {
            return Vec::new();
        }
        let xml = res.text().await.unwrap_or_default();
        let parsed: Vec<IndexerInfo> = row
            .captures_iter(&xml)
            .filter(|c| &c[1] != "all")
            .map(|c| IndexerInfo {
                id: c[1].to_string(),
                name: xml_unescape(&c[2]),
                last_error: String::new(),
            })
            .collect();
        if !parsed.is_empty() {
            *self.indexer_cache.lock().unwrap_or_else(|e| e.into_inner()) = Some(parsed.clone());
        }
        parsed
    }

    async fn fetch_torznab(
        &self,
        id: &str,
        params: &[(&str, String)],
        id_matched: bool,
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let url = format!("{}/api/v2.0/indexers/{id}/results/torznab/api", self.base_url);
        let res = self
            .http
            .get(&url)
            .query(&[("apikey", self.api_key.as_str())])
            .query(params)
            .send()
            .await
            .map_err(|e| self.redact_text(&e.to_string()))?;
        let status = res.status();
        let body = res.text().await.unwrap_or_default();
        if status.as_u16() == 429 {
            return Err("rate_limited".to_string());
        }
        if !status.is_success() {
            return Err(self.redact_text(&body));
        }
        parse_torznab_items(&body, id_matched).map_err(|e| self.redact_text(&e))
    }

    /// One indexer: exact IMDb search when it supports it (movies), else a
    /// Torznab text / season+episode search. Unknown caps → plain `t=search`.
    async fn search_torznab_one(
        &self,
        id: &str,
        caps: Option<&IndexerCaps>,
        target: &SearchTarget,
        kind: &str,
        season: Option<i32>,
        episode: Option<i32>,
    ) -> std::result::Result<Vec<JackettHit>, String> {
        let cats = kind_categories(kind).to_string();
        let title = build_query(&target.title, kind, None, None, None, "");
        if kind == "movie" {
            if let (Some(imdb), Some(c)) = (target.imdb(), caps) {
                if c.movie_imdb {
                    let hits = self
                        .fetch_torznab(
                            id,
                            &[("t", "movie".into()), ("imdbid", imdb.into()), ("cat", cats.clone())],
                            true,
                        )
                        .await?;
                    if !hits.is_empty() {
                        return Ok(hits);
                    }
                }
            }
            let t = if caps.is_some_and(|c| c.movie_search) { "movie" } else { "search" };
            return self
                .fetch_torznab(id, &[("t", t.into()), ("q", title), ("cat", cats)], false)
                .await;
        }
        match (season, episode) {
            (Some(s), Some(e)) if caps.is_some_and(|c| c.tv_season_ep) => {
                self.fetch_torznab(
                    id,
                    &[
                        ("t", "tvsearch".into()),
                        ("q", title),
                        ("season", s.to_string()),
                        ("ep", e.to_string()),
                        ("cat", cats),
                    ],
                    false,
                )
                .await
            }
            (Some(s), Some(e)) => {
                self.fetch_torznab(
                    id,
                    &[("t", "search".into()), ("q", format!("{title} S{s:02}E{e:02}")), ("cat", cats)],
                    false,
                )
                .await
            }
            _ => {
                let t = if caps.is_some_and(|c| c.tv_search) { "tvsearch" } else { "search" };
                self.fetch_torznab(id, &[("t", t.into()), ("q", title), ("cat", cats)], false)
                    .await
            }
        }
    }
}

#[cfg(test)]
mod match_tests {
    use super::*;

    fn dune() -> SearchTarget {
        SearchTarget {
            title: "Dune".into(),
            year: Some(2021),
            imdb_id: Some("tt1160419".into()),
            ..Default::default()
        }
    }

    fn bear() -> SearchTarget {
        SearchTarget {
            title: "The Bear".into(),
            year: Some(2022),
            ..Default::default()
        }
    }

    #[test]
    fn movie_year_and_title() {
        let t = dune();
        assert!(t.matches("Dune Part One (2021) 1080p BRRip 5.1 x264 -YTS", "movie"));
        assert!(t.matches("Dune.2021.2160p.AI Enhanced.WEBRip.60FPS.H265", "movie"));
        assert!(t.matches("Dune 1080p WEB-DL", "movie"));
        assert!(!t.matches("Dune Part Two (2024) 1080p BRRip 5.1 x264 -YT", "movie"));
        assert!(!t.matches("Dune - Part Two 2024 1080p BluRay DoVi HDR10", "movie"));
        assert!(!t.matches("Dune 1984 1080p BluRay", "movie"));
        assert!(!t.matches("Dune Messiah 1080p", "movie"));
        assert!(!t.matches("À l'école de l'universel Germaine Le Goff", "movie"));
    }

    #[test]
    fn series_title_must_lead() {
        let t = bear();
        assert!(t.matches("The Bear S02E03 Sundae 2160p DSNP WEB-DL DDP5 1 H", "series"));
        assert!(t.matches("The.Bear.S02E03.Sundae.1080p.DSNP.WEB-DL.DDP5.1.H", "series"));
        assert!(t.matches("The Bear S02e01-10 [1080p Ita Eng Spa 5.1 HEVC10]", "series"));
        assert!(t.matches("www.UIndex.org    -    The Bear S02E03 720p WEB h264-EDITH", "series"));
        assert!(t.matches("The Bear 2022 S02E03 1080p", "series"));
        assert!(!t.matches("Kleo S02E03 The Bear 1080p NF WEB-DL DD 5 1 Atmos", "series"));
        assert!(!t.matches("Running Wild with Bear Grylls The Challenge S02E03", "series"));
        assert!(!t.matches("The Yogi Bear Show S02E03 Gleesome Threesome 1080p", "series"));
        assert!(!t.matches("The Island with Bear Grylls S02E03 The Mens Island", "series"));
        assert!(!t.matches("Ronja the Robbers Daughter 2024 S02E03 Bear Cavern", "series"));
        assert!(!t.matches("The Bear 1988 S02E03", "series"));
    }

    #[test]
    fn subtitles_and_alt_titles() {
        let t = SearchTarget {
            title: "Mission: Impossible – Dead Reckoning Part One".into(),
            year: Some(2023),
            ..Default::default()
        };
        assert!(t.matches("Mission Impossible Dead Reckoning Part One 2023 1080p", "movie"));
        assert!(t.matches("Mission.Impossible.2023.1080p.WEB", "movie"));
        assert!(!t.matches("Mission Impossible 1996 1080p", "movie"));
        let a = SearchTarget {
            title: "Frieren: Beyond Journey's End".into(),
            alt_titles: vec!["Sousou no Frieren".into()],
            ..Default::default()
        };
        assert!(a.matches("[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234].mkv", "anime"));
        assert!(!a.matches("[SubsPlease] Dandadan - 05 (1080p)", "anime"));
    }

    #[test]
    fn parses_torznab_items_and_caps() {
        let xml = r#"<rss><channel>
          <item><title>Dune Part One 2021 720p BluRay &amp; x264</title>
          <guid>https://x/1</guid><jackettindexer id="yts">YTS</jackettindexer>
          <size>1717986918</size><link>http://j/dl/yts/?a=1&amp;b=2</link>
          <category>2000</category><category>100467</category>
          <torznab:attr name="seeders" value="55" /><torznab:attr name="peers" value="72" />
          <torznab:attr name="infohash" value="C325154DAA922E60334A169DF70354ED07AA17E3" />
          </item></channel></rss>"#;
        let hits = parse_torznab_items(xml, true).unwrap();
        assert_eq!(hits.len(), 1);
        let h = &hits[0];
        assert_eq!(h.title, "Dune Part One 2021 720p BluRay & x264");
        assert_eq!(h.seeders, Some(55));
        assert_eq!(h.size, Some(1717986918));
        assert_eq!(h.category, vec![2000, 100467]);
        assert_eq!(h.link.as_deref(), Some("http://j/dl/yts/?a=1&b=2"));
        assert!(h.magnet_uri.as_deref().unwrap().contains("C325154DAA922E60334A169DF70354ED07AA17E3"));
        assert!(h.id_matched);
        assert_eq!(
            parse_torznab_items(r#"<error code="100" description="Invalid API Key" />"#, false).unwrap_err(),
            "Invalid API Key"
        );

        let caps = parse_caps(r#"<indexers>
          <indexer id="yts" configured="true"><caps><searching>
          <tv-search available="no" supportedParams="q" />
          <movie-search available="yes" supportedParams="q,imdbid" /></searching></caps></indexer>
          <indexer id="eztv" configured="true"><caps><searching>
          <tv-search available="yes" supportedParams="q,season,ep" />
          <movie-search available="no" supportedParams="q" /></searching></caps></indexer>
          </indexers>"#);
        assert!(caps["yts"].movie_imdb && !caps["yts"].tv_search);
        assert!(caps["eztv"].tv_season_ep && !caps["eztv"].movie_search);
    }
}

/// Live check against a real Jackett. Skipped unless run with
/// `LIVE_JACKETT_URL=… LIVE_JACKETT_KEY=… cargo test -- --ignored live_jackett --nocapture`.
#[cfg(test)]
mod live_tests {
    use super::*;

    fn client() -> Option<JackettClient> {
        let url = std::env::var("LIVE_JACKETT_URL").ok()?;
        let key = std::env::var("LIVE_JACKETT_KEY").ok()?;
        Some(JackettClient::new(reqwest::Client::new(), url, key))
    }

    async fn run(label: &str, target: SearchTarget, kind: &str, s: Option<i32>, e: Option<i32>) {
        let Some(c) = client() else { return };
        let started = std::time::Instant::now();
        let found = c.search(&target, kind, s, e, "1080p", "").await.expect("search");
        println!("\n== {label}: {} results in {:.1}s", found.len(), started.elapsed().as_secs_f32());
        for src in found.iter().take(12) {
            println!("  [{:>4}] {} — {}", src.seeders, src.title, src.indexer);
        }
        assert!(!found.is_empty(), "{label}: no results");
    }

    #[tokio::test]
    #[ignore]
    async fn live_jackett() {
        run("Dune (2021) by IMDb", SearchTarget {
            title: "Dune".into(), year: Some(2021), imdb_id: Some("tt1160419".into()), ..Default::default()
        }, "movie", None, None).await;
        run("Dune (2021) no IMDb (text + strict)", SearchTarget {
            title: "Dune".into(), year: Some(2021), ..Default::default()
        }, "movie", None, None).await;
        run("The Bear S02E03", SearchTarget {
            title: "The Bear".into(), year: Some(2022), imdb_id: Some("tt14452776".into()), ..Default::default()
        }, "series", Some(2), Some(3)).await;
    }
}
