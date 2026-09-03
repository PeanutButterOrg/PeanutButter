use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

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

pub async fn run_full_sync(ctx: &IngestContext) -> Result<()> {
    if ctx
        .syncing
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        info!("sync already in progress; skipping");
        return Ok(());
    }

    let result = run_full_sync_inner(ctx).await;
    ctx.syncing.store(false, Ordering::SeqCst);

    match &result {
        Ok(()) => {
            let total = db::title_count(&ctx.pool).await.unwrap_or(0);
            let _ = sqlx::query(
                "UPDATE sync_state SET last_sync_at = now(), syncing = FALSE, total_titles = $1, last_error = NULL WHERE id = 1",
            )
            .bind(total as i32)
            .execute(&ctx.pool)
            .await;
        }
        Err(e) => {
            error!(error = %e, "metadata sync failed");
            let _ = sqlx::query(
                "UPDATE sync_state SET syncing = FALSE, last_error = $1 WHERE id = 1",
            )
            .bind(e.to_string())
            .execute(&ctx.pool)
            .await;
        }
    }
    result
}

async fn run_full_sync_inner(ctx: &IngestContext) -> Result<()> {
    info!("starting metadata sync");
    let _ = sqlx::query("UPDATE sync_state SET syncing = TRUE WHERE id = 1")
        .execute(&ctx.pool)
        .await;

    match yts::sync_movies(ctx).await {
        Ok(()) => {}
        Err(e) => warn!(error = %e, "movie catalog sync failed (continuing)"),
    }

    match tvmaze::sync_shows(ctx).await {
        Ok(()) => {}
        Err(e) => warn!(error = %e, "TVMaze sync failed (continuing)"),
    }

    if ctx.config.omdb_key().is_empty() {
        warn!("OMDB_API_KEY is empty; skipping OMDb movie ingest");
    } else {
        omdb::sync_catalog(ctx).await?;
    }

    if ctx.config.tmdb_key().is_empty() {
        warn!("TMDB_API_KEY is empty; skipping optional TMDB ingest");
    } else {
        tmdb::sync_catalog(ctx).await?;
    }

    match anilist::sync_trending(ctx).await {
        Ok(()) => {}
        Err(e) => warn!(error = %e, "AniList sync failed (continuing)"),
    }

    match anilist::fill_missing_people(ctx).await {
        Ok(()) => {}
        Err(e) => warn!(error = %e, "AniList people backfill failed (continuing)"),
    }

    info!("metadata sync complete");
    Ok(())
}

/// Refresh one title from TMDB or AniList and drop cached Jackett listings.
pub async fn refresh_title(ctx: &IngestContext, id: Uuid) -> Result<()> {
    let row: Option<(Option<i32>, Option<i32>, String)> = sqlx::query_as(
        "SELECT tmdb_id, anilist_id, kind FROM titles WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&ctx.pool)
    .await?;
    let Some((tmdb_id, anilist_id, kind)) = row else {
        return Err(crate::error::AppError::NotFound("title not found".into()));
    };

    if let Some(tmdb_id) = tmdb_id {
        if !ctx.config.tmdb_key().is_empty() {
            let tmdb_kind = if kind == "movie" { "movie" } else { "series" };
            tmdb::fetch_details(ctx, tmdb_id, tmdb_kind).await?;
        }
    }
    if let Some(anilist_id) = anilist_id {
        anilist::refresh_by_id(ctx, anilist_id).await?;
    }

    sqlx::query("DELETE FROM jackett_listings WHERE title_id = $1")
        .bind(id)
        .execute(&ctx.pool)
        .await?;
    Ok(())
}

pub async fn refresh_stale(ctx: &IngestContext) -> Result<()> {
    if !ctx.config.tmdb_key().is_empty() {
        info!("refreshing stale titles (updated_at older than 7 days)");
        if let Err(e) = tmdb::refresh_stale_titles(ctx).await {
            warn!(error = %e, "TMDB stale refresh failed");
        }
    }
    if let Err(e) = anilist::fill_missing_people(ctx).await {
        warn!(error = %e, "AniList people backfill failed");
    }
    Ok(())
}

pub async fn throttle() {
    tokio::time::sleep(Duration::from_millis(260)).await;
}
