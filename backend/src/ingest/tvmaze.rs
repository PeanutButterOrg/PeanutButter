use serde::Deserialize;
use tracing::{info, warn};

use super::{throttle, IngestContext};
use crate::error::Result;
use crate::ingest::tmdb::{reindex, replace_genre_names, upsert_ratings, upsert_title};

#[derive(Debug, Deserialize)]
struct TvMazeShow {
    name: String,
    genres: Option<Vec<String>>,
    premiered: Option<String>,
    runtime: Option<i32>,
    summary: Option<String>,
    image: Option<TvMazeImage>,
    externals: Option<TvMazeExternals>,
    rating: Option<TvMazeRating>,
    weight: Option<i32>,
}

#[derive(Debug, Deserialize)]
struct TvMazeImage {
    original: Option<String>,
    medium: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TvMazeExternals {
    imdb: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TvMazeRating {
    average: Option<f64>,
}

/// TVMaze is free, needs no API key, and is used for Series when OMDb/TMDB are absent.
pub async fn sync_shows(ctx: &IngestContext) -> Result<()> {
    info!("fetching series from TVMaze");
    for page in 0..4 {
        let url = format!("https://api.tvmaze.com/shows?page={page}");
        let shows: Vec<TvMazeShow> = match ctx.http.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => resp.json().await?,
            Ok(resp) => {
                warn!(page, status = %resp.status(), "TVMaze page skipped");
                break;
            }
            Err(e) => {
                warn!(page, error = %e, "TVMaze page failed");
                break;
            }
        };
        if shows.is_empty() {
            break;
        }
        for show in shows {
            if let Err(e) = upsert_show(ctx, show).await {
                warn!(error = %e, "TVMaze upsert failed");
            }
        }
        throttle().await;
    }
    Ok(())
}

async fn upsert_show(ctx: &IngestContext, show: TvMazeShow) -> Result<()> {
    let imdb = show
        .externals
        .as_ref()
        .and_then(|e| e.imdb.clone())
        .filter(|s| !s.is_empty());
    if let Some(imdb_id) = imdb.as_deref() {
        let existing_kind: Option<(String,)> =
            sqlx::query_as("SELECT kind FROM titles WHERE imdb_id = $1")
                .bind(imdb_id)
                .fetch_optional(&ctx.pool)
                .await?;
        if existing_kind.as_ref().map(|r| r.0.as_str()) == Some("anime") {
            return Ok(());
        }
    }

    let plot = show.summary.as_deref().map(strip_html);
    let poster = show
        .image
        .as_ref()
        .and_then(|img| img.original.clone().or_else(|| img.medium.clone()));
    let year = show
        .premiered
        .as_deref()
        .and_then(|d| d.get(..4))
        .and_then(|y| y.parse().ok());
    let id = upsert_title(
        ctx,
        "series",
        &show.name,
        None,
        plot.as_deref(),
        plot.as_deref(),
        year,
        show.runtime,
        poster.as_deref(),
        None,
        None,
        imdb.as_deref(),
        None,
        None,
    )
    .await?;
    replace_genre_names(ctx, id, &show.genres.unwrap_or_default()).await?;
    upsert_ratings(
        ctx,
        id,
        show.rating.and_then(|r| r.average),
        show.weight,
        None,
        None,
        None,
        None,
        None,
    )
    .await?;
    reindex(ctx, id).await?;
    Ok(())
}

fn strip_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_tag = false;
    for c in input.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&nbsp;", " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
