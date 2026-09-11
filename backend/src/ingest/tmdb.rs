use std::sync::OnceLock;
use std::time::{Duration, Instant};

use chrono::Datelike;
use futures::stream::{self, StreamExt};
use serde::Deserialize;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};
use uuid::Uuid;

use super::IngestContext;
use crate::db;
use crate::db::models::TitleRow;
use crate::error::{AppError, Result};

const TMDB: &str = "https://api.themoviedb.org/3";
/// Hard cap: 30 TMDB HTTP calls per second (list + detail + search).
const TMDB_PER_SEC: f64 = 30.0;
/// How many detail upserts may run at once (still paced by the token bucket).
const TMDB_CONCURRENCY: usize = 12;
/// Max TMDB list pages fetched during a full/cron sync (trending / popular / fresh).
const TMDB_LIST_INITIAL_PAGES: i32 = 5;
/// Hard ceiling for on-demand scroll fetches (and TMDB's own total_pages clamp).
const TMDB_LIST_MAX_PAGES: i32 = 30;
/// TMDB list endpoints return 20 results per page.
const TMDB_LIST_PAGE_SIZE: i32 = 20;
/// TMDB search returns up to 20 hits per page.
const TMDB_SEARCH_PAGE_SIZE: usize = 20;

pub fn sync_concurrency() -> usize {
    TMDB_CONCURRENCY
}

fn preferred_codes(ctx: &IngestContext) -> Vec<String> {
    ctx.config.live.preferred_language_codes()
}

fn tmdb_locale(ctx: &IngestContext) -> String {
    crate::config::tmdb_ui_locale(&preferred_codes(ctx))
}

fn image_language_param(ctx: &IngestContext) -> String {
    let mut parts = preferred_codes(ctx);
    if parts.is_empty() {
        return "en,null".into();
    }
    if !parts.iter().any(|c| c == "en") {
        parts.push("en".into());
    }
    parts.push("null".into());
    parts.join(",")
}

fn original_language_query(ctx: &IngestContext) -> String {
    let codes = preferred_codes(ctx);
    if codes.is_empty() {
        return String::new();
    }
    format!("&with_original_language={}", codes.join("|"))
}

fn accepts_original_language(ctx: &IngestContext, code: Option<&str>) -> bool {
    let wanted = preferred_codes(ctx);
    if wanted.is_empty() {
        return true;
    }
    let Some(code) = code.map(str::trim).filter(|s| !s.is_empty()) else {
        // Unknown language — skip when the server has a language lock.
        return false;
    };
    wanted.iter().any(|w| w.eq_ignore_ascii_case(code))
}

fn language_match_score(wanted: &[String], code: Option<&str>) -> i32 {
    let lang = code.unwrap_or("").trim();
    if wanted.is_empty() {
        return if lang.eq_ignore_ascii_case("en") {
            3
        } else if lang.is_empty() {
            2
        } else {
            1
        };
    }
    if wanted.iter().any(|w| w.eq_ignore_ascii_case(lang)) {
        4
    } else if lang.is_empty() {
        1
    } else {
        0
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct ShelfTags {
    trending: bool,
    popular: bool,
    fresh: bool,
}

impl ShelfTags {
    fn merge(&mut self, other: Self) {
        self.trending |= other.trending;
        self.popular |= other.popular;
        self.fresh |= other.fresh;
    }

    fn from_path(path: &str) -> Self {
        let p = path.to_ascii_lowercase();
        let trending = p.contains("/trending/");
        let popular = p.contains("/popular")
            || p.contains("sort_by=popularity")
            || p.contains("sort_by=vote_average")
            || p.contains("sort_by=revenue");
        let fresh = p.contains("now_playing")
            || p.contains("upcoming")
            || p.contains("on_the_air")
            || p.contains("airing_today")
            || p.contains("primary_release_date")
            || p.contains("first_air_date");
        Self {
            trending,
            popular,
            fresh,
        }
    }

    fn shelf_name(self) -> Option<&'static str> {
        if self.trending {
            Some("trending")
        } else if self.popular {
            Some("popular")
        } else if self.fresh {
            Some("fresh")
        } else {
            None
        }
    }
}

/// Canonical TMDB list used for on-demand pagination (one path per shelf × media).
fn canonical_shelf_path(shelf: &str, media: &str) -> Option<&'static str> {
    match (shelf, media) {
        ("trending", "movie") => Some("/trending/movie/day"),
        ("trending", "tv") => Some("/trending/tv/day"),
        ("popular", "movie") => Some("/movie/popular"),
        ("popular", "tv") => Some("/tv/popular"),
        ("fresh", "movie") => Some("/movie/now_playing"),
        ("fresh", "tv") => Some("/tv/on_the_air"),
        _ => None,
    }
}

fn is_canonical_shelf_path(path: &str) -> bool {
    matches!(
        path,
        "/trending/movie/day"
            | "/trending/tv/day"
            | "/movie/popular"
            | "/tv/popular"
            | "/movie/now_playing"
            | "/tv/on_the_air"
    )
}

fn current_month_start() -> String {
    let now = chrono::Utc::now().date_naive();
    format!("{:04}-{:02}-01", now.year(), now.month())
}

struct TmdbBucket {
    tokens: f64,
    last: Instant,
}

fn tmdb_bucket() -> &'static Mutex<TmdbBucket> {
    static GATE: OnceLock<Mutex<TmdbBucket>> = OnceLock::new();
    GATE.get_or_init(|| {
        Mutex::new(TmdbBucket {
            tokens: TMDB_PER_SEC,
            last: Instant::now(),
        })
    })
}

/// Token-bucket limiter: up to ~30 starts/sec, many requests may be in flight together.
async fn wait_tmdb_slot() {
    loop {
        let wait = {
            let mut b = tmdb_bucket().lock().await;
            let now = Instant::now();
            let elapsed = now.saturating_duration_since(b.last).as_secs_f64();
            b.tokens = (b.tokens + elapsed * TMDB_PER_SEC).min(TMDB_PER_SEC);
            b.last = now;
            if b.tokens >= 1.0 {
                b.tokens -= 1.0;
                return;
            }
            Duration::from_secs_f64(((1.0 - b.tokens) / TMDB_PER_SEC).max(0.001))
        };
        tokio::time::sleep(wait).await;
    }
}

