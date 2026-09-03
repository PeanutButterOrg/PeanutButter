use async_graphql::{Context, InputObject, Object};
use uuid::Uuid;

use crate::error::AppError;
use crate::graphql::types::{MutationResult, StreamSession, Subtitle, Title, TitleInput};
use crate::ingest::{self, IngestContext};
use crate::AppState;

pub struct Mutation;

#[Object]
impl Mutation {
    /// Start a background metadata sync from OMDb, TVMaze, AniList, and optional TMDB.
    async fn trigger_sync(&self, ctx: &Context<'_>) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        if state.syncing.load(std::sync::atomic::Ordering::Relaxed) {
            return Ok(MutationResult {
                success: true,
                message: "sync already running".into(),
            });
        }
        let ingest = IngestContext::from(state);
        tokio::spawn(async move {
            if let Err(e) = ingest::run_full_sync(&ingest).await {
                tracing::error!(error = %e, "background sync failed");
            }
        });
        Ok(MutationResult {
            success: true,
            message: "metadata sync started".into(),
        })
    }

    async fn create_title(
        &self,
        ctx: &Context<'_>,
        input: TitleInput,
    ) -> async_graphql::Result<Title> {
        let state = ctx.data::<AppState>()?;
        let title = input.title.clone().unwrap_or_else(|| "Untitled".into());
        let kind = input.kind.unwrap_or(crate::graphql::types::TitleKind::Movie);
        let row: (Uuid,) = sqlx::query_as(
            r#"
            INSERT INTO titles (kind, title, original_title, synopsis, description, year, runtime_minutes, poster_path, backdrop_path)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
            RETURNING id
            "#,
        )
        .bind(kind.as_db())
        .bind(&title)
        .bind(&input.original_title)
        .bind(&input.synopsis)
        .bind(&input.description)
        .bind(input.year)
        .bind(input.runtime_minutes)
        .bind(&input.poster_url)
        .bind(&input.backdrop_url)
        .fetch_one(&state.pool)
        .await?;
        state.gql_cache.invalidate();
        let full = fetch_title(&state.pool, row.0).await?;
        Ok(Title::from_row(full))
    }

    async fn update_title(
        &self,
        ctx: &Context<'_>,
        id: Uuid,
        input: TitleInput,
    ) -> async_graphql::Result<Title> {
        let state = ctx.data::<AppState>()?;
        sqlx::query(
            r#"
            UPDATE titles SET
                kind = COALESCE($2, kind),
                title = COALESCE($3, title),
                original_title = COALESCE($4, original_title),
                synopsis = COALESCE($5, synopsis),
                description = COALESCE($6, description),
                year = COALESCE($7, year),
                runtime_minutes = COALESCE($8, runtime_minutes),
                poster_path = COALESCE($9, poster_path),
                backdrop_path = COALESCE($10, backdrop_path),
                updated_at = now()
            WHERE id = $1
            "#,
        )
        .bind(id)
        .bind(input.kind.map(|k| k.as_db()))
        .bind(&input.title)
        .bind(&input.original_title)
        .bind(&input.synopsis)
        .bind(&input.description)
        .bind(input.year)
        .bind(input.runtime_minutes)
        .bind(&input.poster_url)
        .bind(&input.backdrop_url)
        .execute(&state.pool)
        .await?;
        state.gql_cache.invalidate();
        let full = fetch_title(&state.pool, id).await?;
        Ok(Title::from_row(full))
    }

    /// Pull fresh metadata, episodes, and drop cached stream listings for one title.
    async fn refresh_title(&self, ctx: &Context<'_>, id: Uuid) -> async_graphql::Result<Title> {
        let state = ctx.data::<AppState>()?;
        let ingest = IngestContext::from(state);
        crate::ingest::refresh_title(&ingest, id).await?;
        state.gql_cache.invalidate();
        let full = fetch_title(&state.pool, id).await?;
        Ok(Title::from_row(full))
    }

    async fn delete_title(&self, ctx: &Context<'_>, id: Uuid) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        let result = sqlx::query("DELETE FROM titles WHERE id = $1")
            .bind(id)
            .execute(&state.pool)
            .await?;
        let _ = state.search.delete_title(id).await;
        state.gql_cache.invalidate();
        Ok(MutationResult {
            success: result.rows_affected() > 0,
            message: if result.rows_affected() > 0 {
                "title deleted".into()
            } else {
                "title not found".into()
            },
        })
    }

    async fn update_settings(
        &self,
        ctx: &Context<'_>,
        input: SettingsInput,
    ) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        // Jackett is owned by the server console. Ignore client-sent indexer settings.
        crate::db::save_settings(
            &state.pool,
            input.tmdb_api_key.as_deref(),
            input.omdb_api_key.as_deref(),
            input.anilist_client_id.as_ref().map(|s| {
                if s.trim().is_empty() {
                    None
                } else {
                    Some(s.as_str())
                }
            }),
            input.media_path.as_deref().filter(|s| !s.trim().is_empty()),
            None,
            None,
            None,
            None,
            input.opensubtitles_enabled,
            input.opensubtitles_api_key.as_deref().filter(|s| !s.trim().is_empty()),
        )
        .await?;
        state.config.live.apply(
            input.tmdb_api_key,
            input.omdb_api_key,
            input.anilist_client_id.map(|s| {
                if s.trim().is_empty() {
                    None
                } else {
                    Some(s)
                }
            }),
            input
                .media_path
                .filter(|s| !s.trim().is_empty())
                .map(std::path::PathBuf::from),
        );
        state.config.live.apply_opensubtitles(
            input.opensubtitles_enabled,
            input.opensubtitles_api_key.map(|s| {
                if s.trim().is_empty() {
                    None
                } else {
                    Some(s)
                }
            }),
        );
        state.gql_cache.invalidate();
        Ok(MutationResult {
            success: true,
            message: "settings saved".into(),
        })
    }

    /// Download subtitles for one playing file. Cached after the first play.
    async fn ensure_subtitles(
        &self,
        ctx: &Context<'_>,
        file_id: Uuid,
        language: Option<String>,
    ) -> async_graphql::Result<Vec<Subtitle>> {
        let state = ctx.data::<AppState>()?;
        let lang = language.unwrap_or_else(|| "en".into());
        let tracks = crate::subtitles::ensure_for_file(
            &state.pool,
            &state.http,
            &state.config.live,
            file_id,
            &lang,
        )
        .await?;
        Ok(tracks
            .into_iter()
            .map(|t| Subtitle {
                id: t.id,
                language: t.language,
                label: t.label,
                format: t.format,
                content: t.content,
            })
            .collect())
    }

    async fn fetch_subtitles(
        &self,
        ctx: &Context<'_>,
        title_id: Uuid,
        language: Option<String>,
        season: Option<i32>,
        episode: Option<i32>,
        file_id: Option<Uuid>,
    ) -> async_graphql::Result<Vec<Subtitle>> {
        let state = ctx.data::<AppState>()?;
        let lang = language.unwrap_or_else(|| "en".into());
        if !state.config.live.opensubtitles_configured() && file_id.is_none() {
            return Err(AppError::BadRequest(
                "OpenSubtitles is off. Turn it on in Settings and add an API key.".into(),
            )
            .into());
        }
        let tracks = crate::subtitles::fetch_for_title(
            &state.pool,
            &state.http,
            &state.config.live,
            title_id,
            &lang,
            season,
            episode,
            file_id,
        )
        .await?;
        Ok(tracks
            .into_iter()
            .map(|t| Subtitle {
                id: t.id,
                language: t.language,
                label: t.label,
                format: t.format,
                content: t.content,
            })
            .collect())
    }

    async fn set_favorite(
        &self,
        ctx: &Context<'_>,
        title_id: Uuid,
        favorite: bool,
    ) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        sqlx::query(
            r#"
            INSERT INTO user_progress (token_id, title_id, favorite, updated_at)
            VALUES ($1, $2, $3, now())
            ON CONFLICT (token_id, title_id) DO UPDATE SET favorite = EXCLUDED.favorite, updated_at = now()
            "#,
        )
        .bind(auth.token_id)
        .bind(title_id)
        .bind(favorite)
        .execute(&state.pool)
        .await?;
        Ok(MutationResult {
            success: true,
            message: if favorite { "favorited".into() } else { "unfavorited".into() },
        })
    }

    async fn set_watched(
        &self,
        ctx: &Context<'_>,
        title_id: Uuid,
        watched: bool,
    ) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        sqlx::query(
            r#"
            INSERT INTO user_progress (token_id, title_id, watched, position_ms, updated_at)
            VALUES ($1, $2, $3, CASE WHEN $3 THEN 0 ELSE 0 END, now())
            ON CONFLICT (token_id, title_id) DO UPDATE SET
                watched = EXCLUDED.watched,
                position_ms = CASE WHEN EXCLUDED.watched THEN 0 ELSE user_progress.position_ms END,
                updated_at = now()
            "#,
        )
        .bind(auth.token_id)
        .bind(title_id)
        .bind(watched)
        .execute(&state.pool)
        .await?;
        Ok(MutationResult {
            success: true,
            message: if watched { "marked watched".into() } else { "marked unwatched".into() },
        })
    }

    async fn update_progress(
        &self,
        ctx: &Context<'_>,
        title_id: Uuid,
        file_id: Option<Uuid>,
        episode_id: Option<Uuid>,
        position_ms: i64,
        duration_ms: Option<i64>,
    ) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        let kind: Option<String> = sqlx::query_scalar("SELECT kind FROM titles WHERE id = $1")
            .bind(title_id)
            .fetch_optional(&state.pool)
            .await?;
        let movie = kind.as_deref() == Some("movie") || kind.is_none();
        let watched = movie
            && duration_ms
                .map(|d| d > 0 && position_ms as f64 >= d as f64 * 0.9)
                .unwrap_or(false);
        sqlx::query(
            r#"
            INSERT INTO user_progress (token_id, title_id, episode_id, file_id, position_ms, duration_ms, watched, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, now())
            ON CONFLICT (token_id, title_id) DO UPDATE SET
                episode_id = COALESCE(EXCLUDED.episode_id, user_progress.episode_id),
                file_id = COALESCE(EXCLUDED.file_id, user_progress.file_id),
                position_ms = EXCLUDED.position_ms,
                duration_ms = COALESCE(EXCLUDED.duration_ms, user_progress.duration_ms),
                watched = EXCLUDED.watched,
                updated_at = now()
            "#,
        )
        .bind(auth.token_id)
        .bind(title_id)
        .bind(episode_id)
        .bind(file_id)
        .bind(position_ms.max(0))
        .bind(duration_ms)
        .bind(watched)
        .execute(&state.pool)
        .await?;
        Ok(MutationResult {
            success: true,
            message: "progress saved".into(),
        })
    }

    async fn test_jackett(&self, ctx: &Context<'_>) -> async_graphql::Result<MutationResult> {
        let state = ctx.data::<AppState>()?;
        let client = crate::jackett::JackettClient::from_live(&state.http, &state.config.live)?;
        match client.test_connection().await {
            Ok(true) => Ok(MutationResult {
                success: true,
                message: "Connected to Jackett.".into(),
            }),
            Ok(false) => Ok(MutationResult {
                success: false,
                message: "Jackett didn’t respond. Make sure it’s running and the URL is correct.".into(),
            }),
            Err(e) => Ok(MutationResult {
                success: false,
                message: e.to_string(),
            }),
        }
    }

    async fn start_stream(
        &self,
        ctx: &Context<'_>,
        magnet: String,
        title: String,
        title_id: Option<Uuid>,
        resume: Option<bool>,
        seeders: Option<i32>,
        peers: Option<i32>,
        season: Option<i32>,
        episode: Option<i32>,
    ) -> async_graphql::Result<StreamSession> {
        let state = ctx.data::<AppState>()?;
        if !state.config.live.jackett_enabled() {
            return Err(crate::error::AppError::BadRequest(
                "Jackett streaming is turned off. Enable it in Settings.".into(),
            )
            .into());
        }
        let magnet_key = crate::stream::StreamService::magnet_key(&magnet);
        let resume_pos = if resume.unwrap_or(true) {
            if let Some(tid) = title_id {
                let token_id = ctx
                    .data::<crate::auth::AuthSession>()
                    .ok()
                    .map(|a| a.token_id);
                crate::db::load_title_resume_for_token(&state.pool, tid, token_id).await?
            } else {
                crate::db::load_stream_resume(&state.pool, &magnet_key).await?
            }
        } else {
            0
        };
        let session = state
            .streams
            .start(
                magnet,
                title.clone(),
                resume_pos,
                state.config.live.streaming_resolution(),
                seeders.unwrap_or(0),
                peers.unwrap_or(0),
                season,
                episode,
            )
            .await?;
        if let Some(title_id) = title_id {
            let _ = crate::db::save_stream_resume(
                &state.pool,
                &magnet_key,
                Some(title_id),
                &title,
                resume_pos,
            )
            .await;
        }
        Ok(session)
    }

    async fn stream_resume(
        &self,
        ctx: &Context<'_>,
        session_id: String,
        position: i32,
        title_id: Option<Uuid>,
        title: Option<String>,
        magnet: Option<String>,
    ) -> async_graphql::Result<bool> {
        let state = ctx.data::<AppState>()?;
        let ok = state.streams.set_resume(&session_id, position as i64).await;
        if let Some(magnet) = magnet {
            let key = crate::stream::StreamService::magnet_key(&magnet);
            crate::db::save_stream_resume(
                &state.pool,
                &key,
                title_id,
                title.as_deref().unwrap_or(""),
                position as i64,
            )
            .await?;
        }
        Ok(ok)
    }

    async fn stop_stream(&self, ctx: &Context<'_>, session_id: String) -> async_graphql::Result<bool> {
        let state = ctx.data::<AppState>()?;
        Ok(state.streams.stop(&session_id).await)
    }

    async fn start_jackett_catalog(
        &self,
        _ctx: &Context<'_>,
    ) -> async_graphql::Result<MutationResult> {
        Ok(MutationResult {
            success: true,
            message: "Jackett is queried when you open a title. Listings are cached after that.".into(),
        })
    }
}

#[derive(InputObject)]
struct SettingsInput {
    tmdb_api_key: Option<String>,
    omdb_api_key: Option<String>,
    anilist_client_id: Option<String>,
    media_path: Option<String>,
    jackett_enabled: Option<bool>,
    jackett_url: Option<String>,
    jackett_api_key: Option<String>,
    streaming_resolution: Option<String>,
    opensubtitles_enabled: Option<bool>,
    opensubtitles_api_key: Option<String>,
}

async fn fetch_title(pool: &sqlx::PgPool, id: Uuid) -> sqlx::Result<crate::db::models::TitleRow> {
    sqlx::query_as(
        r#"
        SELECT id, kind, title, original_title, synopsis, description, year, runtime_minutes,
               poster_path, backdrop_path, logo_path, thumb_path, content_rating, tmdb_id, imdb_id, anilist_id,
               mal_id, metadata, created_at, updated_at, last_synced_at
        FROM titles WHERE id = $1
        "#,
    )
    .bind(id)
    .fetch_one(pool)
    .await
}
