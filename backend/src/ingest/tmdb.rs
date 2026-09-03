use serde::Deserialize;
use tracing::{debug, info, warn};
use uuid::Uuid;

use super::{throttle, IngestContext};
use crate::db;
use crate::db::models::TitleRow;
use crate::error::{AppError, Result};

const TMDB: &str = "https://api.themoviedb.org/3";

#[derive(Debug, Deserialize)]
struct Page<T> {
    results: Vec<T>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct MovieListItem {
    id: i32,
    title: Option<String>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct TvListItem {
    id: i32,
    name: Option<String>,
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
    #[serde(rename = "type")]
    kind: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MovieDetails {
    id: i32,
    title: String,
    original_title: Option<String>,
    overview: Option<String>,
    release_date: Option<String>,
    runtime: Option<i32>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    imdb_id: Option<String>,
    vote_average: Option<f64>,
    vote_count: Option<i32>,
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
    overview: Option<String>,
    first_air_date: Option<String>,
    episode_run_time: Option<Vec<i32>>,
    poster_path: Option<String>,
    backdrop_path: Option<String>,
    vote_average: Option<f64>,
    vote_count: Option<i32>,
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
    fetch_movies(ctx).await?;
    fetch_tv(ctx).await?;
    refresh_stale_titles(ctx).await?;
    Ok(())
}

pub async fn fetch_movies(ctx: &IngestContext) -> Result<()> {
    let endpoints = [
        "/movie/popular",
        "/movie/top_rated",
        "/movie/now_playing",
        "/trending/movie/week",
    ];
    for path in endpoints {
        info!(path, "fetching TMDB movies");
        let ids = list_movie_ids(ctx, path).await?;
        for id in ids.into_iter().take(40) {
            match fetch_details_movie(ctx, id).await {
                Ok(details) => {
                    if let Err(e) = upsert_movie(ctx, details).await {
                        warn!(tmdb_id = id, error = %e, "movie upsert failed");
                    }
                }
                Err(e) => warn!(tmdb_id = id, error = %e, "movie details failed"),
            }
            throttle().await;
        }
    }
    Ok(())
}

pub async fn fetch_tv(ctx: &IngestContext) -> Result<()> {
    let endpoints = ["/tv/popular", "/tv/top_rated", "/trending/tv/week"];
    for path in endpoints {
        info!(path, "fetching TMDB TV");
        let ids = list_tv_ids(ctx, path).await?;
        for id in ids.into_iter().take(25) {
            match fetch_details_tv(ctx, id).await {
                Ok(details) => {
                    if let Err(e) = upsert_tv(ctx, details).await {
                        warn!(tmdb_id = id, error = %e, "tv upsert failed");
                    }
                }
                Err(e) => warn!(tmdb_id = id, error = %e, "tv details failed"),
            }
            throttle().await;
        }
    }
    Ok(())
}

pub async fn fetch_details(ctx: &IngestContext, tmdb_id: i32, kind: &str) -> Result<Uuid> {
    if kind == "series" {
        let details = fetch_details_tv(ctx, tmdb_id).await?;
        upsert_tv(ctx, details).await
    } else {
        let details = fetch_details_movie(ctx, tmdb_id).await?;
        upsert_movie(ctx, details).await
    }
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
        throttle().await;
    }
    Ok(())
}

async fn list_movie_ids(ctx: &IngestContext, path: &str) -> Result<Vec<i32>> {
    let mut ids = Vec::new();
    for page in 1..=2 {
        let url = format!(
            "{TMDB}{path}?api_key={}&language=en-US&page={page}",
            ctx.config.tmdb_key()
        );
        let page_data: Page<MovieListItem> = get_json(ctx, &url).await?;
        ids.extend(page_data.results.into_iter().map(|m| m.id));
        throttle().await;
    }
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

async fn list_tv_ids(ctx: &IngestContext, path: &str) -> Result<Vec<i32>> {
    let mut ids = Vec::new();
    for page in 1..=2 {
        let url = format!(
            "{TMDB}{path}?api_key={}&language=en-US&page={page}",
            ctx.config.tmdb_key()
        );
        let page_data: Page<TvListItem> = get_json(ctx, &url).await?;
        ids.extend(page_data.results.into_iter().map(|m| m.id));
        throttle().await;
    }
    ids.sort_unstable();
    ids.dedup();
    Ok(ids)
}

async fn fetch_details_movie(ctx: &IngestContext, id: i32) -> Result<MovieDetails> {
    let url = format!(
        "{TMDB}/movie/{id}?api_key={}&language=en-US&append_to_response=videos,images,credits,release_dates&include_image_language=en,null",
        ctx.config.tmdb_key()
    );
    get_json(ctx, &url).await
}

async fn fetch_details_tv(ctx: &IngestContext, id: i32) -> Result<TvDetails> {
    let url = format!(
        "{TMDB}/tv/{id}?api_key={}&language=en-US&append_to_response=videos,external_ids,images,credits,aggregate_credits,content_ratings&include_image_language=en,ja,null",
        ctx.config.tmdb_key()
    );
    get_json(ctx, &url).await
}

async fn upsert_movie(ctx: &IngestContext, details: MovieDetails) -> Result<Uuid> {
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
    )
    .await?;

    replace_genres(ctx, id, details.genres.as_deref().unwrap_or(&[])).await?;
    replace_trailers(ctx, id, details.videos.as_ref()).await?;
    apply_extra_art(ctx, id, details.images.as_ref()).await?;
    replace_people(ctx, id, details.credits.as_ref()).await?;
    apply_content_rating(ctx, id, certification_from_releases(details.release_dates.as_ref())).await?;
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
    )
    .await?;
    reindex(ctx, id).await?;
    Ok(id)
}

async fn upsert_tv(ctx: &IngestContext, details: TvDetails) -> Result<Uuid> {
    let year = year_from(&details.first_air_date);
    let runtime = details
        .episode_run_time
        .as_ref()
        .and_then(|v| v.first().copied());

    let mut imdb_id: Option<String> = None;
    let ext_url = format!(
        "{TMDB}/tv/{}/external_ids?api_key={}",
        details.id, ctx.config.tmdb_key()
    );
    if let Ok(ext) = get_json::<ExternalIds>(ctx, &ext_url).await {
        imdb_id = ext.imdb_id;
    }

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
    )
    .await?;

