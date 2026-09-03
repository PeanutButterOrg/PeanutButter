#![allow(dead_code)]

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct TitleRow {
    pub id: Uuid,
    pub kind: String,
    pub title: String,
    pub original_title: Option<String>,
    pub synopsis: Option<String>,
    pub description: Option<String>,
    pub year: Option<i32>,
    pub runtime_minutes: Option<i32>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub logo_path: Option<String>,
    pub thumb_path: Option<String>,
    pub content_rating: Option<String>,
    pub tmdb_id: Option<i32>,
    pub imdb_id: Option<String>,
    pub anilist_id: Option<i32>,
    pub mal_id: Option<i32>,
    pub metadata: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_synced_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, FromRow)]
pub struct TitlePersonRow {
    pub id: Uuid,
    pub title_id: Uuid,
    pub name: String,
    pub character: Option<String>,
    pub job: Option<String>,
    pub department: String,
    pub profile_path: Option<String>,
    pub sort_order: i32,
}

#[derive(Debug, Clone, FromRow)]
pub struct UserProgressRow {
    pub title_id: Uuid,
    pub episode_id: Option<Uuid>,
    pub file_id: Option<Uuid>,
    pub position_ms: i64,
    pub duration_ms: Option<i64>,
    pub watched: bool,
    pub favorite: bool,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
pub struct GenreRow {
    pub id: Uuid,
    pub name: String,
}

#[derive(Debug, Clone, FromRow)]
pub struct SeasonRow {
    pub id: Uuid,
    pub title_id: Uuid,
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub poster_path: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub episode_count: Option<i32>,
    pub tmdb_season_id: Option<i32>,
}

#[derive(Debug, Clone, FromRow)]
pub struct EpisodeRow {
    pub id: Uuid,
    pub season_id: Uuid,
    pub episode_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub still_path: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub runtime: Option<i32>,
    pub tmdb_episode_id: Option<i32>,
}

#[derive(Debug, Clone, FromRow)]
pub struct FileReferenceRow {
    pub id: Uuid,
    pub title_id: Uuid,
    pub season_id: Option<Uuid>,
    pub episode_id: Option<Uuid>,
    pub kind: String,
    pub quality: Option<String>,
    pub container: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub size_bytes: Option<i64>,
    pub file_path: String,
    pub http_url: Option<String>,
    pub content_hash: Option<String>,
    pub available_peers: i32,
    pub last_check: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
pub struct RatingRow {
    pub id: Uuid,
    pub title_id: Uuid,
    pub tmdb_vote_average: Option<f64>,
    pub tmdb_vote_count: Option<i32>,
    pub imdb_rating: Option<f64>,
    pub imdb_votes: Option<i32>,
    pub anilist_score: Option<f64>,
    pub anilist_popularity: Option<i32>,
    pub rt_score: Option<i32>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
pub struct TrailerRow {
    pub id: Uuid,
    pub title_id: Uuid,
    pub name: String,
    pub youtube_key: String,
    pub site: String,
    pub size: Option<i32>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, FromRow)]
pub struct SyncStateRow {
    pub id: i32,
    pub last_sync_at: Option<DateTime<Utc>>,
    pub syncing: bool,
    pub total_titles: i32,
    pub last_error: Option<String>,
}
