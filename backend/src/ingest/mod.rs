use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use reqwest::Client;
use sqlx::PgPool;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::config::Config;
use crate::db;
use crate::error::Result;
use crate::search::SearchClient;

pub mod anilist;
pub mod jackett;
pub mod jikan;
pub mod omdb;
pub mod scheduler;
pub mod tmdb;
pub mod tvmaze;
pub mod yts;

/// Concurrent page workers per catalog pipeline (movies + series run in parallel).
/// Override with `SYNC_WORKERS` env (e.g. `24`). Default: 2× CPU cores, clamped 8–32.
pub fn sync_workers() -> usize {
    if let Ok(raw) = std::env::var("SYNC_WORKERS") {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            if let Ok(n) = trimmed.parse::<usize>() {
                return n.clamp(1, 64);
            }
        }
    }
    // Push hard by default — Meili waits are gone, so higher concurrency is safe.
    std::thread::available_parallelism()
        .map(|n| (n.get().saturating_mul(4)).clamp(16, 48))
        .unwrap_or(24)
}

/// Back-compat name used by YTS / TVMaze / AniList modules.
pub const SYNC_WORKERS: usize = 16;

#[derive(Clone)]
pub struct IngestContext {
    pub pool: PgPool,
    pub search: SearchClient,
    pub config: Config,
    pub syncing: Arc<AtomicBool>,
    pub jackett_syncing: Arc<AtomicBool>,
    pub http: Client,
}

impl IngestContext {
    pub fn new(
        pool: PgPool,
        search: SearchClient,
        config: Config,
        syncing: Arc<AtomicBool>,
        jackett_syncing: Arc<AtomicBool>,
        http: Client,
    ) -> Self {
        Self {
            pool,
            search,
            config,
            syncing,
            jackett_syncing,
            http,
        }
    }
}

/// Run catalog sync on a dedicated OS thread so Axum workers stay free to serve
/// GraphQL / search / playback while TMDB ingest is in flight.
pub fn spawn_full_sync(ctx: IngestContext) {
    let _ = std::thread::Builder::new()
        .name("pb-catalog-sync".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    error!(error = %e, "failed to build sync runtime");
                    ctx.syncing.store(false, Ordering::SeqCst);
                    return;
                }
            };
            if let Err(e) = rt.block_on(run_full_sync(ctx)) {
                error!(error = %e, "catalog sync failed");
            }
        });
}

pub async fn run_full_sync(ctx: IngestContext) -> Result<()> {
    if ctx
        .syncing
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        info!("sync already in progress; skipping");
        let _ = slog(
            ctx.pool.clone(),
            "warn",
            "Idle",
            "Sync already in progress — skipped",
        )
        .await;
        return Ok(());
    }

    let _ = db::clear_sync_logs(ctx.pool.clone()).await;
    let _ = slog(ctx.pool.clone(), "info", "Starting", "Catalog sync started").await;

    let result = run_full_sync_inner(ctx.clone()).await;
    ctx.syncing.store(false, Ordering::SeqCst);

    match &result {
        Ok(()) => {
            let total = db::title_count(&ctx.pool).await.unwrap_or(0);
            let _ = sqlx::query(
                r#"
                UPDATE sync_state SET
                    last_sync_at = now(),
                    syncing = FALSE,
                    total_titles = $1,
                    last_error = NULL,
                    phase = 'Done',
                    progress_done = 100,
                    progress_total = 100,
                    workers_active = 0
                WHERE id = 1
                "#,
            )
            .bind(total as i32)
            .execute(&ctx.pool)
            .await;
            let _ = slog(
                ctx.pool.clone(),
                "info",
                "Done",
                format!("Sync finished — {total} titles in catalog"),
            )
            .await;
        }
        Err(e) => {
            error!(error = %e, "metadata sync failed");
            let _ = slog(
                ctx.pool.clone(),
                "error",
                "Failed",
                format!("Sync failed: {e}"),
            )
            .await;
            let _ = sqlx::query(
                r#"
                UPDATE sync_state SET
                    syncing = FALSE,
                    last_error = $1,
                    phase = NULL,
                    progress_done = 0,
                    progress_total = 0,
                    workers_active = 0
                WHERE id = 1
                "#,
            )
            .bind(e.to_string())
            .execute(&ctx.pool)
            .await;
        }
    }
    result
}

