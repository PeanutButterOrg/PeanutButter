//! "Notify me" for series: each device record can follow a series, and gets an
//! alert for every episode that airs after it followed. Followed series are
//! refreshed from TMDB every few hours so new episodes show up; apps fetch the
//! alerts, show a notification and mark them delivered.

use sqlx::PgPool;
use tracing::{info, warn};
use uuid::Uuid;

use crate::error::Result;
use crate::ingest::IngestContext;

pub async fn set_follow(pool: &PgPool, token_id: Uuid, title_id: Uuid, follow: bool) -> Result<()> {
    if follow {
        sqlx::query(
            "INSERT INTO title_follows (token_id, title_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(token_id)
        .bind(title_id)
        .execute(pool)
        .await?;
    } else {
        sqlx::query("DELETE FROM title_follows WHERE token_id = $1 AND title_id = $2")
            .bind(token_id)
            .bind(title_id)
            .execute(pool)
            .await?;
        // Unfollowing also drops what hasn't been shown yet.
        sqlx::query(
            "DELETE FROM episode_alerts WHERE token_id = $1 AND title_id = $2 AND delivered_at IS NULL",
        )
        .bind(token_id)
        .bind(title_id)
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn is_following(pool: &PgPool, token_id: Uuid, title_id: Uuid) -> Result<bool> {
    Ok(sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM title_follows WHERE token_id = $1 AND title_id = $2)",
    )
    .bind(token_id)
    .bind(title_id)
    .fetch_one(pool)
    .await?)
}

/// An alert for every regular-season episode of a followed series that has
/// aired, and aired after the day it was followed. Returns how many are new.
pub async fn record_new_episodes(pool: &PgPool) -> Result<u64> {
    let done = sqlx::query(
        r#"
        INSERT INTO episode_alerts (token_id, episode_id, title_id)
        SELECT f.token_id, e.id, f.title_id
        FROM title_follows f
        JOIN seasons s ON s.title_id = f.title_id AND s.season_number > 0
        JOIN episodes e ON e.season_id = s.id
        WHERE e.air_date IS NOT NULL
          AND e.air_date <= CURRENT_DATE
          AND e.air_date > (f.created_at AT TIME ZONE 'UTC')::date
        ON CONFLICT DO NOTHING
        "#,
    )
    .execute(pool)
    .await?;
    Ok(done.rows_affected())
}

/// Refresh followed series from TMDB (new episodes only appear after a
/// refresh), then record alerts. Run by the scheduler every few hours.
pub async fn check(ctx: &IngestContext) -> Result<()> {
    let followed: Vec<(Uuid, i32)> = sqlx::query_as(
        r#"
        SELECT DISTINCT t.id, t.tmdb_id FROM title_follows f
        JOIN titles t ON t.id = f.title_id
        WHERE t.tmdb_id IS NOT NULL AND t.kind <> 'movie'
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;
    for (id, tmdb_id) in &followed {
        if let Err(e) = crate::ingest::tmdb::fetch_details_explicit(ctx, *tmdb_id, "series").await {
            warn!(%id, tmdb_id, error = %e, "followed series refresh failed");
        }
    }
    let new = record_new_episodes(&ctx.pool).await?;
    info!(followed = followed.len(), new_alerts = new, "checked followed series for new episodes");
    Ok(())
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct AlertRow {
    pub episode_id: Uuid,
    pub title_id: Uuid,
    pub title: String,
    pub poster_path: Option<String>,
    pub season_number: i32,
    pub episode_number: i32,
    pub episode_name: Option<String>,
    pub air_date: Option<chrono::NaiveDate>,
}

/// Alerts this device hasn't shown yet, oldest first.
pub async fn pending(pool: &PgPool, token_id: Uuid) -> Result<Vec<AlertRow>> {
    Ok(sqlx::query_as(
        r#"
        SELECT a.episode_id, a.title_id, t.title, t.poster_path,
               s.season_number, e.episode_number, e.name AS episode_name, e.air_date
        FROM episode_alerts a
        JOIN titles t ON t.id = a.title_id
        JOIN episodes e ON e.id = a.episode_id
        JOIN seasons s ON s.id = e.season_id
        WHERE a.token_id = $1 AND a.delivered_at IS NULL
        ORDER BY e.air_date ASC NULLS LAST, s.season_number, e.episode_number
        LIMIT 50
        "#,
    )
    .bind(token_id)
    .fetch_all(pool)
    .await?)
}

pub async fn mark_delivered(pool: &PgPool, token_id: Uuid, episode_ids: &[Uuid]) -> Result<u64> {
    let done = sqlx::query(
        "UPDATE episode_alerts SET delivered_at = now() \
         WHERE token_id = $1 AND episode_id = ANY($2) AND delivered_at IS NULL",
    )
    .bind(token_id)
    .bind(episode_ids)
    .execute(pool)
    .await?;
    Ok(done.rows_affected())
}