#[derive(Debug, Deserialize)]
struct Page<T> {
    results: Vec<T>,
    #[serde(default)]
    total_pages: Option<i32>,
    #[serde(default)]
    #[allow(dead_code)]
    page: Option<i32>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct MovieListItem {
    id: i32,
    title: Option<String>,
    #[serde(default)]
    adult: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct TvListItem {
    id: i32,
    name: Option<String>,
    #[serde(default)]
    adult: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct Genre {
    name: String,
}

#[derive(Debug, Deserialize)]
struct VideoResults {
    results: Vec<Video>,
}

#[derive(Debug, Deserialize)]
struct Video {
    name: String,
    key: String,
    site: String,
    size: Option<i32>,
    #[serde(default)]
    iso_639_1: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MovieDetails {
    id: i32,
    title: String,
    original_title: Option<String>,
    #[serde(default)]
    original_language: Option<String>,
    #[serde(default)]
    adult: Option<bool>,
    overview: Option<String>,
    release_date: Option<String>,
    runtime: Option<i32>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    imdb_id: Option<String>,
    vote_average: Option<f64>,
    vote_count: Option<i32>,
    #[serde(default)]
    popularity: Option<f64>,
    genres: Option<Vec<Genre>>,
    videos: Option<VideoResults>,
    images: Option<TmdbImages>,
    credits: Option<TmdbCredits>,
    release_dates: Option<ReleaseDateResults>,
}

#[derive(Debug, Deserialize)]
struct TvDetails {
    id: i32,
    name: String,
    original_name: Option<String>,
    #[serde(default)]
    original_language: Option<String>,
    #[serde(default)]
    adult: Option<bool>,
    overview: Option<String>,
    first_air_date: Option<String>,
    episode_run_time: Option<Vec<i32>>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    vote_average: Option<f64>,
    vote_count: Option<i32>,
    #[serde(default)]
    popularity: Option<f64>,
    genres: Option<Vec<Genre>>,
    videos: Option<VideoResults>,
    seasons: Option<Vec<TmdbSeason>>,
    #[serde(default)]
    #[allow(dead_code)]
    number_of_seasons: Option<i32>,
    images: Option<TmdbImages>,
    credits: Option<TmdbCredits>,
    #[serde(default)]
    aggregate_credits: Option<TmdbCredits>,
    content_ratings: Option<TvRatingResults>,
    #[serde(default)]
    external_ids: Option<ExternalIds>,
}

#[derive(Debug, Deserialize)]
struct TmdbSeason {
    season_number: i32,
    name: Option<String>,
    overview: Option<String>,
    poster_path: Option<String>,
    air_date: Option<String>,
    episode_count: Option<i32>,
    id: Option<i32>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct SeasonDetails {
    season_number: i32,
    episodes: Option<Vec<TmdbEpisode>>,
}

#[derive(Debug, Deserialize)]
struct TmdbEpisode {
    episode_number: i32,
    name: Option<String>,
    overview: Option<String>,
    still_path: Option<String>,
    air_date: Option<String>,
    runtime: Option<i32>,
    id: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct ExternalIds {
    imdb_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TmdbImages {
    logos: Option<Vec<TmdbImage>>,
    backdrops: Option<Vec<TmdbImage>>,
}

#[derive(Debug, Deserialize)]
struct TmdbImage {
    file_path: String,
    iso_639_1: Option<String>,
    vote_average: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct TmdbCredits {
    cast: Option<Vec<TmdbCast>>,
    crew: Option<Vec<TmdbCrew>>,
}

#[derive(Debug, Deserialize)]
struct ReleaseDateResults {
    results: Option<Vec<ReleaseDateCountry>>,
}

#[derive(Debug, Deserialize)]
struct ReleaseDateCountry {
    iso_3166_1: Option<String>,
    release_dates: Option<Vec<ReleaseDate>>,
}

#[derive(Debug, Deserialize)]
struct ReleaseDate {
    certification: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TvRatingResults {
    results: Option<Vec<TvRating>>,
}

#[derive(Debug, Deserialize)]
struct TvRating {
    iso_3166_1: Option<String>,
    rating: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TmdbCast {
    name: Option<String>,
    character: Option<String>,
    #[serde(default)]
    roles: Option<Vec<TmdbRole>>,
    profile_path: Option<String>,
    order: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct TmdbRole {
    character: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TmdbCrew {
    name: Option<String>,
    job: Option<String>,
    #[serde(default)]
    jobs: Option<Vec<TmdbJob>>,
    profile_path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TmdbJob {
    job: Option<String>,
}

pub async fn sync_catalog(ctx: &IngestContext) -> Result<()> {
    if ctx.config.tmdb_key().is_empty() {
        return Err(AppError::Config(
            "TMDB API key required — add it in console Settings".into(),
        ));
    }
    let _ = db::set_sync_progress(&ctx.pool, "TMDB · Movies", 5, 100).await;
    fetch_movies(ctx).await?;
    let _ = db::set_sync_progress(&ctx.pool, "TMDB · Series", 55, 100).await;
    fetch_tv(ctx).await?;
    let _ = db::set_sync_progress(&ctx.pool, "TMDB · Refresh", 88, 100).await;
    refresh_stale_titles(ctx).await?;
    Ok(())
}

/// Search TMDB and upsert matching titles into the local catalog (on-demand).
/// Pulls a full results page and ingests hits in parallel (≤30 req/s).
pub async fn search_and_ingest(
    ctx: &IngestContext,
    query: &str,
    kind: Option<&str>,
    page: usize,
    limit: usize,
) -> Result<Vec<Uuid>> {
    if ctx.config.tmdb_key().is_empty() || query.trim().is_empty() {
        return Ok(vec![]);
    }
    let page = page.max(1);
    let limit = limit.clamp(1, TMDB_SEARCH_PAGE_SIZE);
    let q = urlencoding_encode(query.trim());

    let mut jobs: Vec<(i32, String)> = Vec::new();
    match kind {
        Some("series") | Some("anime") => {
            jobs.extend(
                search_list_ids(ctx, "tv", &q, page)
                    .await?
                    .into_iter()
                    .map(|id| (id, "series".to_string())),
            );
        }
        Some("movie") => {
            jobs.extend(
                search_list_ids(ctx, "movie", &q, page)
                    .await?
                    .into_iter()
                    .map(|id| (id, "movie".to_string())),
            );
        }
        _ => {
            let (movies, series) = tokio::join!(
                search_list_ids(ctx, "movie", &q, page),
                search_list_ids(ctx, "tv", &q, page),
            );
            jobs.extend(movies?.into_iter().map(|id| (id, "movie".to_string())));
            jobs.extend(series?.into_iter().map(|id| (id, "series".to_string())));
        }
    }

    let jobs: Vec<_> = jobs.into_iter().take(limit).collect();
    let out: Vec<Uuid> = stream::iter(jobs)
        .map(|(tmdb_id, media)| {
            let ctx = ctx.clone();
            async move {
                match fetch_details(&ctx, tmdb_id, &media).await {
                    Ok(uuid) => Some(uuid),
                    Err(e) => {
                        warn!(tmdb_id, media = %media, error = %e, "TMDB search ingest failed");
                        None
                    }
                }
            }
        })
        .buffer_unordered(TMDB_CONCURRENCY.min(8))
        .filter_map(|id| async move { id })
        .collect()
        .await;
    Ok(out)
}

/// Fill missing seasons / trailers / art for a catalog title from TMDB.
/// Resolves legacy rows that have no `tmdb_id` via title search.
pub async fn ensure_title_enriched(ctx: &IngestContext, title_id: Uuid) -> Result<bool> {
    if ctx.config.tmdb_key().is_empty() {
        return Ok(false);
    }

    let row: Option<(Option<i32>, String, String, Option<i32>)> = sqlx::query_as(
        "SELECT tmdb_id, kind, title, year FROM titles WHERE id = $1",
    )
    .bind(title_id)
    .fetch_optional(&ctx.pool)
    .await?;
    let Some((tmdb_id, kind, title, year)) = row else {
        return Ok(false);
    };

    let (season_count,): (i64,) =
        sqlx::query_as("SELECT COUNT(*)::bigint FROM seasons WHERE title_id = $1")
            .bind(title_id)
            .fetch_one(&ctx.pool)
            .await?;
    let (has_backdrop,): (bool,) = sqlx::query_as(
        "SELECT backdrop_path IS NOT NULL AND length(backdrop_path) > 0 FROM titles WHERE id = $1",
    )
    .bind(title_id)
    .fetch_one(&ctx.pool)
    .await?;

    let is_series = kind == "series" || kind == "anime";
    let needs_seasons = is_series && season_count == 0;
    let needs_link = tmdb_id.is_none();
    let needs_backdrop = !has_backdrop;
    if !needs_seasons && !needs_link && !needs_backdrop {
        return Ok(false);
    }

    if let Some(tmdb_id) = tmdb_id {
        let media = if kind == "movie" { "movie" } else { "series" };
        fetch_details(ctx, tmdb_id, media).await?;
        return Ok(true);
    }

    let media = if kind == "movie" { "movie" } else { "tv" };
    let q = urlencoding_encode(&title);
    let mut candidates = search_list_ids_year(ctx, media, &q, 1, year).await?;
    if candidates.is_empty() && year.is_some() {
        candidates = search_list_ids(ctx, media, &q, 1).await?;
    }
    let Some(chosen) = candidates.into_iter().next() else {
        return Ok(false);
    };

    let upsert_kind = if kind == "movie" { "movie" } else { "series" };
    fetch_details(ctx, chosen, upsert_kind).await?;
    Ok(true)
}

fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

async fn search_list_ids(
    ctx: &IngestContext,
    media: &str,
    q: &str,
    page: usize,
) -> Result<Vec<i32>> {
    search_list_ids_year(ctx, media, q, page, None).await
}

async fn search_list_ids_year(
    ctx: &IngestContext,
    media: &str,
    q: &str,
    page: usize,
    year: Option<i32>,
) -> Result<Vec<i32>> {
    let mut url = format!(
        "{TMDB}/search/{media}?api_key={}&language={}&query={q}&page={page}&include_adult=false",
        ctx.config.tmdb_key(),
        tmdb_locale(ctx)
    );
    if let Some(year) = year {
        if media == "tv" {
            url.push_str(&format!("&first_air_date_year={year}"));
        } else {
            url.push_str(&format!("&primary_release_year={year}"));
        }
    }
    #[derive(Deserialize)]
    struct Hit {
        id: i32,
    }
    let page_data: Page<Hit> = get_json(ctx, &url).await?;
    Ok(page_data.results.into_iter().map(|h| h.id).collect())
}

/// Resolve TMDB ids for catalog rows that only have an IMDb id (legacy YTS/TVMaze rows).
pub async fn enrich_missing_from_imdb(ctx: &IngestContext) -> Result<()> {
    if ctx.config.tmdb_key().is_empty() {
        return Ok(());
    }
    let rows: Vec<(Uuid, String, String)> = sqlx::query_as(
        r#"
        SELECT t.id, t.imdb_id, t.kind
        FROM titles t
        WHERE t.imdb_id IS NOT NULL
          AND t.imdb_id <> ''
          AND (
            t.tmdb_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM title_people p WHERE p.title_id = t.id)
          )
        ORDER BY t.updated_at DESC NULLS LAST
        LIMIT 200
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    info!(count = rows.len(), "enriching legacy rows via TMDB find-by-IMDb");
    let mut linked = 0u32;
    for (_id, imdb_id, kind) in rows {
        match find_tmdb_id(ctx, &imdb_id, &kind).await {
            Ok(Some(tmdb_id)) => {
                let media = if kind == "series" { "series" } else { "movie" };
                match fetch_details(ctx, tmdb_id, media).await {
                    Ok(_) => linked += 1,
                    Err(e) => warn!(%imdb_id, tmdb_id, error = %e, "TMDB enrich details failed"),
                }
            }
            Ok(None) => debug!(%imdb_id, "TMDB find returned no match"),
            Err(e) => warn!(%imdb_id, error = %e, "TMDB find-by-IMDb failed"),
        }
    }
    info!(linked, "TMDB IMDb enrichment finished");
    Ok(())
}

#[derive(Debug, Deserialize)]
struct TmdbFindResponse {
    #[serde(default)]
    movie_results: Vec<TmdbFindHit>,
    #[serde(default)]
    tv_results: Vec<TmdbFindHit>,
}

#[derive(Debug, Deserialize)]
struct TmdbFindHit {
    id: i32,
}

async fn find_tmdb_id(ctx: &IngestContext, imdb_id: &str, kind: &str) -> Result<Option<i32>> {
    let url = format!(
        "{TMDB}/find/{imdb_id}?api_key={}&external_source=imdb_id&language={}",
        ctx.config.tmdb_key(),
        tmdb_locale(ctx)
    );
    let found: TmdbFindResponse = get_json(ctx, &url).await?;
    if kind == "series" {
        Ok(found.tv_results.first().map(|h| h.id).or_else(|| found.movie_results.first().map(|h| h.id)))
    } else {
        Ok(found.movie_results.first().map(|h| h.id).or_else(|| found.tv_results.first().map(|h| h.id)))
    }
}

pub async fn fetch_movies(ctx: &IngestContext) -> Result<()> {
    // Always pull the same shelves the home UI shows (trending / popular / fresh),
    // then optionally deepen with language-scoped discover. Language filtering
    // happens at upsert so curated TMDB lists stay meaningful.
    // Initial sync only takes TMDB_LIST_INITIAL_PAGES; scrolling fetches more.
    let month_start = current_month_start();
    let mut endpoints: Vec<(String, bool)> = [
        ("/movie/popular", false),
        ("/movie/top_rated", false),
        ("/movie/now_playing", false),
        ("/movie/upcoming", false),
        ("/trending/movie/day", false),
        ("/trending/movie/week", false),
    ]
    .into_iter()
    .map(|(p, f)| (p.to_owned(), f))
    .collect();
    if !preferred_codes(ctx).is_empty() {
        endpoints.push((
            "/discover/movie?sort_by=popularity.desc&include_adult=false".into(),
            true,
        ));
        endpoints.push((
            "/discover/movie?sort_by=vote_average.desc&vote_count.gte=100&include_adult=false"
                .into(),
            true,
        ));
        endpoints.push((
            format!(
                "/discover/movie?sort_by=primary_release_date.desc&include_adult=false&primary_release_date.gte={month_start}"
            ),
            true,
        ));
    }

    let mut tagged: std::collections::HashMap<i32, ShelfTags> = std::collections::HashMap::new();
    let listed: Vec<(Vec<i32>, ShelfTags)> = stream::iter(endpoints)
        .map(|(path, lang_filter)| {
            let ctx = ctx.clone();
            async move {
                let tags = ShelfTags::from_path(&path);
                let record = if is_canonical_shelf_path(&path) {
                    tags.shelf_name().map(|s| (s, "movie"))
                } else {
                    None
                };
                info!(path = %path, max_pages = TMDB_LIST_INITIAL_PAGES, "listing TMDB movies");
                let ids = match list_movie_ids(
                    &ctx,
                    &path,
                    lang_filter,
                    TMDB_LIST_INITIAL_PAGES,
                    record,
                )
                .await
                {
                    Ok(ids) => ids,
                    Err(e) => {
                        warn!(path = %path, error = %e, "TMDB movie list failed");
                        Vec::new()
                    }
                };
                (ids, tags)
            }
        })
        .buffer_unordered(3)
        .collect()
        .await;
    for (ids, tags) in listed {
        for id in ids {
            tagged.entry(id).or_default().merge(tags);
        }
    }
    let all_ids: Vec<(i32, ShelfTags)> = tagged.into_iter().collect();
    let total = all_ids.len();
    info!(
        total,
        concurrency = TMDB_CONCURRENCY,
        rate_per_sec = TMDB_PER_SEC,
        "ingesting TMDB movies"
    );
    let _ = db::set_sync_workers(&ctx.pool, TMDB_CONCURRENCY as i32).await;
    let done = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    stream::iter(all_ids)
        .map(|(id, tags)| {
            let ctx = ctx.clone();
            let done = done.clone();
            async move {
                match fetch_details_movie(&ctx, id).await {
                    Ok(details) => match upsert_movie(&ctx, details).await {
                        Ok(Some(title_id)) => {
                            if let Err(e) = mark_shelf_tags(&ctx, title_id, tags).await {
                                warn!(tmdb_id = id, error = %e, "shelf tag update failed");
                            }
                        }
                        Ok(None) => {}
                        Err(e) => warn!(tmdb_id = id, error = %e, "movie upsert failed"),
                    },
                    Err(e) => warn!(tmdb_id = id, error = %e, "movie details failed"),
                }
                let n = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                if n % 25 == 0 || n == total {
                    let pct = 5 + ((n as f64 / total.max(1) as f64) * 45.0) as i32;
                    let _ = db::set_sync_progress(
                        &ctx.pool,
                        &format!("TMDB · Movies ({n}/{total})"),
                        pct.min(54),
                        100,
                    )
                    .await;
                }
            }
        })
        .buffer_unordered(TMDB_CONCURRENCY)
        .collect::<Vec<_>>()
        .await;
    Ok(())
}

pub async fn fetch_tv(ctx: &IngestContext) -> Result<()> {
    let month_start = current_month_start();
    let mut endpoints: Vec<(String, bool)> = [
        ("/tv/popular", false),
        ("/tv/top_rated", false),
        ("/tv/on_the_air", false),
        ("/tv/airing_today", false),
        ("/trending/tv/day", false),
        ("/trending/tv/week", false),
    ]
    .into_iter()
    .map(|(p, f)| (p.to_owned(), f))
    .collect();
    if !preferred_codes(ctx).is_empty() {
        endpoints.push((
            "/discover/tv?sort_by=popularity.desc&include_adult=false".into(),
            true,
        ));
        endpoints.push((
            "/discover/tv?sort_by=vote_average.desc&vote_count.gte=100&include_adult=false".into(),
            true,
        ));
        endpoints.push((
            format!(
                "/discover/tv?sort_by=first_air_date.desc&include_adult=false&first_air_date.gte={month_start}"
            ),
            true,
        ));
    }

    let mut tagged: std::collections::HashMap<i32, ShelfTags> = std::collections::HashMap::new();
    let listed: Vec<(Vec<i32>, ShelfTags)> = stream::iter(endpoints)
        .map(|(path, lang_filter)| {
            let ctx = ctx.clone();
            async move {
                let tags = ShelfTags::from_path(&path);
                let record = if is_canonical_shelf_path(&path) {
                    tags.shelf_name().map(|s| (s, "tv"))
                } else {
                    None
                };
                info!(path = %path, max_pages = TMDB_LIST_INITIAL_PAGES, "listing TMDB TV");
                let ids =
                    match list_tv_ids(&ctx, &path, lang_filter, TMDB_LIST_INITIAL_PAGES, record)
                        .await
                    {
                        Ok(ids) => ids,
                        Err(e) => {
                            warn!(path = %path, error = %e, "TMDB TV list failed");
                            Vec::new()
                        }
                    };
                (ids, tags)
            }
        })
        .buffer_unordered(3)
        .collect()
        .await;
    for (ids, tags) in listed {
        for id in ids {
            tagged.entry(id).or_default().merge(tags);
        }
    }
    let all_ids: Vec<(i32, ShelfTags)> = tagged.into_iter().collect();
    let total = all_ids.len();
    info!(
        total,
        concurrency = TMDB_CONCURRENCY,
        rate_per_sec = TMDB_PER_SEC,
        "ingesting TMDB series"
    );
    let _ = db::set_sync_workers(&ctx.pool, TMDB_CONCURRENCY as i32).await;
    let done = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    stream::iter(all_ids)
        .map(|(id, tags)| {
            let ctx = ctx.clone();
            let done = done.clone();
            async move {
                match fetch_details_tv(&ctx, id).await {
                    Ok(details) => match upsert_tv(&ctx, details).await {
                        Ok(Some(title_id)) => {
                            if let Err(e) = mark_shelf_tags(&ctx, title_id, tags).await {
                                warn!(tmdb_id = id, error = %e, "shelf tag update failed");
                            }
                        }
                        Ok(None) => {}
                        Err(e) => warn!(tmdb_id = id, error = %e, "tv upsert failed"),
                    },
                    Err(e) => warn!(tmdb_id = id, error = %e, "tv details failed"),
                }
                let n = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                if n % 25 == 0 || n == total {
                    let pct = 55 + ((n as f64 / total.max(1) as f64) * 30.0) as i32;
                    let _ = db::set_sync_progress(
                        &ctx.pool,
                        &format!("TMDB · Series ({n}/{total})"),
                        pct.min(87),
                        100,
                    )
                    .await;
                }
            }
        })
        .buffer_unordered(TMDB_CONCURRENCY)
        .collect::<Vec<_>>()
        .await;
    Ok(())
}

pub async fn fetch_details(ctx: &IngestContext, tmdb_id: i32, kind: &str) -> Result<Uuid> {
    let id = if kind == "series" {
        let details = fetch_details_tv(ctx, tmdb_id).await?;
        upsert_tv(ctx, details).await?
    } else {
        let details = fetch_details_movie(ctx, tmdb_id).await?;
        upsert_movie(ctx, details).await?
    };
    id.ok_or_else(|| AppError::Message("title skipped by preferred language filter".into()))
}

pub async fn refresh_stale_titles(ctx: &IngestContext) -> Result<()> {
    let rows: Vec<(Uuid, Option<i32>, String)> = sqlx::query_as(
        r#"
        SELECT id, tmdb_id, kind
        FROM titles
        WHERE tmdb_id IS NOT NULL
          AND (
            updated_at < now() - interval '7 days'
            OR last_synced_at IS NULL
            OR logo_path IS NULL
            OR thumb_path IS NULL
            OR content_rating IS NULL
            OR NOT EXISTS (SELECT 1 FROM title_people p WHERE p.title_id = titles.id)
          )
        ORDER BY updated_at ASC NULLS FIRST
        LIMIT 80
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    for (id, tmdb_id, kind) in rows {
        let Some(tmdb_id) = tmdb_id else { continue };
        match fetch_details(ctx, tmdb_id, &kind).await {
            Ok(_) => debug!(%id, tmdb_id, "refreshed title"),
            Err(e) => warn!(%id, tmdb_id, error = %e, "stale refresh failed"),
        }
    }
    Ok(())
}

async fn list_movie_ids(
    ctx: &IngestContext,
    path: &str,
    lang_filter: bool,
    max_pages: i32,
    record: Option<(&str, &str)>,
) -> Result<Vec<i32>> {
    let mut ids = Vec::new();
    let mut page: i32 = 1;
    let max_pages = max_pages.clamp(1, TMDB_LIST_MAX_PAGES);
    let locale = tmdb_locale(ctx);
    let lang_q = if lang_filter {
        original_language_query(ctx)
    } else {
        String::new()
    };
    let sep = if path.contains('?') { '&' } else { '?' };
    while page <= max_pages {
        let url = format!(
            "{TMDB}{path}{sep}api_key={}&language={locale}&page={page}{lang_q}",
            ctx.config.tmdb_key()
        );
        let page_data: Page<MovieListItem> = match get_json(ctx, &url).await {
            Ok(data) => data,
            Err(e) => {
                // End-of-list / transient errors must not abort the whole sync.
                warn!(path, page, error = %e, "TMDB movie page stopped");
                break;
            }
        };
        let batch: Vec<i32> = page_data
            .results
            .into_iter()
            .filter(|m| m.adult != Some(true))
            .map(|m| m.id)
            .collect();
        if batch.is_empty() {
            break;
        }
        let total = page_data
            .total_pages
            .unwrap_or(max_pages)
            .clamp(1, TMDB_LIST_MAX_PAGES);
        if let Some((shelf, media)) = record {
            let _ = db::record_tmdb_shelf_page(
                &ctx.pool,
                shelf,
                media,
                page,
                total,
                batch.len() as i32,
            )
            .await;
        }
        ids.extend(batch);
        if page >= total {
            break;
        }
        page += 1;
    }
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

async fn list_tv_ids(
    ctx: &IngestContext,
    path: &str,
    lang_filter: bool,
    max_pages: i32,
    record: Option<(&str, &str)>,
) -> Result<Vec<i32>> {
    let mut ids = Vec::new();
    let mut page: i32 = 1;
    let max_pages = max_pages.clamp(1, TMDB_LIST_MAX_PAGES);
    let locale = tmdb_locale(ctx);
    let lang_q = if lang_filter {
        original_language_query(ctx)
    } else {
        String::new()
    };
    let sep = if path.contains('?') { '&' } else { '?' };
    while page <= max_pages {
        let url = format!(
            "{TMDB}{path}{sep}api_key={}&language={locale}&page={page}{lang_q}",
            ctx.config.tmdb_key()
        );
        let page_data: Page<TvListItem> = match get_json(ctx, &url).await {
            Ok(data) => data,
            Err(e) => {
                warn!(path, page, error = %e, "TMDB TV page stopped");
                break;
            }
        };
        let batch: Vec<i32> = page_data
            .results
            .into_iter()
            .filter(|m| m.adult != Some(true))
            .map(|m| m.id)
            .collect();
        if batch.is_empty() {
            break;
        }
        let total = page_data
            .total_pages
            .unwrap_or(max_pages)
            .clamp(1, TMDB_LIST_MAX_PAGES);
        if let Some((shelf, media)) = record {
            let _ = db::record_tmdb_shelf_page(
                &ctx.pool,
                shelf,
                media,
                page,
                total,
                batch.len() as i32,
            )
            .await;
        }
        ids.extend(batch);
        if page >= total {
            break;
        }
        page += 1;
    }
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

fn shelf_ensure_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Map catalog sort → TMDB shelf name used for lazy pagination.
pub fn shelf_for_sort(sort: &str) -> Option<&'static str> {
    match sort {
        "TRENDING" | "trending" => Some("trending"),
        "POPULARITY" | "popularity" => Some("popular"),
        "DATE_ADDED" | "date_added" | "DATEADDED" => Some("fresh"),
        _ => None,
    }
}

/// Ensure TMDB list pages covering `catalog_page * per_page` items are cached.
/// Called from GraphQL `catalog` when the user scrolls trending / popular / fresh.
pub async fn ensure_shelf_pages_for_catalog(
    ctx: &IngestContext,
    shelf: &str,
    kind: Option<&str>,
    catalog_page: i32,
    per_page: i32,
) -> Result<bool> {
    if ctx.config.tmdb_key().is_empty() {
        return Ok(false);
    }
    // Don't compete with a full catalog sync.
    if ctx.syncing.load(std::sync::atomic::Ordering::Relaxed) {
        return Ok(shelf_has_more_remote(ctx, shelf, kind).await.unwrap_or(false));
    }

    let needed = {
        let items = (catalog_page.max(1) as i64) * (per_page.max(1) as i64);
        let pages = ((items + TMDB_LIST_PAGE_SIZE as i64 - 1) / TMDB_LIST_PAGE_SIZE as i64) as i32;
        pages.clamp(1, TMDB_LIST_MAX_PAGES)
    };

    let medias: Vec<&str> = match kind {
        Some("movie") => vec!["movie"],
        Some("series") | Some("anime") => vec!["tv"],
        _ => vec!["movie", "tv"],
    };

    let _guard = shelf_ensure_lock().lock().await;
    for media in medias {
        ensure_shelf_media_pages(ctx, shelf, media, needed).await?;
    }
    shelf_has_more_remote(ctx, shelf, kind).await
}

async fn shelf_has_more_remote(
    ctx: &IngestContext,
    shelf: &str,
    kind: Option<&str>,
) -> Result<bool> {
    let medias: Vec<&str> = match kind {
        Some("movie") => vec!["movie"],
        Some("series") | Some("anime") => vec!["tv"],
        _ => vec!["movie", "tv"],
    };
    for media in medias {
        let max_page = db::tmdb_shelf_max_page(&ctx.pool, shelf, media).await?;
        let total = db::tmdb_shelf_total_pages(&ctx.pool, shelf, media).await?;
        if max_page > 0 && total > max_page && max_page < TMDB_LIST_MAX_PAGES {
            return Ok(true);
        }
        // Never synced this shelf yet — treat as "more available" so first scroll can fetch.
        if max_page == 0 {
            return Ok(true);
        }
    }
    Ok(false)
}

async fn ensure_shelf_media_pages(
    ctx: &IngestContext,
    shelf: &str,
    media: &str,
    needed_page: i32,
) -> Result<()> {
    let Some(path) = canonical_shelf_path(shelf, media) else {
        return Ok(());
    };
    let tags = ShelfTags::from_path(path);
    let mut page = db::tmdb_shelf_max_page(&ctx.pool, shelf, media).await? + 1;
    let known_total = db::tmdb_shelf_total_pages(&ctx.pool, shelf, media).await?;
    let mut total_cap = if known_total > 0 {
        known_total.min(TMDB_LIST_MAX_PAGES)
    } else {
        TMDB_LIST_MAX_PAGES
    };

    while page <= needed_page && page <= total_cap {
        if db::tmdb_shelf_page_synced(&ctx.pool, shelf, media, page).await? {
            page += 1;
            continue;
        }
        info!(shelf, media, page, path, "lazy-fetching TMDB shelf page");
        let ids = fetch_list_page_ids(ctx, path, false, page).await?;
        let (page_ids, total_pages) = ids;
        total_cap = total_pages.min(TMDB_LIST_MAX_PAGES);
        let _ = db::record_tmdb_shelf_page(
            &ctx.pool,
            shelf,
            media,
            page,
            total_cap,
            page_ids.len() as i32,
        )
        .await;
        if page_ids.is_empty() {
            break;
        }

        // Ingest this page's titles (detail + shelf tag) so catalog can return them.
        stream::iter(page_ids)
            .map(|id| {
                let ctx = ctx.clone();
                async move {
                    let result = if media == "tv" {
                        match fetch_details_tv(&ctx, id).await {
                            Ok(d) => upsert_tv(&ctx, d).await,
                            Err(e) => Err(e),
                        }
                    } else {
                        match fetch_details_movie(&ctx, id).await {
                            Ok(d) => upsert_movie(&ctx, d).await,
                            Err(e) => Err(e),
                        }
                    };
                    match result {
                        Ok(Some(title_id)) => {
                            if let Err(e) = mark_shelf_tags(&ctx, title_id, tags).await {
                                warn!(tmdb_id = id, error = %e, "shelf tag update failed");
                            } else if let Err(e) = reindex(&ctx, title_id).await {
                                debug!(tmdb_id = id, error = %e, "meili reindex skipped");
                            }
                        }
                        Ok(None) => {}
                        Err(e) => warn!(tmdb_id = id, media, error = %e, "lazy shelf ingest failed"),
                    }
                }
            })
            .buffer_unordered(TMDB_CONCURRENCY.min(6))
            .collect::<Vec<_>>()
            .await;

        if page >= total_cap {
            break;
        }
        page += 1;
    }
    Ok(())
}

async fn fetch_list_page_ids(
    ctx: &IngestContext,
    path: &str,
    lang_filter: bool,
    page: i32,
) -> Result<(Vec<i32>, i32)> {
    let locale = tmdb_locale(ctx);
    let lang_q = if lang_filter {
        original_language_query(ctx)
    } else {
        String::new()
    };
    let sep = if path.contains('?') { '&' } else { '?' };
    let url = format!(
        "{TMDB}{path}{sep}api_key={}&language={locale}&page={page}{lang_q}",
        ctx.config.tmdb_key()
    );
    if path.contains("/tv") || path.contains("trending/tv") {
        let page_data: Page<TvListItem> = get_json(ctx, &url).await?;
        let ids = page_data
            .results
            .into_iter()
            .filter(|m| m.adult != Some(true))
            .map(|m| m.id)
            .collect();
        let total = page_data
            .total_pages
            .unwrap_or(1)
            .clamp(1, TMDB_LIST_MAX_PAGES);
        Ok((ids, total))
    } else {
        let page_data: Page<MovieListItem> = get_json(ctx, &url).await?;
        let ids = page_data
            .results
            .into_iter()
            .filter(|m| m.adult != Some(true))
            .map(|m| m.id)
            .collect();
        let total = page_data
            .total_pages
            .unwrap_or(1)
            .clamp(1, TMDB_LIST_MAX_PAGES);
        Ok((ids, total))
    }
}

async fn fetch_details_movie(ctx: &IngestContext, id: i32) -> Result<MovieDetails> {
    let locale = tmdb_locale(ctx);
    let img_lang = image_language_param(ctx);
    let url = format!(
        "{TMDB}/movie/{id}?api_key={}&language={locale}&append_to_response=videos,images,credits,release_dates&include_image_language={img_lang}",
        ctx.config.tmdb_key()
    );
    get_json(ctx, &url).await
}

async fn fetch_details_tv(ctx: &IngestContext, id: i32) -> Result<TvDetails> {
    let locale = tmdb_locale(ctx);
    let img_lang = image_language_param(ctx);
    let url = format!(
        "{TMDB}/tv/{id}?api_key={}&language={locale}&append_to_response=videos,external_ids,images,credits,aggregate_credits,content_ratings&include_image_language={img_lang}",
        ctx.config.tmdb_key()
    );
    get_json(ctx, &url).await
}

async fn upsert_movie(ctx: &IngestContext, details: MovieDetails) -> Result<Option<Uuid>> {
    if details.adult == Some(true) {
        debug!(tmdb_id = details.id, "skipping adult movie");
        return Ok(None);
    }
    if details
        .release_date
        .as_deref()
        .is_some_and(crate::content_filter::is_unreleased_date)
    {
        debug!(tmdb_id = details.id, "skipping unreleased movie");
        return Ok(None);
    }
    if details
        .genres
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .any(|g| crate::content_filter::is_blocked_genre(&g.name))
    {
        debug!(tmdb_id = details.id, "skipping movie with blocked genre");
        return Ok(None);
    }
    if !accepts_original_language(ctx, details.original_language.as_deref()) {
        debug!(
            tmdb_id = details.id,
            lang = ?details.original_language,
            "skipping movie outside preferred languages"
        );
        return Ok(None);
    }
    let year = year_from(&details.release_date);
    let synopsis = details.overview.clone();
    let id = upsert_title(
        ctx,
        "movie",
        &details.title,
        details.original_title.as_deref(),
        synopsis.as_deref(),
        details.overview.as_deref(),
        year,
        details.runtime,
        details.poster_path.as_deref(),
        details.backdrop_path.as_deref(),
        Some(details.id),
        details.imdb_id.as_deref(),
        None,
        None,
        details.original_language.as_deref(),
    )
    .await?;

    replace_genres(ctx, id, details.genres.as_deref().unwrap_or(&[])).await?;
    replace_trailers(ctx, id, details.videos.as_ref()).await?;
    apply_extra_art(ctx, id, details.images.as_ref()).await?;
    replace_people(ctx, id, details.credits.as_ref()).await?;
    apply_content_rating(ctx, id, certification_from_releases(details.release_dates.as_ref())).await?;
    apply_released_at(ctx, id, details.release_date.as_deref()).await?;
    upsert_ratings(
        ctx,
        id,
        details.vote_average,
        details.vote_count,
        None,
        None,
        None,
        None,
        None,
        details.popularity,
    )
    .await?;
    reindex(ctx, id).await?;
    Ok(Some(id))
}

async fn upsert_tv(ctx: &IngestContext, details: TvDetails) -> Result<Option<Uuid>> {
    if details.adult == Some(true) {
        debug!(tmdb_id = details.id, "skipping adult series");
        return Ok(None);
    }
    if details
        .first_air_date
        .as_deref()
        .is_some_and(crate::content_filter::is_unreleased_date)
    {
        debug!(tmdb_id = details.id, "skipping unreleased series");
        return Ok(None);
    }
    if details
        .genres
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .any(|g| crate::content_filter::is_blocked_genre(&g.name))
    {
        debug!(tmdb_id = details.id, "skipping series with blocked genre");
        return Ok(None);
    }
    if !accepts_original_language(ctx, details.original_language.as_deref()) {
        debug!(
            tmdb_id = details.id,
            lang = ?details.original_language,
            "skipping series outside preferred languages"
        );
        return Ok(None);
    }
    let year = year_from(&details.first_air_date);
    let runtime = details
        .episode_run_time
        .as_ref()
        .and_then(|v| v.first().copied());

    let imdb_id = details
        .external_ids
        .as_ref()
        .and_then(|e| e.imdb_id.clone());

    let tmdb_tv_id = details.id;
    let id = upsert_title(
        ctx,
        "series",
        &details.name,
        details.original_name.as_deref(),
        details.overview.as_deref(),
        details.overview.as_deref(),
        year,
        runtime,
        details.poster_path.as_deref(),
        details.backdrop_path.as_deref(),
        Some(details.id),
        imdb_id.as_deref(),
        None,
        None,
        details.original_language.as_deref(),
    )
    .await?;

    replace_genres(ctx, id, details.genres.as_deref().unwrap_or(&[])).await?;
    replace_trailers(ctx, id, details.videos.as_ref()).await?;
    apply_extra_art(ctx, id, details.images.as_ref()).await?;
    replace_people(
        ctx,
        id,
        pick_credits(details.credits.as_ref(), details.aggregate_credits.as_ref()),
    )
    .await?;
    apply_content_rating(ctx, id, certification_from_tv(details.content_ratings.as_ref())).await?;
    apply_released_at(ctx, id, details.first_air_date.as_deref()).await?;
    upsert_ratings(
        ctx,
        id,
        details.vote_average,
        details.vote_count,
        None,
        None,
        None,
        None,
        None,
        details.popularity,
    )
    .await?;

    if let Some(seasons) = details.seasons {
        let season_jobs: Vec<_> = seasons
            .into_iter()
            .filter(|s| s.season_number >= 0)
            .collect();
        stream::iter(season_jobs)
            .map(|season| {
                let ctx = ctx.clone();
                async move {
                    match upsert_season(&ctx, id, &season).await {
                        Ok(season_id) => {
                            if let Err(e) =
                                sync_season_episodes(&ctx, tmdb_tv_id, season.season_number, season_id)
                                    .await
                            {
                                warn!(
                                    tmdb_id = tmdb_tv_id,
                                    season = season.season_number,
                                    error = %e,
                                    "season episodes failed"
                                );
                            }
                        }
                        Err(e) => warn!(
                            tmdb_id = tmdb_tv_id,
                            season = season.season_number,
                            error = %e,
                            "season upsert failed"
                        ),
                    }
                }
            })
            .buffer_unordered(6)
            .collect::<Vec<_>>()
            .await;
    }

    reindex(ctx, id).await?;
    Ok(Some(id))
}

async fn sync_season_episodes(
    ctx: &IngestContext,
    tmdb_tv_id: i32,
    season_number: i32,
    season_id: Uuid,
) -> Result<()> {
    let locale = tmdb_locale(ctx);
    let url = format!(
        "{TMDB}/tv/{tmdb_tv_id}/season/{season_number}?api_key={}&language={locale}",
        ctx.config.tmdb_key()
    );
    let details: SeasonDetails = get_json(ctx, &url).await?;
    for ep in details.episodes.unwrap_or_default() {
        sqlx::query(
            r#"
            INSERT INTO episodes (season_id, episode_number, name, overview, still_path, air_date, runtime, tmdb_episode_id)
            VALUES ($1, $2, $3, $4, $5, $6::date, $7, $8)
            ON CONFLICT (season_id, episode_number) DO UPDATE SET
                name = EXCLUDED.name,
                overview = EXCLUDED.overview,
                still_path = EXCLUDED.still_path,
                air_date = EXCLUDED.air_date,
                runtime = EXCLUDED.runtime,
                tmdb_episode_id = EXCLUDED.tmdb_episode_id
            "#,
        )
        .bind(season_id)
        .bind(ep.episode_number)
        .bind(ep.name)
        .bind(ep.overview)
        .bind(ep.still_path)
        .bind(ep.air_date)
        .bind(ep.runtime)
        .bind(ep.id)
        .execute(&ctx.pool)
        .await?;
    }
    Ok(())
}

async fn upsert_season(ctx: &IngestContext, title_id: Uuid, season: &TmdbSeason) -> Result<Uuid> {
    let row: (Uuid,) = sqlx::query_as(
        r#"
        INSERT INTO seasons (title_id, season_number, name, overview, poster_path, air_date, episode_count, tmdb_season_id)
        VALUES ($1, $2, $3, $4, $5, $6::date, $7, $8)
        ON CONFLICT (title_id, season_number) DO UPDATE SET
            name = EXCLUDED.name,
            overview = EXCLUDED.overview,
            poster_path = EXCLUDED.poster_path,
            air_date = EXCLUDED.air_date,
            episode_count = EXCLUDED.episode_count,
            tmdb_season_id = EXCLUDED.tmdb_season_id
        RETURNING id
        "#,
    )
    .bind(title_id)
    .bind(season.season_number)
    .bind(&season.name)
    .bind(&season.overview)
    .bind(&season.poster_path)
    .bind(&season.air_date)
    .bind(season.episode_count)
    .bind(season.id)
    .fetch_one(&ctx.pool)
    .await?;
    Ok(row.0)
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn upsert_title(
    ctx: &IngestContext,
    kind: &str,
    title: &str,
    original_title: Option<&str>,
    synopsis: Option<&str>,
    description: Option<&str>,
    year: Option<i32>,
    runtime_minutes: Option<i32>,
    poster_path: Option<&str>,
    backdrop_path: Option<&str>,
    tmdb_id: Option<i32>,
    imdb_id: Option<&str>,
    anilist_id: Option<i32>,
    mal_id: Option<i32>,
    original_language: Option<&str>,
) -> Result<Uuid> {
    let mut existing: Option<(Uuid,)> = if let Some(tmdb_id) = tmdb_id {
        // TMDB movie/TV namespaces reuse integers — always scope by kind.
        sqlx::query_as("SELECT id FROM titles WHERE tmdb_id = $1 AND kind = $2")
            .bind(tmdb_id)
            .bind(kind)
            .fetch_optional(&ctx.pool)
            .await?
    } else {
        None
    };
    if existing.is_none() {
        if let Some(imdb_id) = imdb_id.filter(|s| !s.is_empty()) {
            existing = sqlx::query_as("SELECT id FROM titles WHERE imdb_id = $1 AND kind = $2")
                .bind(imdb_id)
                .bind(kind)
                .fetch_optional(&ctx.pool)
                .await?;
        }
    }
    // Merge into legacy catalog rows (YTS/TVMaze) that lack tmdb_id.
    if existing.is_none() {
        existing = sqlx::query_as(
            r#"
            SELECT id FROM titles
            WHERE kind = $1
              AND lower(title) = lower($2)
              AND ($3::int IS NULL OR year IS NULL OR year = $3)
            ORDER BY CASE WHEN tmdb_id IS NULL THEN 0 ELSE 1 END, updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(kind)
        .bind(title)
        .bind(year)
        .fetch_optional(&ctx.pool)
        .await?;
    }

    if let Some((id,)) = existing {
        sqlx::query(
            r#"
            UPDATE titles SET
                kind = $2, title = $3,
                original_title = COALESCE($4, original_title),
                synopsis = COALESCE($5, synopsis),
                description = COALESCE($6, description),
                year = COALESCE($7, year),
                runtime_minutes = COALESCE($8, runtime_minutes),
                poster_path = COALESCE($9, poster_path),
                backdrop_path = COALESCE($10, backdrop_path),
                tmdb_id = COALESCE($11, tmdb_id),
                imdb_id = COALESCE($12, imdb_id), anilist_id = COALESCE($13, anilist_id),
                mal_id = COALESCE($14, mal_id),
                original_language = COALESCE($15, original_language),
                last_synced_at = now()
            WHERE id = $1
            "#,
        )
        .bind(id)
        .bind(kind)
        .bind(title)
        .bind(original_title)
        .bind(synopsis)
        .bind(description)
        .bind(year)
        .bind(runtime_minutes)
        .bind(poster_path)
        .bind(backdrop_path)
        .bind(tmdb_id)
        .bind(imdb_id)
        .bind(anilist_id)
        .bind(mal_id)
        .bind(original_language)
        .execute(&ctx.pool)
        .await?;
        return Ok(id);
    }

    let row: (Uuid,) = sqlx::query_as(
        r#"
        INSERT INTO titles (
            kind, title, original_title, synopsis, description, year, runtime_minutes,
            poster_path, backdrop_path, tmdb_id, imdb_id, anilist_id, mal_id,
            original_language, last_synced_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14, now())
        RETURNING id
        "#,
    )
    .bind(kind)
    .bind(title)
    .bind(original_title)
    .bind(synopsis)
    .bind(description)
    .bind(year)
    .bind(runtime_minutes)
    .bind(poster_path)
    .bind(backdrop_path)
    .bind(tmdb_id)
    .bind(imdb_id)
    .bind(anilist_id)
    .bind(mal_id)
    .bind(original_language)
    .fetch_one(&ctx.pool)
    .await?;
    Ok(row.0)
}

fn pick_image<'a>(images: &'a [TmdbImage], prefer_text: bool, wanted: &[String]) -> Option<&'a TmdbImage> {
    let mut scored: Vec<(i32, &'a TmdbImage)> = images
        .iter()
        .map(|img| {
            let lang = img.iso_639_1.as_deref().unwrap_or("");
            let lang_score = language_match_score(wanted, Some(lang));
            let text_bonus = if prefer_text && !lang.is_empty() { 1 } else { 0 };
            let votes = (img.vote_average.unwrap_or(0.0) * 100.0) as i32;
            (lang_score * 10_000 + text_bonus * 1_000 + votes, img)
        })
        .collect();
    scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    scored.first().map(|(_, img)| *img)
}

/// Banner backdrops: preferred language first, then textless, then anything — highest votes.
fn pick_banner_backdrop<'a>(images: &'a [TmdbImage], wanted: &[String]) -> Option<&'a TmdbImage> {
    let mut scored: Vec<(i32, &'a TmdbImage)> = images
        .iter()
        .map(|img| {
            let lang = img.iso_639_1.as_deref().unwrap_or("");
            let lang_score = language_match_score(wanted, Some(lang));
            let votes = (img.vote_average.unwrap_or(0.0) * 100.0) as i32;
            (lang_score * 10_000 + votes, img)
        })
        .collect();
    scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    scored.first().map(|(_, img)| *img)
}

fn certification_from_releases(dates: Option<&ReleaseDateResults>) -> Option<String> {
    let results = dates?.results.as_ref()?;
    let us = results.iter().find(|c| c.iso_3166_1.as_deref() == Some("US"));
    let pick = |country: &ReleaseDateCountry| {
        country.release_dates.as_ref()?.iter().find_map(|d| {
            d.certification
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
    };
    us.and_then(pick).or_else(|| results.iter().find_map(pick))
}

fn certification_from_tv(ratings: Option<&TvRatingResults>) -> Option<String> {
    let results = ratings?.results.as_ref()?;
    let pick = |row: &TvRating| {
        row.rating
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    results
        .iter()
        .find(|c| c.iso_3166_1.as_deref() == Some("US"))
        .and_then(pick)
        .or_else(|| results.iter().find_map(pick))
}

pub(crate) async fn apply_content_rating(
    ctx: &IngestContext,
    title_id: Uuid,
    rating: Option<String>,
) -> Result<()> {
    let Some(rating) = rating.filter(|s| !s.is_empty()) else {
        return Ok(());
    };
    if crate::content_filter::is_blocked_content_rating(&rating) {
        // Explicit adult rating — drop the title entirely.
        sqlx::query("DELETE FROM titles WHERE id = $1")
            .bind(title_id)
            .execute(&ctx.pool)
            .await?;
        return Ok(());
    }
    sqlx::query(
        r#"
        UPDATE titles SET content_rating = COALESCE($2, content_rating)
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .bind(&rating)
    .execute(&ctx.pool)
    .await?;
    Ok(())
}

/// Store theatrical / first-air date for Popcorn Time–style "Last added" sorting.
pub(crate) async fn apply_released_at(
    ctx: &IngestContext,
    title_id: Uuid,
    raw: Option<&str>,
) -> Result<()> {
    let Some(raw) = raw.map(str::trim).filter(|s| s.len() >= 8) else {
        return Ok(());
    };
    // TMDB dates are YYYY-MM-DD; reject partial years.
    if raw.len() < 10 {
        return Ok(());
    }
    sqlx::query(
        r#"
        UPDATE titles
        SET released_at = COALESCE($2::date, released_at)
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .bind(raw)
    .execute(&ctx.pool)
    .await?;
    Ok(())
}

async fn mark_shelf_tags(ctx: &IngestContext, title_id: Uuid, tags: ShelfTags) -> Result<()> {
    if !tags.trending && !tags.popular && !tags.fresh {
        return Ok(());
    }
    sqlx::query(
        r#"
        UPDATE titles SET
            list_trending_at = CASE WHEN $2 THEN now() ELSE list_trending_at END,
            list_popular_at  = CASE WHEN $3 THEN now() ELSE list_popular_at END,
            list_fresh_at    = CASE WHEN $4 THEN now() ELSE list_fresh_at END
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .bind(tags.trending)
    .bind(tags.popular)
    .bind(tags.fresh)
    .execute(&ctx.pool)
    .await?;
    Ok(())
}

async fn apply_extra_art(ctx: &IngestContext, title_id: Uuid, images: Option<&TmdbImages>) -> Result<()> {
    let Some(images) = images else { return Ok(()) };
    let wanted = preferred_codes(ctx);
    let logo = images.logos.as_ref().and_then(|v| pick_image(v, true, &wanted));
    // Hero banners: prefer preferred-language backdrops, then textless, by vote average.
    let backdrop = images
        .backdrops
        .as_ref()
        .and_then(|v| pick_banner_backdrop(v, &wanted));
    let thumb = images
        .backdrops
        .as_ref()
        .and_then(|v| pick_image(v, true, &wanted))
        .or(backdrop);
    sqlx::query(
        r#"
        UPDATE titles SET
            logo_path = COALESCE($2, logo_path),
            thumb_path = COALESCE($3, thumb_path),
            backdrop_path = COALESCE($4, backdrop_path)
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .bind(logo.map(|img| img.file_path.as_str()))
    .bind(thumb.map(|img| img.file_path.as_str()))
    .bind(backdrop.map(|img| img.file_path.as_str()))
    .execute(&ctx.pool)
    .await?;
    Ok(())
}

fn pick_credits<'a>(credits: Option<&'a TmdbCredits>, aggregate: Option<&'a TmdbCredits>) -> Option<&'a TmdbCredits> {
    let agg_len = aggregate.and_then(|c| c.cast.as_ref()).map(|v| v.len()).unwrap_or(0);
    let cred_len = credits.and_then(|c| c.cast.as_ref()).map(|v| v.len()).unwrap_or(0);
    if agg_len >= cred_len && agg_len > 0 {
        aggregate
    } else {
        credits.or(aggregate)
    }
}

fn cast_character(member: &TmdbCast) -> Option<String> {
    member
        .character
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .or_else(|| {
            member.roles.as_ref()?.iter().find_map(|role| {
                role.character
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
            })
        })
}

fn crew_job(member: &TmdbCrew) -> Option<String> {
    member
        .job
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .or_else(|| {
            member.jobs.as_ref()?.iter().find_map(|job| {
                job.job
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
            })
        })
}

pub(crate) struct CreditPerson {
    pub name: String,
    pub character: Option<String>,
    pub job: Option<String>,
    pub department: &'static str,
    pub profile_path: Option<String>,
    pub sort_order: i32,
}

pub(crate) async fn replace_credit_people(
    ctx: &IngestContext,
    title_id: Uuid,
    people: &[CreditPerson],
) -> Result<()> {
    sqlx::query("DELETE FROM title_people WHERE title_id = $1")
        .bind(title_id)
        .execute(&ctx.pool)
        .await?;
    for person in people {
        sqlx::query(
            r#"
            INSERT INTO title_people (title_id, name, character, job, department, profile_path, sort_order)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            "#,
        )
        .bind(title_id)
        .bind(&person.name)
        .bind(&person.character)
        .bind(&person.job)
        .bind(person.department)
        .bind(&person.profile_path)
        .bind(person.sort_order)
        .execute(&ctx.pool)
        .await?;
    }
    Ok(())
}

async fn replace_people(ctx: &IngestContext, title_id: Uuid, credits: Option<&TmdbCredits>) -> Result<()> {
    let Some(credits) = credits else { return Ok(()) };
    let mut people = Vec::new();
    for member in credits.cast.as_deref().unwrap_or(&[]).iter().take(12) {
        let Some(name) = member.name.as_deref().filter(|n| !n.is_empty()) else { continue };
        people.push(CreditPerson {
            name: name.to_string(),
            character: cast_character(member),
            job: None,
            department: "cast",
            profile_path: member.profile_path.clone(),
            sort_order: member.order.unwrap_or(people.len() as i32),
        });
    }
    let mut crew_order = 0i32;
    for member in credits.crew.as_deref().unwrap_or(&[]) {
        let Some(job) = crew_job(member) else { continue };
        if !matches!(
            job.as_str(),
            "Director" | "Writer" | "Screenplay" | "Creator" | "Executive Producer" | "Producer"
        ) {
            continue;
        }
        let Some(name) = member.name.as_deref().filter(|n| !n.is_empty()) else { continue };
        people.push(CreditPerson {
            name: name.to_string(),
            character: None,
            job: Some(job),
            department: "crew",
            profile_path: member.profile_path.clone(),
            sort_order: crew_order,
        });
        crew_order += 1;
        if crew_order >= 8 {
            break;
        }
    }
    replace_credit_people(ctx, title_id, &people).await
}

async fn replace_genres(ctx: &IngestContext, title_id: Uuid, genres: &[Genre]) -> Result<()> {
    let names: Vec<String> = genres.iter().map(|g| g.name.clone()).collect();
    replace_genre_names(ctx, title_id, &names).await
}

pub(crate) async fn replace_genre_names(
    ctx: &IngestContext,
    title_id: Uuid,
    names: &[String],
) -> Result<()> {
    sqlx::query("DELETE FROM title_genres WHERE title_id = $1")
        .bind(title_id)
        .execute(&ctx.pool)
        .await?;
    for name in names {
        let name = name.trim();
        if name.is_empty() || crate::content_filter::is_blocked_genre(name) {
            continue;
        }
        let (genre_id,): (Uuid,) = sqlx::query_as(
            r#"
            INSERT INTO genres (name) VALUES ($1)
            ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
            "#,
        )
        .bind(name)
        .fetch_one(&ctx.pool)
        .await?;
        sqlx::query(
            "INSERT INTO title_genres (title_id, genre_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(title_id)
        .bind(genre_id)
        .execute(&ctx.pool)
        .await?;
    }
    Ok(())
}

async fn replace_trailers(ctx: &IngestContext, title_id: Uuid, videos: Option<&VideoResults>) -> Result<()> {
    let Some(videos) = videos else { return Ok(()) };
    let wanted = preferred_codes(ctx);

    // Prefer preferred-language Trailer > Teaser; highest size wins. Keep exactly one.
    let mut best: Option<&Video> = None;
    let mut best_score: (i32, i32, i32) = (-1, -1, -1); // (lang, kind_rank, size)
    for v in &videos.results {
        if !v.site.eq_ignore_ascii_case("YouTube") {
            continue;
        }
        let kind = v.kind.as_deref().unwrap_or("");
        let kind_rank = if kind.eq_ignore_ascii_case("Trailer") {
            2
        } else if kind.eq_ignore_ascii_case("Teaser") {
            1
        } else {
            continue;
        };
        if v.size.unwrap_or(0) > 0 && v.size.unwrap_or(0) < 720 {
            continue;
        }
        if v.name.to_ascii_lowercase().contains("mobile") {
            continue;
        }
        // When languages are locked, skip trailers in other languages.
        let lang_score = language_match_score(&wanted, v.iso_639_1.as_deref());
        if !wanted.is_empty() && lang_score == 0 {
            continue;
        }
        let size = v.size.unwrap_or(0);
        let score = (lang_score, kind_rank, size);
        if score > best_score {
            best_score = score;
            best = Some(v);
        }
    }

    // Fallback: if nothing matched preferred language, take best Trailer/Teaser of any language.
    if best.is_none() && !wanted.is_empty() {
        for v in &videos.results {
            if !v.site.eq_ignore_ascii_case("YouTube") {
                continue;
            }
            let kind = v.kind.as_deref().unwrap_or("");
            let kind_rank = if kind.eq_ignore_ascii_case("Trailer") {
                2
            } else if kind.eq_ignore_ascii_case("Teaser") {
                1
            } else {
                continue;
            };
            if v.size.unwrap_or(0) > 0 && v.size.unwrap_or(0) < 720 {
                continue;
            }
            if v.name.to_ascii_lowercase().contains("mobile") {
                continue;
            }
            let size = v.size.unwrap_or(0);
            let score = (0, kind_rank, size);
            if score > best_score {
                best_score = score;
                best = Some(v);
            }
        }
    }

    sqlx::query("DELETE FROM trailers WHERE title_id = $1")
        .bind(title_id)
        .execute(&ctx.pool)
        .await?;

    if let Some(v) = best {
        sqlx::query(
            r#"
            INSERT INTO trailers (title_id, name, youtube_key, site, size)
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(title_id)
        .bind(&v.name)
        .bind(&v.key)
        .bind(&v.site)
        .bind(v.size)
        .execute(&ctx.pool)
        .await?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn upsert_ratings(
    ctx: &IngestContext,
    title_id: Uuid,
    tmdb_vote_average: Option<f64>,
    tmdb_vote_count: Option<i32>,
    imdb_rating: Option<f64>,
    imdb_votes: Option<i32>,
    anilist_score: Option<f64>,
    anilist_popularity: Option<i32>,
    rt_score: Option<i32>,
    tmdb_popularity: Option<f64>,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO ratings (
            title_id, tmdb_vote_average, tmdb_vote_count, imdb_rating, imdb_votes,
            anilist_score, anilist_popularity, rt_score, tmdb_popularity, updated_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9, now())
        ON CONFLICT (title_id) DO UPDATE SET
            tmdb_vote_average = COALESCE(EXCLUDED.tmdb_vote_average, ratings.tmdb_vote_average),
            tmdb_vote_count = COALESCE(EXCLUDED.tmdb_vote_count, ratings.tmdb_vote_count),
            imdb_rating = COALESCE(EXCLUDED.imdb_rating, ratings.imdb_rating),
            imdb_votes = COALESCE(EXCLUDED.imdb_votes, ratings.imdb_votes),
            anilist_score = COALESCE(EXCLUDED.anilist_score, ratings.anilist_score),
            anilist_popularity = COALESCE(EXCLUDED.anilist_popularity, ratings.anilist_popularity),
            rt_score = COALESCE(EXCLUDED.rt_score, ratings.rt_score),
            tmdb_popularity = COALESCE(EXCLUDED.tmdb_popularity, ratings.tmdb_popularity),
            updated_at = now()
        "#,
    )
    .bind(title_id)
    .bind(tmdb_vote_average)
    .bind(tmdb_vote_count)
    .bind(imdb_rating)
    .bind(imdb_votes)
    .bind(anilist_score)
    .bind(anilist_popularity)
    .bind(rt_score)
    .bind(tmdb_popularity)
    .execute(&ctx.pool)
    .await?;
    Ok(())
}

pub async fn reindex(ctx: &IngestContext, title_id: Uuid) -> Result<()> {
    let row: Option<TitleRow> = sqlx::query_as(
        r#"
        SELECT id, kind, title, original_title, synopsis, description, year, runtime_minutes,
               poster_path, backdrop_path, logo_path, thumb_path, content_rating, tmdb_id, imdb_id, anilist_id,
               mal_id, metadata, created_at, updated_at, last_synced_at
        FROM titles WHERE id = $1
        "#,
    )
    .bind(title_id)
    .fetch_optional(&ctx.pool)
    .await?;
    let Some(row) = row else { return Ok(()) };
    let genres = db::genre_names_for_title(&ctx.pool, title_id).await?;
    let rating: Option<(Option<f64>,)> =
        sqlx::query_as("SELECT tmdb_vote_average FROM ratings WHERE title_id = $1")
            .bind(title_id)
            .fetch_optional(&ctx.pool)
            .await?;
    ctx.search
        .index_title(&row, &genres, rating.and_then(|r| r.0))
        .await?;
    Ok(())
}

/// Fast end-of-sync search rebuild: batch Meili docs without waiting per title.
pub async fn reindex_all_titles(ctx: &IngestContext) -> Result<()> {
    let rows: Vec<TitleRow> = sqlx::query_as(
        r#"
        SELECT id, kind, title, original_title, synopsis, description, year, runtime_minutes,
               poster_path, backdrop_path, logo_path, thumb_path, content_rating, tmdb_id, imdb_id, anilist_id,
               mal_id, metadata, created_at, updated_at, last_synced_at
        FROM titles
        ORDER BY updated_at DESC NULLS LAST
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    let mut batch = Vec::with_capacity(100);
    for row in rows {
        batch.push(crate::search::SearchClient::title_document(&row, &[], None));
        if batch.len() >= 100 {
            ctx.search.index_titles_batch(&batch).await?;
            batch.clear();
        }
    }
    if !batch.is_empty() {
        ctx.search.index_titles_batch(&batch).await?;
    }
    Ok(())
}

fn year_from(date: &Option<String>) -> Option<i32> {
    date.as_ref()
        .and_then(|d| d.get(0..4))
        .and_then(|y| y.parse().ok())
        .filter(|y| *y > 1800)
}

async fn get_json<T: serde::de::DeserializeOwned>(ctx: &IngestContext, url: &str) -> Result<T> {
    wait_tmdb_slot().await;
    let resp = ctx
        .http
        .get(url)
        .header("Accept", "application/json")
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(AppError::Provider(format!(
            "TMDB {status}: {}",
            body.chars().take(200).collect::<String>()
        )));
    }
    Ok(resp.json().await?)
}
