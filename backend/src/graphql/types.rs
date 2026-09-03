use async_graphql::{ComplexObject, Context, Enum, InputObject, SimpleObject};
use chrono::{DateTime, NaiveDate, Utc};
use uuid::Uuid;

use crate::config::{absolute_image_url, backdrop_url, logo_url, profile_url, still_url};
use crate::db::models::{
    EpisodeRow, FileReferenceRow, RatingRow, SeasonRow, TitlePersonRow, TitleRow, TrailerRow,
    UserProgressRow,
};
use crate::db::{self};
use crate::error::AppError;
use crate::AppState;

struct PrimaryFile {
    quality: Option<String>,
    codec: Option<String>,
    audio_codec: Option<String>,
    container: Option<String>,
}

async fn primary_file(ctx: &Context<'_>, title_id: Uuid) -> async_graphql::Result<Option<PrimaryFile>> {
    let state = ctx.data::<AppState>()?;
    let row: Option<(Option<String>, Option<String>, Option<String>, Option<String>)> = sqlx::query_as(
        r#"
        SELECT quality, codec, audio_codec, container
        FROM file_references
        WHERE title_id = $1
        ORDER BY quality DESC NULLS LAST
        LIMIT 1
        "#,
    )
    .bind(title_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(AppError::Database)?;
    Ok(row.map(|(quality, codec, audio_codec, container)| PrimaryFile {
        quality,
        codec,
        audio_codec,
        container,
    }))
}

#[derive(Enum, Copy, Clone, Eq, PartialEq, Debug)]
#[graphql(rename_items = "SCREAMING_SNAKE_CASE")]
pub enum TitleKind {
    Movie,
    Series,
    Anime,
}

impl TitleKind {
    pub fn as_db(self) -> &'static str {
        match self {
            TitleKind::Movie => "movie",
            TitleKind::Series => "series",
            TitleKind::Anime => "anime",
        }
    }

    pub fn from_db(value: &str) -> Self {
        match value {
            "series" => TitleKind::Series,
            "anime" => TitleKind::Anime,
            _ => TitleKind::Movie,
        }
    }
}

#[derive(Enum, Copy, Clone, Eq, PartialEq, Debug)]
#[graphql(rename_items = "SCREAMING_SNAKE_CASE")]
pub enum SortField {
    Rating,
    Popularity,
    Year,
    Title,
    DateAdded,
    Trending,
    RottenTomatoes,
    Availability,
    ContinueWatching,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq, Debug)]
#[graphql(rename_items = "SCREAMING_SNAKE_CASE")]
pub enum SortDir {
    Asc,
    Desc,
}

#[derive(InputObject, Clone, Debug, Default)]
pub struct TitleFilter {
    pub kind: Option<TitleKind>,
    pub genre: Option<String>,
    pub year_min: Option<i32>,
    pub year_max: Option<i32>,
    pub rating_min: Option<f64>,
}