fn slog(
    pool: sqlx::PgPool,
    level: &str,
    phase: &str,
    message: impl Into<String>,
) -> impl std::future::Future<Output = Result<()>> + Send {
    let level = level.to_string();
    let phase = phase.to_string();
    let message = message.into();
    async move {
        match level.as_str() {
            "error" => error!(phase = %phase, "{message}"),
            "warn" => warn!(phase = %phase, "{message}"),
            _ => info!(phase = %phase, "{message}"),
        }
        db::append_sync_log(&pool, level, Some(phase), message).await
    }
}

async fn run_full_sync_inner(ctx: IngestContext) -> Result<()> {
    if ctx.config.tmdb_key().is_empty() {
        let msg = "No TMDB API key — add one in console Settings before syncing";
        let _ = slog(ctx.pool.clone(), "error", "Blocked", msg).await;
        let _ = sqlx::query(
            r#"
            UPDATE sync_state SET
                syncing = FALSE,
                last_error = $1,
                phase = 'Need TMDB key',
                progress_done = 0,
                progress_total = 0,
                workers_active = 0
            WHERE id = 1
            "#,
        )
        .bind(msg)
        .execute(&ctx.pool)
        .await;
        return Err(crate::error::AppError::Config(msg.into()));
    }

    info!("starting TMDB-only catalog sync (≤30 req/s)");
    let _ = sqlx::query("UPDATE sync_state SET syncing = TRUE, last_error = NULL WHERE id = 1")
        .execute(&ctx.pool)
        .await;
    let _ = db::set_sync_workers(&ctx.pool, crate::ingest::tmdb::sync_concurrency() as i32).await;
    let _ = db::set_sync_progress(&ctx.pool, "Starting", 0, 100).await;
    let _ = slog(
        ctx.pool.clone(),
        "info",
        "Starting",
        "TMDB-only sync · ≤30 req/s · up to 30 pages/list · deduped by TMDB id + kind",
    )
    .await;

    let _ = db::set_sync_progress(&ctx.pool, "TMDB catalog", 2, 100).await;
    if let Err(e) = tmdb::sync_catalog(&ctx).await {
        let _ = slog(
            ctx.pool.clone(),
            "error",
            "TMDB",
            format!("TMDB sync failed: {e}"),
        )
        .await;
        return Err(e);
    }
    let _ = slog(ctx.pool.clone(), "info", "TMDB", "TMDB catalog ingest finished").await;

    // Optional: upgrade any leftover YTS/TVMaze rows that only have IMDb ids.
    let _ = db::set_sync_progress(&ctx.pool, "TMDB · Link legacy", 90, 100).await;
    if let Err(e) = tmdb::enrich_missing_from_imdb(&ctx).await {
        warn!(error = %e, "legacy IMDb enrich failed (continuing)");
        let _ = slog(
            ctx.pool.clone(),
            "warn",
            "Legacy",
            format!("Legacy link failed: {e}"),
        )
        .await;
    }

    if !ctx.config.omdb_key().is_empty() {
        let _ = db::set_sync_progress(&ctx.pool, "OMDb polish", 93, 100).await;
        if let Err(e) = omdb::sync_catalog(&ctx).await {
            warn!(error = %e, "OMDb sync failed (continuing)");
            let _ = slog(
                ctx.pool.clone(),
                "warn",
                "OMDb",
                format!("OMDb polish failed: {e}"),
            )
            .await;
        }
    }

    let _ = db::set_sync_progress(&ctx.pool, "Search index", 96, 100).await;
    let _ = slog(ctx.pool.clone(), "info", "Search", "Rebuilding search index…").await;
    if let Err(e) = tmdb::reindex_all_titles(&ctx).await {
        warn!(error = %e, "batch search reindex failed (continuing)");
        let _ = slog(
            ctx.pool.clone(),
            "warn",
            "Search",
            format!("Search reindex failed: {e}"),
        )
        .await;
    } else {
        let _ = slog(ctx.pool.clone(), "info", "Search", "Search index updated").await;
    }

    let movies = db::title_count_for_kind(&ctx.pool, "movie").await.unwrap_or(0);
    let series = db::title_count_for_kind(&ctx.pool, "series").await.unwrap_or(0);
    let _ = slog(
        ctx.pool.clone(),
        "info",
        "Done",
        format!("Catalog ready — {movies} movies, {series} series"),
    )
    .await;

    let _ = db::set_sync_progress(&ctx.pool, "Done", 100, 100).await;
    let _ = db::set_sync_workers(&ctx.pool, 0).await;
    info!("metadata sync complete");
    Ok(())
}

