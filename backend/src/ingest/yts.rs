use serde::Deserialize;
use tracing::{info, warn};

use super::{throttle, IngestContext};
use crate::error::Result;
use crate::ingest::tmdb::{reindex, replace_genre_names, upsert_ratings, upsert_title};

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
    like_count: Option<i32>,
    download_count: Option<i32>,
    date_uploaded_unix: Option<i64>,
}

/// Butter / Popcorn Time used this public movie list for catalog size.
/// Only title metadata is stored — never torrents or magnets.
pub async fn sync_movies(ctx: &IngestContext) -> Result<()> {
    info!("fetching Butter-style movie catalog");
    let mut ingested = 0usize;
    for (sort, pages) in [
        ("year", 12usize),
        ("download_count", 20usize),
        ("date_added", 12usize),
    ] {
        for page in 1..=pages {
            match fetch_page(ctx, sort, page).await {
                Ok(movies) => {
                    if movies.is_empty() {
                        break;
                    }
                    for movie in movies {
                        match upsert_movie(ctx, movie).await {
                            Ok(true) => ingested += 1,
                            Ok(false) => {}
                            Err(e) => warn!(error = %e, "movie upsert failed"),
                        }
                    }
                }
                Err(e) => {
                    warn!(sort, page, error = %e, "movie list page failed");
                    break;
                }
            }
            throttle().await;
        }
    }
    info!(ingested, "Butter-style movie catalog sync finished");
    Ok(())
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
    )
    .await?;
    if let Some(genres) = movie.genres.filter(|g| !g.is_empty()) {
        replace_genre_names(ctx, id, &genres).await?;
    }
    let rating = movie.rating.filter(|n| *n > 0.0);
    let votes = movie.download_count.filter(|n| *n > 0);
    upsert_ratings(
        ctx,
        id,
        None,
        votes.or(movie.like_count),
        rating,
        votes,
        None,
        movie.like_count,
        None,
    )
    .await?;
    if let Some(unix) = movie.date_uploaded_unix.filter(|n| *n > 0) {
        sqlx::query("UPDATE titles SET created_at = to_timestamp($1) WHERE id = $2")
            .bind(unix as f64)
            .bind(id)
            .execute(&ctx.pool)
            .await?;
    }
    reindex(ctx, id).await?;
    Ok(true)
}
