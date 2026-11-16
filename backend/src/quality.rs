//! Which movies have an HD copy yet, for the home "Now in HD" row: new
//! releases whose first proper copy turned up, instead of cinema recordings.
//!
//! A verdict sums up an ordinary source search (Jackett and every enabled
//! add-on, ranked the usual way, which only keeps 720p, 1080p and 4K copies
//! and never CAM / telesync / screener):
//! - **ready**: at least one copy that can play (a direct link, or a torrent
//!   not known to be dead);
//! - **none**: nothing usable yet.
//!
//! Verdicts come from two places: the background check below (favourites,
//! titles being watched, and movies released in the last six months), and
//! every time someone opens a movie's sources in an app. A search where every
//! source failed or timed out never overwrites a verdict.

use std::sync::atomic::{AtomicBool, Ordering};

use futures::stream::{self, StreamExt};
use sqlx::PgPool;
use tracing::{info, warn};
use uuid::Uuid;

use crate::error::Result;
use crate::graphql::types::StreamSource;
use crate::ingest::IngestContext;
use crate::sources::rank::detect_resolution;

/// Titles one background run checks; runs every 30 minutes.
const BATCH: i64 = 40;
/// Searches at once. Each one already asks every source in parallel.
const CONCURRENCY: usize = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Ready,
    None,
}

impl Status {
    pub fn as_db(self) -> &'static str {
        match self {
            Status::Ready => "ready",
            Status::None => "none",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub status: Status,
    /// Best resolution among playable copies (2160 / 1080 / 720).
    pub best_resolution: Option<u32>,
    /// Playable HD copies.
    pub good_sources: i32,
}

/// Sums up a ranked source list (already HD only, see `sources::rank`).
pub fn verdict(ranked: &[StreamSource]) -> Verdict {
    let playable: Vec<&StreamSource> = ranked.iter().filter(|s| s.is_http() || s.health != "dead").collect();
    let best_resolution = playable.iter().filter_map(|s| detect_resolution(&s.title)).max();
    let good_sources = playable.len() as i32;
    let status = if good_sources > 0 { Status::Ready } else { Status::None };
    Verdict { status, best_resolution, good_sources }
}

/// A saved verdict, as the tests read it back.
#[cfg(test)]
#[derive(Clone, Debug, sqlx::FromRow)]
struct QualityRow {
    status: String,
    best_resolution: Option<i32>,
    good_since: Option<chrono::DateTime<chrono::Utc>>,
}

/// Saves a verdict. `good_since` is when a title first became ready, and is
/// kept while it stays ready.
pub async fn record(pool: &PgPool, title_id: Uuid, v: Verdict) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO title_quality (title_id, status, best_resolution, good_sources, checked_at, good_since)
        VALUES ($1, $2, $3, $4, now(), CASE WHEN $2 = 'ready' THEN now() END)
        ON CONFLICT (title_id) DO UPDATE SET
            status = EXCLUDED.status,
            best_resolution = EXCLUDED.best_resolution,
            good_sources = EXCLUDED.good_sources,
            checked_at = now(),
            good_since = CASE
                WHEN EXCLUDED.status <> 'ready' THEN NULL
                WHEN title_quality.status = 'ready' THEN title_quality.good_since
                ELSE now()
            END
        "#,
    )
    .bind(title_id)
    .bind(v.status.as_db())
    .bind(v.best_resolution.map(|r| r as i32))
    .bind(v.good_sources)
    .execute(pool)
    .await?;
    Ok(())
}