/// Clear vote/popularity fields polluted by YTS download/like counts and
/// YTS “rating” written into imdb_rating without real IMDb vote support.
async fn scrub_fake_movie_votes(ctx: &IngestContext) -> Result<()> {
    // Any movie rating with no IMDb votes and no TMDB votes is not trustworthy
    // for Popular / Trending (almost always YTS noise).
    let res = sqlx::query(
        r#"
        UPDATE ratings r
        SET
            imdb_rating = NULL,
            imdb_votes = NULL,
            tmdb_vote_count = CASE
                WHEN r.tmdb_vote_average IS NULL THEN NULL
                ELSE r.tmdb_vote_count
            END,
            anilist_popularity = CASE
                WHEN r.anilist_score IS NULL THEN NULL
                ELSE r.anilist_popularity
            END
        FROM titles t
        WHERE r.title_id = t.id
          AND t.kind = 'movie'
          AND COALESCE(r.imdb_votes, 0) = 0
          AND COALESCE(r.tmdb_vote_count, 0) = 0
          AND (
            r.imdb_rating IS NOT NULL
            OR COALESCE(r.anilist_popularity, 0) > 0
          )
        "#,
    )
    .execute(&ctx.pool)
    .await?;
    if res.rows_affected() > 0 {
        info!(cleared = res.rows_affected(), "cleared untrusted movie ratings (no IMDb/TMDB votes)");
    }
    let res2 = sqlx::query(
        r#"
        UPDATE ratings r
        SET tmdb_vote_count = NULL
        FROM titles t
        WHERE r.title_id = t.id
          AND t.kind = 'series'
          AND t.tmdb_id IS NULL
          AND COALESCE(r.tmdb_vote_count, 0) > 0
        "#,
    )
    .execute(&ctx.pool)
    .await?;
    if res2.rows_affected() > 0 {
        info!(cleared = res2.rows_affected(), "cleared TVMaze weight from series vote counts");
    }
    Ok(())
}

/// Refresh one title from TMDB and drop cached Jackett listings.
pub async fn refresh_title(ctx: &IngestContext, id: Uuid) -> Result<()> {
    if ctx.config.tmdb_key().is_empty() {
        return Err(crate::error::AppError::Config(
            "TMDB API key required — add it in console Settings".into(),
        ));
    }

    let row: Option<(Option<i32>, String, String, Option<i32>)> = sqlx::query_as(
        "SELECT tmdb_id, kind, title, year FROM titles WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&ctx.pool)
    .await?;
    let Some((tmdb_id, kind, title, year)) = row else {
        return Err(crate::error::AppError::NotFound("title not found".into()));
    };

    if let Some(tmdb_id) = tmdb_id {
        let media = if kind == "movie" { "movie" } else { "series" };
        tmdb::fetch_details(ctx, tmdb_id, media).await?;
    } else {
        // Resolve + pull English art / seasons for legacy rows.
        let _ = tmdb::ensure_title_enriched(ctx, id).await?;
        let _ = (title, year);
    }

    sqlx::query("DELETE FROM jackett_listings WHERE title_id = $1")
        .bind(id)
        .execute(&ctx.pool)
        .await?;
    crate::db::stream_search_cache_delete_title(&ctx.pool, id).await?;
    Ok(())
}

pub async fn refresh_stale(ctx: &IngestContext) -> Result<()> {
    if !ctx.config.tmdb_key().is_empty() {
        info!("refreshing stale titles (updated_at older than 7 days)");
        if let Err(e) = tmdb::refresh_stale_titles(ctx).await {
            warn!(error = %e, "TMDB stale refresh failed");
        }
    }
    Ok(())
}

pub async fn throttle() {
    // Keep a tiny yield so we don't starve the HTTP client under max workers.
    tokio::task::yield_now().await;
}
