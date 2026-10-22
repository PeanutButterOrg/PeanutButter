//! Batched per-title lookups. A home feed asks for ~80 titles × 9 fields;
//! resolving each field per title was ~700 queries. Each loader turns one
//! field into a single `title_id = ANY($1)` query per request.

use std::collections::HashMap;
use std::sync::Arc;

use async_graphql::dataloader::{DataLoader, Loader};
use sqlx::PgPool;
use uuid::Uuid;

use crate::db::models::{RatingRow, UserProgressRow};

pub type LoadError = Arc<sqlx::Error>;

/// Best file per title (quality first) plus the highest peer count seen.
#[derive(Clone, Debug, Default)]
pub struct FileStats {
    pub quality: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub container: Option<String>,
    pub peers: i32,
}

pub struct TitleLoader {
    pool: PgPool,
}

/// One DataLoader per request: batching (and per-request caching) only.
pub fn new_loader(pool: PgPool) -> DataLoader<TitleLoader> {
    DataLoader::new(TitleLoader { pool }, tokio::spawn)
}

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct RatingsKey(pub Uuid);
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct GenresKey(pub Uuid);
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct TrailerKey(pub Uuid);
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct FileStatsKey(pub Uuid);
/// (device token, title)
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct ProgressKey(pub Uuid, pub Uuid);

fn ids<K: Copy>(keys: &[K], id: impl Fn(K) -> Uuid) -> Vec<Uuid> {
    keys.iter().map(|k| id(*k)).collect()
}

impl Loader<RatingsKey> for TitleLoader {
    type Value = RatingRow;
    type Error = LoadError;

    async fn load(&self, keys: &[RatingsKey]) -> Result<HashMap<RatingsKey, RatingRow>, LoadError> {
        let rows: Vec<RatingRow> = sqlx::query_as(
            r#"
            SELECT id, title_id, tmdb_vote_average, tmdb_vote_count, imdb_rating, imdb_votes,
                   anilist_score, anilist_popularity, rt_score, updated_at
            FROM ratings
            WHERE title_id = ANY($1)
            "#,
        )
        .bind(ids(keys, |k| k.0))
        .fetch_all(&self.pool)
        .await
        .map_err(Arc::new)?;
        Ok(rows.into_iter().map(|r| (RatingsKey(r.title_id), r)).collect())
    }
}

impl Loader<GenresKey> for TitleLoader {
    type Value = Vec<String>;
    type Error = LoadError;

    async fn load(&self, keys: &[GenresKey]) -> Result<HashMap<GenresKey, Vec<String>>, LoadError> {
        let rows: Vec<(Uuid, String)> = sqlx::query_as(
            r#"
            SELECT tg.title_id, g.name
            FROM genres g
            JOIN title_genres tg ON tg.genre_id = g.id
            WHERE tg.title_id = ANY($1)
            ORDER BY g.name
            "#,
        )
        .bind(ids(keys, |k| k.0))
        .fetch_all(&self.pool)
        .await
        .map_err(Arc::new)?;
        let mut out: HashMap<GenresKey, Vec<String>> = HashMap::new();
        for (title_id, name) in rows {
            out.entry(GenresKey(title_id)).or_default().push(name);
        }
        Ok(out)
    }
}

impl Loader<TrailerKey> for TitleLoader {
    type Value = String;
    type Error = LoadError;

    async fn load(&self, keys: &[TrailerKey]) -> Result<HashMap<TrailerKey, String>, LoadError> {
        let rows: Vec<(Uuid, String)> = sqlx::query_as(
            r#"
            SELECT DISTINCT ON (title_id) title_id, youtube_key
            FROM trailers
            WHERE title_id = ANY($1)
              AND COALESCE(size, 720) >= 720
              AND name NOT ILIKE '%mobile%'
            ORDER BY title_id, size DESC NULLS LAST, created_at
            "#,
        )
        .bind(ids(keys, |k| k.0))
        .fetch_all(&self.pool)
        .await
        .map_err(Arc::new)?;
        Ok(rows.into_iter().map(|(id, key)| (TrailerKey(id), key)).collect())
    }
}

impl Loader<FileStatsKey> for TitleLoader {
    type Value = FileStats;
    type Error = LoadError;

    async fn load(&self, keys: &[FileStatsKey]) -> Result<HashMap<FileStatsKey, FileStats>, LoadError> {
        #[allow(clippy::type_complexity)]
        let rows: Vec<(Uuid, Option<String>, Option<String>, Option<String>, Option<String>, i32)> =
            sqlx::query_as(
                r#"
                SELECT DISTINCT ON (title_id)
                       title_id, quality, codec, audio_codec, container,
                       COALESCE(MAX(available_peers) OVER (PARTITION BY title_id), 0)::int
                FROM file_references
                WHERE title_id = ANY($1)
                ORDER BY title_id, quality DESC NULLS LAST
                "#,
            )
            .bind(ids(keys, |k| k.0))
            .fetch_all(&self.pool)
            .await
            .map_err(Arc::new)?;
        Ok(rows
            .into_iter()
            .map(|(id, quality, codec, audio_codec, container, peers)| {
                (
                    FileStatsKey(id),
                    FileStats {
                        quality,
                        codec,
                        audio_codec,
                        container,
                        peers,
                    },
                )
            })
            .collect())
    }
}

impl Loader<ProgressKey> for TitleLoader {
    type Value = UserProgressRow;
    type Error = LoadError;

    async fn load(&self, keys: &[ProgressKey]) -> Result<HashMap<ProgressKey, UserProgressRow>, LoadError> {
        // Normally one token per request; group anyway.
        let mut by_token: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
        for k in keys {
            by_token.entry(k.0).or_default().push(k.1);
        }
        let mut out = HashMap::new();
        for (token, titles) in by_token {
            let rows: Vec<UserProgressRow> = sqlx::query_as(
                r#"
                SELECT title_id, episode_id, file_id, position_ms, duration_ms, watched, favorite, updated_at
                FROM user_progress
                WHERE token_id = $1 AND title_id = ANY($2)
                "#,
            )
            .bind(token)
            .bind(&titles)
            .fetch_all(&self.pool)
            .await
            .map_err(Arc::new)?;
            out.extend(rows.into_iter().map(|r| (ProgressKey(token, r.title_id), r)));
        }
        Ok(out)
    }
}