#[cfg(test)]
async fn get(pool: &PgPool, title_id: Uuid) -> Result<Option<QualityRow>> {
    Ok(sqlx::query_as(
        "SELECT status, best_resolution, good_since FROM title_quality WHERE title_id = $1",
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?)
}

/// Movies due a check: favourites and titles being watched (any device), and
/// movies released in the last six months. Without a good copy they're
/// rechecked every 4 hours, with one weekly. Never-checked titles first.
async fn due(pool: &PgPool, limit: i64) -> Result<Vec<Uuid>> {
    Ok(sqlx::query_scalar(
        r#"
        SELECT t.id
        FROM titles t
        LEFT JOIN title_quality q ON q.title_id = t.id
        WHERE t.kind = 'movie'
          AND t.imdb_id IS NOT NULL AND t.imdb_id <> ''
          AND (t.released_at IS NULL OR t.released_at <= CURRENT_DATE)
          AND (t.year IS NULL OR t.year <= EXTRACT(YEAR FROM CURRENT_DATE)::int)
          AND (
                EXISTS (
                    SELECT 1 FROM user_progress p
                    WHERE p.title_id = t.id AND (p.favorite OR (NOT p.watched AND p.position_ms > 2000))
                )
                OR t.released_at >= CURRENT_DATE - INTERVAL '180 days'
          )
          AND (
                q.title_id IS NULL
                OR (q.status <> 'ready' AND q.checked_at < now() - INTERVAL '4 hours')
                OR (q.status = 'ready' AND q.checked_at < now() - INTERVAL '7 days')
          )
        ORDER BY q.checked_at ASC NULLS FIRST, t.released_at DESC NULLS LAST
        LIMIT $1
        "#,
    )
    .bind(limit)
    .fetch_all(pool)
    .await?)
}

/// One movie: search every source the way the apps do and save the verdict.
/// Returns None when no source answered (nothing saved).
pub async fn check_title(ctx: &IngestContext, title_id: Uuid) -> Result<Option<Verdict>> {
    let target = crate::sources::target_for_title(&ctx.pool, Some(title_id), "", None).await;
    if target.title.trim().is_empty() {
        return Ok(None);
    }
    let query = crate::sources::SourceQuery {
        target,
        kind: "movie".into(),
        languages: ctx.config.live.preferred_languages(),
        resolution: "1080p".into(),
        ..Default::default()
    };
    let mut providers: Vec<Box<dyn crate::sources::SourceProvider>> = Vec::new();
    if let Some(j) = crate::jackett::JackettSource::from_live(&ctx.http, &ctx.config.live) {
        providers.push(Box::new(j));
    }
    if query.stremio_id().is_some() {
        providers.extend(crate::providers::enabled_sources(&ctx.http));
    }
    if providers.is_empty() {
        return Ok(None);
    }
    let (lists, reports) = crate::sources::gather(&providers, &query).await;
    if !reports.iter().any(|r| matches!(r.outcome, crate::sources::Outcome::Found(_))) {
        return Ok(None);
    }
    let merged = crate::sources::collapse_mirrors(
        crate::sources::check_links(&ctx.http, crate::sources::merge(lists)).await,
    );
    let ranked = crate::sources::rank::rank(merged, &crate::sources::prefs(&query));
    let v = verdict(&ranked);
    record(&ctx.pool, title_id, v).await?;
    Ok(Some(v))
}

/// The background check (every 30 minutes). Skipped when no source is set up.
pub async fn run(ctx: &IngestContext) -> Result<()> {
    static RUNNING: AtomicBool = AtomicBool::new(false);
    if crate::jackett::JackettSource::from_live(&ctx.http, &ctx.config.live).is_none() && !crate::providers::active() {
        return Ok(());
    }
    if RUNNING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let result = async {
        let ids = due(&ctx.pool, BATCH).await?;
        if ids.is_empty() {
            return Ok(());
        }
        let total = ids.len();
        let ready = stream::iter(ids)
            .map(|id| async move {
                match check_title(ctx, id).await {
                    Ok(v) => v.is_some_and(|v| v.status == Status::Ready),
                    Err(e) => {
                        warn!(title_id = %id, error = %e, "quality check failed");
                        false
                    }
                }
            })
            .buffer_unordered(CONCURRENCY)
            .filter(|ready| futures::future::ready(*ready))
            .count()
            .await;
        info!(checked = total, ready, "release quality check");
        Ok(())
    }
    .await;
    RUNNING.store(false, Ordering::SeqCst);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(title: &str, health: &str) -> StreamSource {
        let mut s = crate::jackett::external_source(
            title,
            "0123456789abcdef0123456789abcdef01234567",
            &[],
            Some(10),
            2_000_000_000,
            "T",
            "movie",
            "",
        )
        .expect("valid");
        s.health = health.into();
        s
    }

    #[test]
    fn any_playable_hd_copy_is_ready() {
        let ranked = crate::sources::rank::rank(
            vec![src("Film.2025.2160p.WEB-DL", "healthy"), src("Film.2025.1080p.WEB-DL", "healthy"), src("Film.2025.480p.WEB", "healthy")],
            &crate::sources::rank::RankPrefs { resolution: "1080p", languages: "", kind: "movie" },
        );
        let v = verdict(&ranked);
        assert_eq!(v, Verdict { status: Status::Ready, best_resolution: Some(2160), good_sources: 2 });
    }

    #[test]
    fn dead_torrents_dont_count() {
        let v = verdict(&[src("Film.2025.1080p.WEB-DL", "dead")]);
        assert_eq!(v, Verdict { status: Status::None, best_resolution: None, good_sources: 0 });
        assert_eq!(verdict(&[]).status, Status::None);
    }

    /// Against a scratch database with the migrations applied:
    /// `PB_TEST_DATABASE_URL=postgres://… cargo test quality -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn verdicts_round_trip_in_postgres() {
        let url = std::env::var("PB_TEST_DATABASE_URL").expect("PB_TEST_DATABASE_URL");
        let pool = PgPool::connect(&url).await.unwrap();
        let fav = Uuid::new_v4();
        let new_movie = Uuid::new_v4();
        let old_movie = Uuid::new_v4();
        for (id, imdb, released) in [
            (fav, "tt9000001", "2001-01-01"),
            (new_movie, "tt9000002", "today"),
            (old_movie, "tt9000003", "2001-01-01"),
        ] {
            sqlx::query(
                "INSERT INTO titles (id, kind, title, imdb_id, released_at) VALUES ($1, 'movie', 'T', $2, \
                 CASE WHEN $3 = 'today' THEN CURRENT_DATE - 10 ELSE $3::date END)",
            )
            .bind(id)
            .bind(imdb)
            .bind(released)
            .execute(&pool)
            .await
            .unwrap();
        }
        sqlx::query("INSERT INTO user_progress (title_id, favorite) VALUES ($1, TRUE)")
            .bind(fav)
            .execute(&pool)
            .await
            .unwrap();
        // Favourite and new release are due; an old movie nobody follows isn't.
        let due_now = due(&pool, 100).await.unwrap();
        assert!(due_now.contains(&fav) && due_now.contains(&new_movie), "{due_now:?}");
        assert!(!due_now.contains(&old_movie));

        let low = Verdict { status: Status::None, best_resolution: None, good_sources: 0 };
        let ready = Verdict { status: Status::Ready, best_resolution: Some(1080), good_sources: 3 };
        record(&pool, new_movie, low).await.unwrap();
        assert!(get(&pool, new_movie).await.unwrap().unwrap().good_since.is_none());
        record(&pool, new_movie, ready).await.unwrap();
        let first = get(&pool, new_movie).await.unwrap().unwrap();
        assert_eq!(first.status, "ready");
        assert_eq!(first.best_resolution, Some(1080));
        let since = first.good_since.expect("set when it became ready");
        // Staying ready keeps the date it first became ready.
        record(&pool, new_movie, ready).await.unwrap();
        assert_eq!(get(&pool, new_movie).await.unwrap().unwrap().good_since, Some(since));
        // Just checked: not due again.
        assert!(!due(&pool, 100).await.unwrap().contains(&new_movie));
        sqlx::query("DELETE FROM titles WHERE id = ANY($1)")
            .bind(vec![fav, new_movie, old_movie])
            .execute(&pool)
            .await
            .unwrap();
    }
}
