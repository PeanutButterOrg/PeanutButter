use serde::Deserialize;
use tracing::{info, warn};
use uuid::Uuid;

use super::{throttle, IngestContext};
use crate::error::Result;
use crate::ingest::tmdb::{
    replace_credit_people, replace_genre_names, upsert_ratings, upsert_title, CreditPerson,
};

#[derive(Debug, Deserialize)]
struct TvMazeShow {
    id: i32,
    name: String,
    genres: Option<Vec<String>>,
    premiered: Option<String>,
    runtime: Option<i32>,
    summary: Option<String>,
    image: Option<TvMazeImage>,
    externals: Option<TvMazeExternals>,
    rating: Option<TvMazeRating>,
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

#[derive(Debug, Deserialize)]
struct TvMazeCastCredit {
    person: Option<TvMazePerson>,
    character: Option<TvMazeCharacter>,
}

#[derive(Debug, Deserialize)]
struct TvMazePerson {
    name: Option<String>,
    image: Option<TvMazeImage>,
}

#[derive(Debug, Deserialize)]
struct TvMazeCharacter {
    name: Option<String>,
}

/// TVMaze is free, needs no API key, and is used for Series when OMDb/TMDB are absent.
pub async fn sync_shows(ctx: &IngestContext) -> Result<()> {
    let workers = super::sync_workers();
    info!(workers, "fetching series from TVMaze");
    let pages: Vec<usize> = (0..4).collect();
    let mut set = tokio::task::JoinSet::new();
    let mut pending = pages.into_iter();

    while set.len() < workers {
        let Some(page) = pending.next() else { break };
        let c = ctx.clone();
        set.spawn(async move {
            if let Err(e) = sync_tvmaze_page(&c, page).await {
                warn!(page, error = %e, "TVMaze page failed");
            }
        });
    }
    while set.join_next().await.is_some() {
        if let Some(page) = pending.next() {
            let c = ctx.clone();
            set.spawn(async move {
                if let Err(e) = sync_tvmaze_page(&c, page).await {
                    warn!(page, error = %e, "TVMaze page failed");
                }
            });
        }
    }
    Ok(())
}

async fn sync_tvmaze_page(ctx: &IngestContext, page: usize) -> Result<()> {
    let url = format!("https://api.tvmaze.com/shows?page={page}");
    let shows: Vec<TvMazeShow> = match ctx.http.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => resp.json().await?,
        Ok(resp) => {
            warn!(page, status = %resp.status(), "TVMaze page skipped");
            return Ok(());
        }
        Err(e) => {
            return Err(crate::error::AppError::Provider(e.to_string()));
        }
    };

    let mut need_cast: Vec<(Uuid, i32)> = Vec::new();
    let mut set = tokio::task::JoinSet::new();
    let mut pending = shows.into_iter();
    const UPSERT_WORKERS: usize = 24;
    while set.len() < UPSERT_WORKERS {
        let Some(show) = pending.next() else { break };
        let c = ctx.clone();
        set.spawn(async move { upsert_show(&c, show).await });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(Ok(Some(pair))) => need_cast.push(pair),
            Ok(Ok(None)) => {}
            Ok(Err(e)) => warn!(error = %e, "TVMaze upsert failed"),
            Err(e) => warn!(error = %e, "TVMaze upsert task failed"),
        }
        if let Some(show) = pending.next() {
            let c = ctx.clone();
            set.spawn(async move { upsert_show(&c, show).await });
        }
    }

    // Cast in parallel — this used to be sequential and made series sync crawl.
    let cast_workers = super::sync_workers().saturating_mul(2).min(48);
    let mut set = tokio::task::JoinSet::new();
    let mut pending = need_cast.into_iter();
    while set.len() < cast_workers {
        let Some((title_id, tvmaze_id)) = pending.next() else { break };
        let c = ctx.clone();
        set.spawn(async move {
            if let Err(e) = fill_cast_if_missing(&c, title_id, tvmaze_id).await {
                warn!(show_id = tvmaze_id, error = %e, "TVMaze cast fetch failed");
            }
        });
    }
    while set.join_next().await.is_some() {
        if let Some((title_id, tvmaze_id)) = pending.next() {
            let c = ctx.clone();
            set.spawn(async move {
                if let Err(e) = fill_cast_if_missing(&c, title_id, tvmaze_id).await {
                    warn!(show_id = tvmaze_id, error = %e, "TVMaze cast fetch failed");
                }
            });
        }
    }

    throttle().await;
    Ok(())
}

async fn upsert_show(ctx: &IngestContext, show: TvMazeShow) -> Result<Option<(Uuid, i32)>> {
    let tvmaze_id = show.id;
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
            return Ok(None);
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
        None,
    )
    .await?;
    replace_genre_names(ctx, id, &show.genres.unwrap_or_default()).await?;
    upsert_ratings(
        ctx,
        id,
        show.rating.and_then(|r| r.average),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    )
    .await?;
    // Search index rebuilt in batch at end of sync.

    let people: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM title_people WHERE title_id = $1")
            .bind(id)
            .fetch_one(&ctx.pool)
            .await?;
    if people.0 > 0 {
        return Ok(None);
    }
    Ok(Some((id, tvmaze_id)))
}

async fn fill_cast_if_missing(ctx: &IngestContext, title_id: Uuid, tvmaze_id: i32) -> Result<()> {
    let url = format!("https://api.tvmaze.com/shows/{tvmaze_id}/cast");
    let credits: Vec<TvMazeCastCredit> = match ctx.http.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => resp.json().await?,
        Ok(resp) if resp.status().as_u16() == 404 => return Ok(()),
        Ok(resp) => {
            warn!(tvmaze_id, status = %resp.status(), "TVMaze cast skipped");
            return Ok(());
        }
        Err(e) => return Err(crate::error::AppError::Provider(e.to_string())),
    };

    let mut people = Vec::new();
    for (i, credit) in credits.into_iter().take(16).enumerate() {
        let Some(person) = credit.person else { continue };
        let Some(name) = person.name.filter(|s| !s.is_empty()) else { continue };
        let profile = person
            .image
            .and_then(|img| img.medium.or(img.original));
        people.push(CreditPerson {
            name,
            character: credit.character.and_then(|c| c.name),
            job: None,
            department: "cast",
            profile_path: profile,
            sort_order: i as i32,
        });
    }
    if !people.is_empty() {
        replace_credit_people(ctx, title_id, &people).await?;
    }
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
