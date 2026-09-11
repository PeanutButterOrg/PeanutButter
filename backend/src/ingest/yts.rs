use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde::Deserialize;
use tracing::{info, warn};

use super::{sync_workers, throttle, IngestContext};
use crate::error::Result;
use crate::ingest::tmdb::{
    apply_content_rating, replace_genre_names, upsert_ratings, upsert_title,
};

const YTS_ENDPOINTS: &[&str] = &[
    "https://yts.mx/api/v2/list_movies.json",
    "https://yts.lt/api/v2/list_movies.json",
];

#[derive(Debug, Deserialize)]
struct YtsResponse {
    data: Option<YtsData>,
}

#[derive(Debug, Deserialize)]
struct YtsData {
    movies: Option<Vec<YtsMovie>>,
}

#[derive(Debug, Deserialize)]
struct YtsMovie {
    imdb_code: Option<String>,
    title: Option<String>,
    year: Option<i32>,
    rating: Option<f64>,
    runtime: Option<i32>,
    genres: Option<Vec<String>>,
    synopsis: Option<String>,
    description_full: Option<String>,
    large_cover_image: Option<String>,
    medium_cover_image: Option<String>,
    mpa_rating: Option<String>,
    yt_trailer_code: Option<String>,
    date_uploaded_unix: Option<i64>,
}

/// Butter / Popcorn Time used this public movie list for catalog size.
/// Only title metadata is stored — never torrents or magnets.
pub async fn sync_movies(ctx: &IngestContext) -> Result<()> {
    let workers = sync_workers();
    info!(workers, "fetching Butter-style movie catalog");
    let work: Vec<(String, usize)> = [
        ("year", 12usize),
        ("download_count", 20usize),
        ("date_added", 12usize),
    ]
    .into_iter()
    .flat_map(|(sort, pages)| (1..=pages).map(move |page| (sort.to_string(), page)))
    .collect();

    let total_pages = work.len();
    let done_pages = Arc::new(AtomicUsize::new(0));
    let ingested = Arc::new(AtomicUsize::new(0));
    let mut set = tokio::task::JoinSet::new();
    let mut pending = work.into_iter();

    while set.len() < workers {
        let Some((sort, page)) = pending.next() else {
            break;
        };
        spawn_yts_page(&mut set, ctx.clone(), sort, page, done_pages.clone(), ingested.clone());
    }
    while set.join_next().await.is_some() {
        let finished = done_pages.load(Ordering::Relaxed);
        let _ = crate::db::set_sync_progress(
            &ctx.pool,
            &format!("Movies · YTS ({finished}/{total_pages})"),
            // Keep overall bar moving within the movies band without fighting other workers.
            ((finished as f64 / total_pages.max(1) as f64) * 40.0) as i32 + 2,
            100,
        )
        .await;
        if let Some((sort, page)) = pending.next() {
            spawn_yts_page(
                &mut set,
                ctx.clone(),
                sort,
                page,
                done_pages.clone(),
                ingested.clone(),
            );
        }
    }

    info!(
        ingested = ingested.load(Ordering::Relaxed),
        "Butter-style movie catalog sync finished"
    );
    Ok(())
}

fn spawn_yts_page(
    set: &mut tokio::task::JoinSet<()>,
    ctx: IngestContext,
    sort: String,
    page: usize,
    done_pages: Arc<AtomicUsize>,
    ingested: Arc<AtomicUsize>,
) {
    set.spawn(async move {
        match fetch_page(&ctx, &sort, page).await {
            Ok(movies) => {
                // Upsert titles on the page concurrently (was sequential and slow).
                let mut inner = tokio::task::JoinSet::new();
                let mut pending = movies.into_iter();
                const PAGE_WORKERS: usize = 12;
                while inner.len() < PAGE_WORKERS {
                    let Some(movie) = pending.next() else { break };
                    let c = ctx.clone();
                    let ingested = ingested.clone();
                    inner.spawn(async move {
                        match upsert_movie(&c, movie).await {
                            Ok(true) => {
                                ingested.fetch_add(1, Ordering::Relaxed);
                            }
                            Ok(false) => {}
                            Err(e) => warn!(error = %e, "movie upsert failed"),
                        }
                    });
                }
                while inner.join_next().await.is_some() {
                    if let Some(movie) = pending.next() {
                        let c = ctx.clone();
                        let ingested = ingested.clone();
                        inner.spawn(async move {
                            match upsert_movie(&c, movie).await {
                                Ok(true) => {
                                    ingested.fetch_add(1, Ordering::Relaxed);
                                }
                                Ok(false) => {}
                                Err(e) => warn!(error = %e, "movie upsert failed"),
                            }
                        });
                    }
                }
            }
            Err(e) => warn!(sort = %sort, page, error = %e, "movie list page failed"),
        }
        let finished = done_pages.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = crate::db::append_sync_log(
            &ctx.pool,
            "info",
            Some("Movies".into()),
            format!("YTS page done ({finished}) · {sort} p{page}"),
        )
        .await;
        throttle().await;
    });
}