    if let Some(seasons) = details.seasons {
        for season in seasons {
            if season.season_number < 0 {
                continue;
            }
            let season_id = upsert_season(ctx, id, &season).await?;
            if let Err(e) = sync_season_episodes(ctx, details.id, season.season_number, season_id).await
            {
                warn!(
                    tmdb_id = details.id,
                    season = season.season_number,
                    error = %e,
                    "season episodes failed"
                );
            }
            throttle().await;
        }
    }

    reindex(ctx, id).await?;
    Ok(id)
}

async fn sync_season_episodes(
    ctx: &IngestContext,
    tmdb_tv_id: i32,
    season_number: i32,
    season_id: Uuid,
) -> Result<()> {
    let url = format!(
        "{TMDB}/tv/{tmdb_tv_id}/season/{season_number}?api_key={}&language=en-US",
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
) -> Result<Uuid> {
    let mut existing: Option<(Uuid,)> = if let Some(tmdb_id) = tmdb_id {
        sqlx::query_as("SELECT id FROM titles WHERE tmdb_id = $1")
            .bind(tmdb_id)
            .fetch_optional(&ctx.pool)
            .await?
    } else {
        None
    };
    if existing.is_none() {
        if let Some(imdb_id) = imdb_id.filter(|s| !s.is_empty()) {
            existing = sqlx::query_as("SELECT id FROM titles WHERE imdb_id = $1")
                .bind(imdb_id)
                .fetch_optional(&ctx.pool)
                .await?;
        }
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
                imdb_id = COALESCE($11, imdb_id), anilist_id = COALESCE($12, anilist_id),
                mal_id = COALESCE($13, mal_id), last_synced_at = now()
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
        .bind(imdb_id)
        .bind(anilist_id)
        .bind(mal_id)
        .execute(&ctx.pool)
        .await?;
        return Ok(id);
    }

    let row: (Uuid,) = sqlx::query_as(
        r#"
        INSERT INTO titles (
            kind, title, original_title, synopsis, description, year, runtime_minutes,
            poster_path, backdrop_path, tmdb_id, imdb_id, anilist_id, mal_id, last_synced_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, now())
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
    .fetch_one(&ctx.pool)
    .await?;
    Ok(row.0)
}

fn pick_image<'a>(images: &'a [TmdbImage], prefer_text: bool) -> Option<&'a TmdbImage> {
    let mut scored: Vec<(i32, &'a TmdbImage)> = images
        .iter()
        .map(|img| {
            let lang = img.iso_639_1.as_deref().unwrap_or("");
            let lang_score = if lang.eq_ignore_ascii_case("en") {
                2
            } else if lang.is_empty() {
                if prefer_text { 0 } else { 3 }
            } else if prefer_text {
                1
            } else {
                0
            };
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

async fn apply_extra_art(ctx: &IngestContext, title_id: Uuid, images: Option<&TmdbImages>) -> Result<()> {
    let Some(images) = images else { return Ok(()) };
    let logo = images.logos.as_ref().and_then(|v| pick_image(v, true));
    let thumb = images
        .backdrops
        .as_ref()
        .and_then(|v| {
            v.iter()
                .filter(|img| img.iso_639_1.as_deref().is_some_and(|l| !l.is_empty()))
                .collect::<Vec<_>>()
                .into_iter()
                .max_by(|a, b| {
                    a.vote_average
                        .partial_cmp(&b.vote_average)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        })
        .or_else(|| images.backdrops.as_ref().and_then(|v| pick_image(v, false)));
    sqlx::query(
        r#"
        UPDATE titles SET
            logo_path = COALESCE($2, logo_path),
            thumb_path = COALESCE($3, thumb_path)
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .bind(logo.map(|img| img.file_path.as_str()))
    .bind(thumb.map(|img| img.file_path.as_str()))
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
        if name.is_empty() {
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
    for v in &videos.results {
        if !v.site.eq_ignore_ascii_case("YouTube") {
            continue;
        }
        let is_trailer = v
            .kind
            .as_deref()
            .map(|k| k.eq_ignore_ascii_case("Trailer") || k.eq_ignore_ascii_case("Teaser"))
            .unwrap_or(true);
        if !is_trailer {
            continue;
        }
        // TMDB lists 360/480 "mobile" encodes of the same clip. Keep 720p+.
        if v.size.unwrap_or(0) > 0 && v.size.unwrap_or(0) < 720 {
            continue;
        }
        if v.name.to_ascii_lowercase().contains("mobile") {
            continue;
        }
        sqlx::query(
            r#"
            INSERT INTO trailers (title_id, name, youtube_key, site, size)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (title_id, youtube_key) DO UPDATE SET name = EXCLUDED.name, size = EXCLUDED.size
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
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO ratings (
            title_id, tmdb_vote_average, tmdb_vote_count, imdb_rating, imdb_votes,
            anilist_score, anilist_popularity, rt_score, updated_at
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8, now())
        ON CONFLICT (title_id) DO UPDATE SET
            tmdb_vote_average = COALESCE(EXCLUDED.tmdb_vote_average, ratings.tmdb_vote_average),
            tmdb_vote_count = COALESCE(EXCLUDED.tmdb_vote_count, ratings.tmdb_vote_count),
            imdb_rating = COALESCE(EXCLUDED.imdb_rating, ratings.imdb_rating),
            imdb_votes = COALESCE(EXCLUDED.imdb_votes, ratings.imdb_votes),
            anilist_score = COALESCE(EXCLUDED.anilist_score, ratings.anilist_score),
            anilist_popularity = COALESCE(EXCLUDED.anilist_popularity, ratings.anilist_popularity),
            rt_score = COALESCE(EXCLUDED.rt_score, ratings.rt_score),
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

fn year_from(date: &Option<String>) -> Option<i32> {
    date.as_ref()
        .and_then(|d| d.get(0..4))
        .and_then(|y| y.parse().ok())
        .filter(|y| *y > 1800)
}

async fn get_json<T: serde::de::DeserializeOwned>(ctx: &IngestContext, url: &str) -> Result<T> {
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
