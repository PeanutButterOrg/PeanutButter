//! TheIntroDB client — intro / recap / credits / preview timestamps by TMDB ID.
//! https://api.theintrodb.org/v3

use std::time::Duration;

use moka::future::Cache;
use reqwest::Client;
use serde::Deserialize;
use tracing::debug;

use crate::error::{AppError, Result};

const BASE: &str = "https://api.theintrodb.org/v3";

#[derive(Clone)]
pub struct IntroDb {
    http: Client,
    cache: Cache<String, Option<MediaTimestamps>>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct MediaTimestamps {
    pub tmdb_id: Option<i32>,
    #[serde(default)]
    pub r#type: Option<String>,
    #[serde(default)]
    pub season: Option<i32>,
    #[serde(default)]
    pub episode: Option<i32>,
    #[serde(default)]
    pub intro: Vec<RawSpan>,
    #[serde(default)]
    pub recap: Vec<RawSpan>,
    #[serde(default)]
    pub credits: Vec<RawSpan>,
    #[serde(default)]
    pub preview: Vec<RawSpan>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RawSpan {
    /// `null` = starts at media beginning (intro/recap).
    pub start_ms: Option<i64>,
    /// `null` = runs to media end (credits/preview).
    pub end_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentKind {
    Intro,
    Recap,
    Credits,
    Preview,
}

impl SegmentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Intro => "INTRO",
            Self::Recap => "RECAP",
            Self::Credits => "CREDITS",
            Self::Preview => "PREVIEW",
        }
    }

    pub fn skip_label(self) -> &'static str {
        match self {
            Self::Intro => "Skip Intro",
            Self::Recap => "Skip Recap",
            Self::Credits => "Skip Credits",
            Self::Preview => "Skip Preview",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NormalizedSegment {
    pub kind: SegmentKind,
    pub start_ms: i64,
    pub end_ms: Option<i64>,
}

impl IntroDb {
    pub fn new(http: Client) -> Self {
        Self {
            http,
            cache: Cache::builder()
                .max_capacity(512)
                .time_to_live(Duration::from_secs(6 * 60 * 60))
                .build(),
        }
    }

    /// Fetch segments. Prefer `tmdb_id`; fall back to `imdb_id`.
    /// Pass `duration_ms` when known so TheIntroDB can pick the closest cut.
    pub async fn media(
        &self,
        tmdb_id: Option<i32>,
        imdb_id: Option<&str>,
        season: Option<i32>,
        episode: Option<i32>,
        duration_ms: Option<i64>,
    ) -> Result<Option<MediaTimestamps>> {
        if tmdb_id.is_none() && imdb_id.map(str::trim).filter(|s| !s.is_empty()).is_none() {
            return Ok(None);
        }
        let duration_bucket = duration_ms.map(|d| (d / 5000) * 5000);
        let key = format!(
            "{}|{}|{}|{}|{}",
            tmdb_id.map(|v| v.to_string()).unwrap_or_default(),
            imdb_id.unwrap_or(""),
            season.unwrap_or(0),
            episode.unwrap_or(0),
            duration_bucket.unwrap_or(-1),
        );
        if let Some(hit) = self.cache.get(&key).await {
            return Ok(hit);
        }

        let mut req = self.http.get(format!("{BASE}/media"));
        if let Some(id) = tmdb_id {
            req = req.query(&[("tmdb_id", id.to_string())]);
        } else if let Some(imdb) = imdb_id.map(str::trim).filter(|s| !s.is_empty()) {
            req = req.query(&[("imdb_id", imdb.to_string())]);
        }
        if let (Some(s), Some(e)) = (season, episode) {
            req = req.query(&[("season", s.to_string()), ("episode", e.to_string())]);
        }
        if let Some(d) = duration_ms.filter(|d| *d > 0) {
            req = req.query(&[("duration_ms", d.to_string())]);
        }

        let res = req.send().await.map_err(|e| AppError::Message(e.to_string()))?;
        let status = res.status();
        if status.as_u16() == 404 {
            self.cache.insert(key, None).await;
            return Ok(None);
        }
        if status.as_u16() == 429 {
            return Err(AppError::Message(
                "TheIntroDB rate limit reached — try again shortly".into(),
            ));
        }
        if !status.is_success() {
            let body = res.text().await.unwrap_or_default();
            return Err(AppError::Message(format!(
                "TheIntroDB error {status}: {}",
                body.chars().take(160).collect::<String>()
            )));
        }
        let parsed: MediaTimestamps = res
            .json()
            .await
            .map_err(|e| AppError::Message(format!("TheIntroDB decode: {e}")))?;
        debug!(
            tmdb = ?parsed.tmdb_id,
            intro = parsed.intro.len(),
            recap = parsed.recap.len(),
            credits = parsed.credits.len(),
            preview = parsed.preview.len(),
            "TheIntroDB segments"
        );
        let out = Some(parsed);
        self.cache.insert(key, out.clone()).await;
        Ok(out)
    }
}

impl MediaTimestamps {
    /// Flatten + normalize spans for the player.
    pub fn normalized(&self) -> Vec<NormalizedSegment> {
        let mut out = Vec::new();
        push_kind(&mut out, SegmentKind::Intro, &self.intro);
        push_kind(&mut out, SegmentKind::Recap, &self.recap);
        push_kind(&mut out, SegmentKind::Preview, &self.preview);
        push_kind(&mut out, SegmentKind::Credits, &self.credits);
        out
    }
}

fn push_kind(out: &mut Vec<NormalizedSegment>, kind: SegmentKind, spans: &[RawSpan]) {
    for span in spans {
        let start = span.start_ms.unwrap_or(0).max(0);
        let end = span.end_ms.filter(|e| *e >= 0);
        // Drop empty / inverted spans (except open-ended credits/preview).
        if let Some(end) = end {
            if end <= start {
                continue;
            }
        }
        out.push(NormalizedSegment {
            kind,
            start_ms: start,
            end_ms: end,
        });
    }
}