async fn fetch_page(ctx: &IngestContext, sort: &str, page: usize) -> Result<Vec<YtsMovie>> {
    let mut last_err = None;
    for base in YTS_ENDPOINTS {
        let url = format!("{base}?limit=50&page={page}&sort_by={sort}&order_by=desc");
        match ctx
            .http
            .get(&url)
            .header(
                "User-Agent",
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 catalog/1.0",
            )
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                let parsed: YtsResponse = resp.json().await?;
                return Ok(parsed.data.and_then(|d| d.movies).unwrap_or_default());
            }
            Ok(resp) => {
                last_err = Some(format!("HTTP {}", resp.status()));
            }
            Err(e) => last_err = Some(e.to_string()),
        }
    }
    Err(crate::error::AppError::Provider(
        last_err.unwrap_or_else(|| "movie list unavailable".into()),
    ))
}

async fn upsert_movie(ctx: &IngestContext, movie: YtsMovie) -> Result<bool> {
    let Some(title) = movie.title.filter(|s| !s.is_empty()) else {
        return Ok(false);
    };
    let imdb = movie
        .imdb_code
        .filter(|s| s.starts_with("tt") || s.chars().all(|c| c.is_ascii_digit()));
    let plot = movie
        .synopsis
        .or(movie.description_full)
        .filter(|s| !s.is_empty());
    let poster = movie
        .large_cover_image
        .or(movie.medium_cover_image)
        .filter(|s| !s.is_empty());
    let id = upsert_title(
        ctx,
        "movie",
        &title,
        None,
        plot.as_deref(),
        plot.as_deref(),
        movie.year.filter(|y| *y > 0),
        movie.runtime.filter(|n| *n > 0),
        poster.as_deref(),
        None,
        None,
        imdb.as_deref(),
        None,
        None,
        None,
    )
    .await?;
    if let Some(genres) = movie.genres.filter(|g| !g.is_empty()) {
        replace_genre_names(ctx, id, &genres).await?;
    }
    // Free catalog score (same pattern as TVMaze). Never write into imdb_rating —
    // that column is reserved for real OMDb IMDb scores.
    let rating = movie.rating.filter(|n| *n > 0.0 && *n <= 10.0);
    upsert_ratings(ctx, id, rating, None, None, None, None, None, None, None).await?;
    if let Some(mpa) = movie
        .mpa_rating
        .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("null"))
    {
        apply_content_rating(ctx, id, Some(mpa)).await?;
    }
    if let Some(key) = movie
        .yt_trailer_code
        .filter(|s| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'))
    {
        ensure_single_youtube_trailer(ctx, id, &key, &format!("{title} Trailer")).await?;
    }
    if let Some(unix) = movie.date_uploaded_unix.filter(|n| *n > 0) {
        sqlx::query("UPDATE titles SET created_at = to_timestamp($1) WHERE id = $2")
            .bind(unix as f64)
            .bind(id)
            .execute(&ctx.pool)
            .await?;
    }
    // Search index is rebuilt in a fast batch at the end of sync (not per title).
    Ok(true)
}

/// Keep exactly one trailer when the free YTS YouTube id is the only source.
async fn ensure_single_youtube_trailer(
    ctx: &IngestContext,
    title_id: uuid::Uuid,
    youtube_key: &str,
    name: &str,
) -> Result<()> {
    let existing: Option<(i64,)> =
        sqlx::query_as("SELECT COUNT(*) FROM trailers WHERE title_id = $1")
            .bind(title_id)
            .fetch_optional(&ctx.pool)
            .await?;
    if existing.map(|r| r.0).unwrap_or(0) > 0 {
        return Ok(());
    }
    sqlx::query(
        r#"
        INSERT INTO trailers (title_id, name, youtube_key, site, size)
        VALUES ($1, $2, $3, 'YouTube', 1080)
        ON CONFLICT (title_id, youtube_key) DO NOTHING
        "#,
    )
    .bind(title_id)
    .bind(name)
    .bind(youtube_key)
    .execute(&ctx.pool)
    .await?;
    Ok(())
}