#[derive(InputObject, Clone, Debug, Default)]
pub struct TitleInput {
    pub kind: Option<TitleKind>,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub synopsis: Option<String>,
    pub description: Option<String>,
    pub year: Option<i32>,
    pub runtime_minutes: Option<i32>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct Ratings {
    pub tmdb_vote_average: Option<f64>,
    pub tmdb_vote_count: Option<i32>,
    pub imdb_rating: Option<f64>,
    pub imdb_votes: Option<i32>,
    pub anilist_score: Option<f64>,
    pub anilist_popularity: Option<i32>,
    pub rt_score: Option<i32>,
}

impl From<RatingRow> for Ratings {
    fn from(row: RatingRow) -> Self {
        Self {
            tmdb_vote_average: row.tmdb_vote_average,
            tmdb_vote_count: row.tmdb_vote_count,
            imdb_rating: row.imdb_rating,
            imdb_votes: row.imdb_votes,
            anilist_score: row.anilist_score,
            anilist_popularity: row.anilist_popularity,
            rt_score: row.rt_score,
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct Trailer {
    pub id: Uuid,
    pub name: String,
    pub youtube_key: String,
    pub site: String,
    pub size: Option<i32>,
}

impl From<TrailerRow> for Trailer {
    fn from(row: TrailerRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            youtube_key: row.youtube_key,
            site: row.site,
            size: row.size,
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct FileReference {
    pub id: Uuid,
    pub kind: String,
    pub quality: Option<String>,
    pub container: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub size_bytes: Option<i64>,
    pub available_peers: i32,
    pub playback_url: String,
    pub episode_id: Option<Uuid>,
    pub source: String,
}

impl FileReference {
    pub fn from_row(row: FileReferenceRow, public_url: &str) -> Self {
        let playback_url = format!(
            "{}/files/{}",
            public_url.trim_end_matches('/'),
            row.id
        );
        Self {
            id: row.id,
            kind: row.kind,
            quality: row.quality,
            container: row.container,
            codec: row.codec,
            audio_codec: row.audio_codec,
            size_bytes: row.size_bytes,
            available_peers: row.available_peers,
            playback_url,
            episode_id: row.episode_id,
            source: "local".into(),
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct Episode {
    pub id: Uuid,
    pub episode_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub still_path: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub runtime: Option<i32>,
}

impl From<EpisodeRow> for Episode {
    fn from(row: EpisodeRow) -> Self {
        Self {
            id: row.id,
            episode_number: row.episode_number,
            name: row.name,
            overview: row.overview,
            still_path: still_url(&row.still_path),
            air_date: row.air_date,
            runtime: row.runtime,
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
#[graphql(complex)]
pub struct Season {
    pub id: Uuid,
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub episode_count: Option<i32>,
}

impl From<SeasonRow> for Season {
    fn from(row: SeasonRow) -> Self {
        Self {
            id: row.id,
            season_number: row.season_number,
            name: row.name,
            overview: row.overview,
            poster_path: absolute_image_url(&row.poster_path),
            air_date: row.air_date,
            episode_count: row.episode_count,
        }
    }
}

#[ComplexObject]
impl Season {
    async fn episodes(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Episode>> {
        let state = ctx.data::<AppState>()?;
        let rows: Vec<EpisodeRow> = sqlx::query_as(
            r#"
            SELECT id, season_id, episode_number, name, overview, still_path,
                   air_date, runtime, tmdb_episode_id
            FROM episodes
            WHERE season_id = $1
            ORDER BY episode_number
            "#,
        )
        .bind(self.id)
        .fetch_all(&state.pool)
        .await
        .map_err(|e| AppError::Database(e))?;
        if rows.is_empty() {
            if let Some(count) = self.episode_count.filter(|c| *c > 0) {
                let _ = crate::db::fill_season_episodes(&state.pool, self.id, count).await;
                let rows: Vec<EpisodeRow> = sqlx::query_as(
                    r#"
                    SELECT id, season_id, episode_number, name, overview, still_path,
                           air_date, runtime, tmdb_episode_id
                    FROM episodes
                    WHERE season_id = $1
                    ORDER BY episode_number
                    "#,
                )
                .bind(self.id)
                .fetch_all(&state.pool)
                .await
                .map_err(|e| AppError::Database(e))?;
                return Ok(rows.into_iter().map(Episode::from).collect());
            }
        }
        Ok(rows.into_iter().map(Episode::from).collect())
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct Person {
    pub id: Uuid,
    pub name: String,
    pub character: Option<String>,
    pub job: Option<String>,
    pub department: String,
    pub profile_url: Option<String>,
}

impl From<TitlePersonRow> for Person {
    fn from(row: TitlePersonRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            character: row.character,
            job: row.job,
            department: row.department,
            profile_url: profile_url(&row.profile_path),
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct UserState {
    pub favorite: bool,
    pub watched: bool,
    pub position_ms: i64,
    pub duration_ms: Option<i64>,
    pub episode_id: Option<Uuid>,
    pub file_id: Option<Uuid>,
}

impl From<UserProgressRow> for UserState {
    fn from(row: UserProgressRow) -> Self {
        Self {
            favorite: row.favorite,
            watched: row.watched,
            position_ms: row.position_ms,
            duration_ms: row.duration_ms,
            episode_id: row.episode_id,
            file_id: row.file_id,
        }
    }
}

#[derive(SimpleObject, Clone, Debug)]
#[graphql(complex)]
pub struct Title {
    pub id: Uuid,
    pub kind: TitleKind,
    pub title: String,
    pub original_title: Option<String>,
    pub synopsis: Option<String>,
    pub description: Option<String>,
    pub year: Option<i32>,
    pub runtime_minutes: Option<i32>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub logo_url: Option<String>,
    pub thumb_url: Option<String>,
    pub content_rating: Option<String>,
}

impl Title {
    pub fn from_row(row: TitleRow) -> Self {
        Self {
            id: row.id,
            kind: TitleKind::from_db(&row.kind),
            title: row.title,
            original_title: row.original_title,
            synopsis: row.synopsis,
            description: row.description,
            year: row.year,
            runtime_minutes: row.runtime_minutes,
            poster_url: absolute_image_url(&row.poster_path),
            backdrop_url: backdrop_url(&row.backdrop_path),
            logo_url: logo_url(&row.logo_path),
            thumb_url: backdrop_url(&row.thumb_path),
            content_rating: row.content_rating,
        }
    }
}

#[ComplexObject]
impl Title {
    async fn ratings(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<Ratings>> {
        let state = ctx.data::<AppState>()?;
        let row: Option<RatingRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, tmdb_vote_average, tmdb_vote_count, imdb_rating, imdb_votes,
                   anilist_score, anilist_popularity, rt_score, updated_at
            FROM ratings
            WHERE title_id = $1
            "#,
        )
        .bind(self.id)
        .fetch_optional(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(row.map(Ratings::from))
    }

    async fn genres(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<String>> {
        let state = ctx.data::<AppState>()?;
        Ok(db::genre_names_for_title(&state.pool, self.id).await?)
    }

    async fn trailers(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Trailer>> {
        let state = ctx.data::<AppState>()?;
        let rows: Vec<TrailerRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, name, youtube_key, site, size, created_at
            FROM trailers
            WHERE title_id = $1
              AND COALESCE(size, 720) >= 720
              AND name NOT ILIKE '%mobile%'
            ORDER BY size DESC NULLS LAST, created_at
            "#,
        )
        .bind(self.id)
        .fetch_all(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(rows.into_iter().map(Trailer::from).collect())
    }

    async fn file_references(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<FileReference>> {
        let state = ctx.data::<AppState>()?;
        let rows: Vec<FileReferenceRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, season_id, episode_id, kind, quality, container, codec, audio_codec,
                   size_bytes, file_path, http_url, content_hash, available_peers,
                   last_check, created_at
            FROM file_references
            WHERE title_id = $1
            ORDER BY quality DESC NULLS LAST, created_at
            "#,
        )
        .bind(self.id)
        .fetch_all(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(rows
            .into_iter()
            .map(|r| FileReference::from_row(r, &state.config.public_url))
            .collect())
    }

    async fn seasons(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Season>> {
        let state = ctx.data::<AppState>()?;
        let rows: Vec<SeasonRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, season_number, name, overview, poster_path, air_date,
                   episode_count, tmdb_season_id
            FROM seasons
            WHERE title_id = $1
            ORDER BY season_number
            "#,
        )
        .bind(self.id)
        .fetch_all(&state.pool)
        .await
        .map_err(AppError::Database)?;
        if rows.is_empty() {
            let info: Option<(String, serde_json::Value)> = sqlx::query_as(
                "SELECT kind, metadata FROM titles WHERE id = $1",
            )
            .bind(self.id)
            .fetch_optional(&state.pool)
            .await
            .map_err(AppError::Database)?;
            if let Some((kind, metadata)) = info {
                if kind == "anime" {
                    let count = metadata
                        .get("episodes")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(12) as i32;
                    let _ = crate::db::ensure_episode_list(&state.pool, self.id, count).await;
                    let rows: Vec<SeasonRow> = sqlx::query_as(
                        r#"
                        SELECT id, title_id, season_number, name, overview, poster_path, air_date,
                               episode_count, tmdb_season_id
                        FROM seasons
                        WHERE title_id = $1
                        ORDER BY season_number
                        "#,
                    )
                    .bind(self.id)
                    .fetch_all(&state.pool)
                    .await
                    .map_err(AppError::Database)?;
                    return Ok(rows.into_iter().map(Season::from).collect());
                }
            }
        }
        Ok(rows.into_iter().map(Season::from).collect())
    }

    async fn trailer_youtube_key(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        let state = ctx.data::<AppState>()?;
        let row: Option<(String,)> = sqlx::query_as(
            r#"
            SELECT youtube_key FROM trailers
            WHERE title_id = $1
              AND COALESCE(size, 720) >= 720
              AND name NOT ILIKE '%mobile%'
            ORDER BY size DESC NULLS LAST, created_at
            LIMIT 1
            "#,
        )
        .bind(self.id)
        .fetch_optional(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(row.map(|r| r.0))
    }

    async fn available_peers(&self, ctx: &Context<'_>) -> async_graphql::Result<i32> {
        let state = ctx.data::<AppState>()?;
        let (peers,): (i32,) = sqlx::query_as(
            "SELECT COALESCE(MAX(available_peers), 0)::int FROM file_references WHERE title_id = $1",
        )
        .bind(self.id)
        .fetch_one(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(peers)
    }

    async fn best_quality(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        Ok(primary_file(ctx, self.id).await?.and_then(|row| row.quality))
    }

    async fn video_codec(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        Ok(primary_file(ctx, self.id).await?.and_then(|row| row.codec))
    }

    async fn audio_codec(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        Ok(primary_file(ctx, self.id).await?.and_then(|row| row.audio_codec))
    }

    async fn container(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        Ok(primary_file(ctx, self.id).await?.and_then(|row| row.container))
    }

    async fn people(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Person>> {
        let state = ctx.data::<AppState>()?;
        let rows: Vec<TitlePersonRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, name, character, job, department, profile_path, sort_order
            FROM title_people
            WHERE title_id = $1
            ORDER BY department ASC, sort_order ASC
            "#,
        )
        .bind(self.id)
        .fetch_all(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(rows.into_iter().map(Person::from).collect())
    }

    async fn user_state(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<UserState>> {
        let state = ctx.data::<AppState>()?;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        let row: Option<UserProgressRow> = sqlx::query_as(
            r#"
            SELECT title_id, episode_id, file_id, position_ms, duration_ms, watched, favorite, updated_at
            FROM user_progress
            WHERE token_id = $1 AND title_id = $2
            "#,
        )
        .bind(auth.token_id)
        .bind(self.id)
        .fetch_optional(&state.pool)
        .await
        .map_err(AppError::Database)?;
        Ok(row.map(UserState::from))
    }
}

#[derive(SimpleObject, Clone, Debug)]
pub struct TitleConnection {
    pub items: Vec<Title>,
    pub total_count: i64,
    pub has_next_page: bool,
    pub page: i32,
    pub per_page: i32,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct HomeFeed {
    pub trending: Vec<Title>,
    pub popular: Vec<Title>,
    pub recent: Vec<Title>,
    pub continue_watching: Vec<Title>,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct SyncStatus {
    pub last_sync_at: Option<DateTime<Utc>>,
    pub total_titles: i32,
    pub syncing: bool,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct ServerInfo {
    pub version: String,
    pub library_path: String,
    pub sync_status: SyncStatus,
    pub tmdb_configured: bool,
    pub omdb_configured: bool,
    pub anilist_configured: bool,
    pub jackett_enabled: bool,
    pub jackett_configured: bool,
    pub jackett_url: Option<String>,
    pub streaming_resolution: String,
    pub jackett_catalog: JackettCatalogStatus,
    pub opensubtitles_enabled: bool,
    pub opensubtitles_configured: bool,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct JackettCatalogStatus {
    pub ready: bool,
    pub syncing: bool,
    pub done: i32,
    pub total: i32,
    pub last_error: Option<String>,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct StreamSource {
    pub id: String,
    pub title: String,
    pub magnet: String,
    pub seeders: i32,
    pub peers: i32,
    pub rating: i32,
    pub health: String,
    pub size: String,
    pub tracker: String,
    pub indexer: String,
    pub language: String,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct StreamSession {
    pub id: String,
    pub title: String,
    pub progress: f32,
    pub buffer_progress: f32,
    pub download_mbps: f64,
    pub seeders: i32,
    pub peers: i32,
    pub resume_position: i32,
    pub status: String,
    pub stream_url: String,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct SearchResult {
    pub items: Vec<Title>,
    pub total_count: i64,
    pub has_next_page: bool,
    pub page: i32,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct MutationResult {
    pub success: bool,
    pub message: String,
}

#[derive(SimpleObject, Clone, Debug)]
pub struct Subtitle {
    pub id: Uuid,
    pub language: String,
    pub label: String,
    pub format: String,
    pub content: String,
}
