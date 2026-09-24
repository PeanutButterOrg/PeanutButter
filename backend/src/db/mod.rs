pub mod models;

use std::path::Path;
use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tracing::info;
use uuid::Uuid;

use crate::error::{AppError, Result};

const EMBEDDED_MIGRATION: &str = include_str!("migrations/001_initial.sql");
const EMBEDDED_MIGRATION_002: &str = include_str!("migrations/002_rt_score.sql");
const EMBEDDED_MIGRATION_003: &str = include_str!("migrations/003_app_settings.sql");
const EMBEDDED_MIGRATION_004: &str = include_str!("migrations/004_app_token.sql");
const EMBEDDED_MIGRATION_005: &str = include_str!("migrations/005_subtitles.sql");
const EMBEDDED_MIGRATION_006: &str = include_str!("migrations/006_jellyfin_metadata.sql");
const EMBEDDED_MIGRATION_007: &str = include_str!("migrations/007_content_rating_audio.sql");
const EMBEDDED_MIGRATION_008: &str = include_str!("migrations/008_jackett_streaming.sql");
const EMBEDDED_MIGRATION_009: &str = include_str!("migrations/009_jackett_catalog.sql");
const EMBEDDED_MIGRATION_010: &str = include_str!("migrations/010_opensubtitles.sql");
const EMBEDDED_MIGRATION_011: &str = include_str!("migrations/011_device_tokens.sql");
const EMBEDDED_MIGRATION_012: &str = include_str!("migrations/012_admin_password.sql");
const EMBEDDED_MIGRATION_013: &str = include_str!("migrations/013_sync_progress.sql");
const EMBEDDED_MIGRATION_014: &str = include_str!("migrations/014_sync_workers.sql");
const EMBEDDED_MIGRATION_015: &str = include_str!("migrations/015_sync_logs.sql");
const EMBEDDED_MIGRATION_016: &str = include_str!("migrations/016_tmdb_id_kind_unique.sql");
const EMBEDDED_MIGRATION_017: &str = include_str!("migrations/017_preferred_languages.sql");
const EMBEDDED_MIGRATION_018: &str = include_str!("migrations/018_list_shelf_tags.sql");
const EMBEDDED_MIGRATION_019: &str = include_str!("migrations/019_tmdb_shelf_pages.sql");
const EMBEDDED_MIGRATION_020: &str = include_str!("migrations/020_block_adult_content.sql");
const EMBEDDED_MIGRATION_021: &str = include_str!("migrations/021_popcorn_sort_fields.sql");
const EMBEDDED_MIGRATION_022: &str = include_str!("migrations/022_hide_unreleased.sql");
const EMBEDDED_MIGRATION_023: &str = include_str!("migrations/023_episode_progress.sql");
const EMBEDDED_MIGRATION_024: &str = include_str!("migrations/024_stream_search_cache.sql");
const EMBEDDED_MIGRATION_025: &str = include_str!("migrations/025_stream_bookmark.sql");

pub async fn connect(database_url: &str) -> Result<PgPool> {
    connect_with(database_url, 40, 4, Duration::from_secs(15)).await
}

/// Pool for GraphQL / playback — fail fast so sync never starves clients.
pub async fn connect_api(database_url: &str) -> Result<PgPool> {
    connect_with(database_url, 24, 4, Duration::from_secs(5)).await
}

/// Dedicated pool for catalog sync / TMDB ingest so user queries keep capacity.
pub async fn connect_ingest(database_url: &str) -> Result<PgPool> {
    connect_with(database_url, 12, 1, Duration::from_secs(30)).await
}

async fn connect_with(
    database_url: &str,
    max: u32,
    min: u32,
    acquire: Duration,
) -> Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(max)
        .min_connections(min)
        .acquire_timeout(acquire)
        .idle_timeout(Duration::from_secs(300))
        .max_lifetime(Duration::from_secs(1800))
        .connect(database_url)
        .await?;
    Ok(pool)
}

pub async fn run_migrations(pool: &PgPool, extra_dir: Option<&Path>) -> Result<()> {
    info!("running database migrations");
    sqlx::query(
        r#"
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        "#,
    )
    .execute(pool)
    .await?;

    apply_one(pool, "001_initial", EMBEDDED_MIGRATION).await?;
    apply_one(pool, "002_rt_score", EMBEDDED_MIGRATION_002).await?;
    apply_one(pool, "003_app_settings", EMBEDDED_MIGRATION_003).await?;
    apply_one(pool, "004_app_token", EMBEDDED_MIGRATION_004).await?;
    apply_one(pool, "005_subtitles", EMBEDDED_MIGRATION_005).await?;
    apply_one(pool, "006_jellyfin_metadata", EMBEDDED_MIGRATION_006).await?;
    apply_one(pool, "007_content_rating_audio", EMBEDDED_MIGRATION_007).await?;
    apply_one(pool, "008_jackett_streaming", EMBEDDED_MIGRATION_008).await?;
    apply_one(pool, "009_jackett_catalog", EMBEDDED_MIGRATION_009).await?;
    apply_one(pool, "010_opensubtitles", EMBEDDED_MIGRATION_010).await?;
    apply_one(pool, "011_device_tokens", EMBEDDED_MIGRATION_011).await?;
    apply_one(pool, "012_admin_password", EMBEDDED_MIGRATION_012).await?;
    apply_one(pool, "013_sync_progress", EMBEDDED_MIGRATION_013).await?;
    apply_one(pool, "014_sync_workers", EMBEDDED_MIGRATION_014).await?;
    apply_one(pool, "015_sync_logs", EMBEDDED_MIGRATION_015).await?;
    apply_one(pool, "016_tmdb_id_kind_unique", EMBEDDED_MIGRATION_016).await?;
    apply_one(pool, "017_preferred_languages", EMBEDDED_MIGRATION_017).await?;
    apply_one(pool, "018_list_shelf_tags", EMBEDDED_MIGRATION_018).await?;
    apply_one(pool, "019_tmdb_shelf_pages", EMBEDDED_MIGRATION_019).await?;
    apply_one(pool, "020_block_adult_content", EMBEDDED_MIGRATION_020).await?;
    apply_one(pool, "021_popcorn_sort_fields", EMBEDDED_MIGRATION_021).await?;
    apply_one(pool, "022_hide_unreleased", EMBEDDED_MIGRATION_022).await?;
    apply_one(pool, "023_episode_progress", EMBEDDED_MIGRATION_023).await?;
    apply_one(pool, "024_stream_search_cache", EMBEDDED_MIGRATION_024).await?;
    apply_one(pool, "025_stream_bookmark", EMBEDDED_MIGRATION_025).await?;

    if let Some(dir) = extra_dir {
        if dir.is_dir() {
            let mut entries: Vec<_> = std::fs::read_dir(dir)?
                .filter_map(|e| e.ok())
                .collect();
            entries.sort_by_key(|e| e.path());
            for entry in entries {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("sql") {
                    continue;
                }
                let version = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("unknown")
                    .to_string();
                if version == "001_initial"
                    || version == "002_rt_score"
                    || version == "003_app_settings"
                    || version == "004_app_token"
                    || version == "005_subtitles"
                    || version == "006_jellyfin_metadata"
                    || version == "007_content_rating_audio"
                    || version == "008_jackett_streaming"
                    || version == "009_jackett_catalog"
                    || version == "010_opensubtitles"
                    || version == "011_device_tokens"
                    || version == "012_admin_password"
                    || version == "013_sync_progress"
                    || version == "014_sync_workers"
                    || version == "015_sync_logs"
                    || version == "016_tmdb_id_kind_unique"
                    || version == "017_preferred_languages"
                    || version == "018_list_shelf_tags"
                    || version == "019_tmdb_shelf_pages"
                    || version == "020_block_adult_content"
                    || version == "021_popcorn_sort_fields"
                    || version == "022_hide_unreleased"
                    || version == "023_episode_progress"
                    || version == "024_stream_search_cache"
                    || version == "025_stream_bookmark"
                {
                    continue;
                }
                let sql = std::fs::read_to_string(&path)?;
                apply_one(pool, &version, &sql).await?;
            }
        }
    }

    Ok(())
}

async fn apply_one(pool: &PgPool, version: &str, sql: &str) -> Result<()> {
    let already: Option<(String,)> =
        sqlx::query_as("SELECT version FROM schema_migrations WHERE version = $1")
            .bind(version)
            .fetch_optional(pool)
            .await?;
    if already.is_some() {
        return Ok(());
    }

    let mut tx = pool.begin().await?;
    sqlx::raw_sql(sql)
        .execute(&mut *tx)
        .await
        .map_err(|e| AppError::Internal(format!("migration {version} failed: {e}")))?;
    sqlx::query("INSERT INTO schema_migrations (version) VALUES ($1)")
        .bind(version)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    info!(version, "applied migration");
    Ok(())
}

pub async fn title_imdb_id(pool: &PgPool, title_id: Uuid) -> Result<Option<String>> {
    let row: Option<(Option<String>,)> =
        sqlx::query_as("SELECT imdb_id FROM titles WHERE id = $1")
            .bind(title_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.and_then(|(s,)| s))
}

#[derive(Debug, Clone)]
pub struct TitleStreamMeta {
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub imdb_id: Option<String>,
}

/// Metadata used to build precise Jackett torrent queries.
pub async fn title_stream_meta(pool: &PgPool, title_id: Uuid) -> Result<Option<TitleStreamMeta>> {
    let row: Option<(String, Option<String>, Option<i32>, Option<String>)> = sqlx::query_as(
        r#"
        SELECT title, original_title, year, imdb_id
        FROM titles
        WHERE id = $1
        "#,
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(title, original_title, year, imdb_id)| TitleStreamMeta {
        title,
        original_title,
        year,
        imdb_id,
    }))
}

pub async fn title_count(pool: &PgPool) -> Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM titles")
        .fetch_one(pool)
        .await?;
    Ok(count)
}

pub async fn title_count_for_kind(pool: &PgPool, kind: &str) -> Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM titles WHERE kind = $1")
        .bind(kind)
        .fetch_one(pool)
        .await?;
    Ok(count)
}

/// Highest TMDB list page already cached for a shelf/media pair.
pub async fn tmdb_shelf_max_page(pool: &PgPool, shelf: &str, media: &str) -> Result<i32> {
    let (max_page,): (Option<i32>,) = sqlx::query_as(
        r#"
        SELECT MAX(page) FROM tmdb_shelf_pages
        WHERE shelf = $1 AND media = $2
        "#,
    )
    .bind(shelf)
    .bind(media)
    .fetch_one(pool)
    .await?;
    Ok(max_page.unwrap_or(0))
}

/// TMDB-reported total pages for a shelf (from the latest synced page row).
pub async fn tmdb_shelf_total_pages(pool: &PgPool, shelf: &str, media: &str) -> Result<i32> {
    let row: Option<(i32,)> = sqlx::query_as(
        r#"
        SELECT total_pages FROM tmdb_shelf_pages
        WHERE shelf = $1 AND media = $2
        ORDER BY page DESC
        LIMIT 1
        "#,
    )
    .bind(shelf)
    .bind(media)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(t,)| t).unwrap_or(0))
}

pub async fn tmdb_shelf_page_synced(
    pool: &PgPool,
    shelf: &str,
    media: &str,
    page: i32,
) -> Result<bool> {
    let (exists,): (bool,) = sqlx::query_as(
        r#"
        SELECT EXISTS(
            SELECT 1 FROM tmdb_shelf_pages
            WHERE shelf = $1 AND media = $2 AND page = $3
        )
        "#,
    )
    .bind(shelf)
    .bind(media)
    .bind(page)
    .fetch_one(pool)
    .await?;
    Ok(exists)
}

pub async fn record_tmdb_shelf_page(
    pool: &PgPool,
    shelf: &str,
    media: &str,
    page: i32,
    total_pages: i32,
    item_count: i32,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO tmdb_shelf_pages (shelf, media, page, total_pages, item_count, synced_at)
        VALUES ($1, $2, $3, $4, $5, now())
        ON CONFLICT (shelf, media, page) DO UPDATE SET
            total_pages = EXCLUDED.total_pages,
            item_count = EXCLUDED.item_count,
            synced_at = now()
        "#,
    )
    .bind(shelf)
    .bind(media)
    .bind(page)
    .bind(total_pages.max(1))
    .bind(item_count.max(0))
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn set_sync_progress(
    pool: &PgPool,
    phase: &str,
    done: i32,
    total: i32,
) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE sync_state SET
            syncing = TRUE,
            phase = $1,
            progress_done = $2,
            progress_total = $3
        WHERE id = 1
        "#,
    )
    .bind(phase)
    .bind(done.max(0))
    .bind(total.max(0))
    .execute(pool)
    .await?;
    // Mirror progress into the Sync tab log (dedupe identical consecutive phases).
    let last: Option<(Option<String>,)> = sqlx::query_as(
        r#"
        SELECT phase FROM sync_logs
        ORDER BY id DESC
        LIMIT 1
        "#,
    )
    .fetch_optional(pool)
    .await
    .unwrap_or(None);
    let same = last
        .as_ref()
        .and_then(|r| r.0.as_deref())
        .is_some_and(|p| p == phase);
    if !same {
        let _ = append_sync_log(
            pool,
            "info",
            Some(phase.to_string()),
            format!("Progress {done}/{total}"),
        )
        .await;
    }
    Ok(())
}

pub async fn set_sync_workers(pool: &PgPool, workers: i32) -> Result<()> {
    sqlx::query("UPDATE sync_state SET workers_active = $1 WHERE id = 1")
        .bind(workers.max(0))
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn clear_sync_logs(pool: PgPool) -> Result<()> {
    sqlx::query("DELETE FROM sync_logs").execute(&pool).await?;
    Ok(())
}

pub async fn append_sync_log(
    pool: &PgPool,
    level: impl AsRef<str>,
    phase: Option<String>,
    message: impl AsRef<str>,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO sync_logs (level, phase, message)
        VALUES ($1, $2, $3)
        "#,
    )
    .bind(level.as_ref())
    .bind(phase)
    .bind(message.as_ref())
    .execute(pool)
    .await?;
    // Keep the log bounded so the Sync tab stays snappy.
    sqlx::query(
        r#"
        DELETE FROM sync_logs
        WHERE id < COALESCE(
            (SELECT id FROM sync_logs ORDER BY id DESC OFFSET 400 LIMIT 1),
            0
        )
        "#,
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn list_sync_logs(pool: &PgPool, limit: i64) -> Result<Vec<(chrono::DateTime<chrono::Utc>, String, Option<String>, String)>> {
    let rows = sqlx::query_as(
        r#"
        SELECT created_at, level, phase, message
        FROM sync_logs
        ORDER BY id DESC
        LIMIT $1
        "#,
    )
    .bind(limit.clamp(1, 500))
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

pub async fn bump_sync_progress(pool: &PgPool, by: i32) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE sync_state SET
            progress_done = LEAST(progress_total, progress_done + $1)
        WHERE id = 1
        "#,
    )
    .bind(by.max(0))
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn sync_state(pool: &PgPool) -> Result<crate::db::models::SyncStateRow> {
    let row = sqlx::query_as::<_, crate::db::models::SyncStateRow>(
        r#"
        SELECT id, last_sync_at, syncing, total_titles, last_error,
               phase, progress_done, progress_total, workers_active
        FROM sync_state WHERE id = 1
        "#,
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.unwrap_or(crate::db::models::SyncStateRow {
        id: 1,
        last_sync_at: None,
        syncing: false,
        total_titles: 0,
        last_error: None,
        phase: None,
        progress_done: 0,
        progress_total: 0,
        workers_active: 0,
    }))
}

pub async fn genre_names_for_title(pool: &PgPool, title_id: Uuid) -> Result<Vec<String>> {
    let rows: Vec<(String,)> = sqlx::query_as(
        r#"
        SELECT g.name
        FROM genres g
        JOIN title_genres tg ON tg.genre_id = g.id
        WHERE tg.title_id = $1
        ORDER BY g.name
        "#,
    )
    .bind(title_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(n,)| n).collect())
}

pub async fn all_genre_names(pool: &PgPool) -> Result<Vec<String>> {
    let rows: Vec<(String,)> = sqlx::query_as("SELECT name FROM genres ORDER BY name")
        .fetch_all(pool)
        .await?;
    Ok(rows
        .into_iter()
        .map(|(n,)| n)
        .filter(|n| !crate::content_filter::is_blocked_genre(n))
        .collect())
}

#[derive(sqlx::FromRow)]
struct SettingsRow {
    tmdb_api_key: String,
    omdb_api_key: String,
    anilist_client_id: Option<String>,
    media_path: Option<String>,
    jackett_enabled: bool,
    jackett_url: Option<String>,
    jackett_api_key: Option<String>,
    streaming_resolution: String,
    preferred_languages: String,
    opensubtitles_enabled: bool,
    opensubtitles_api_key: Option<String>,
}

pub async fn overlay_saved_settings(pool: &PgPool, config: &crate::config::Config) -> Result<()> {
    let row: Option<SettingsRow> = sqlx::query_as(
        r#"
        SELECT tmdb_api_key, omdb_api_key, anilist_client_id, media_path,
               jackett_enabled, jackett_url, jackett_api_key, streaming_resolution,
               preferred_languages,
               opensubtitles_enabled, opensubtitles_api_key
        FROM app_settings WHERE id = 1
        "#,
    )
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(());
    };
    config.live.apply(
        if row.tmdb_api_key.trim().is_empty() {
            None
        } else {
            Some(row.tmdb_api_key)
        },
        if row.omdb_api_key.trim().is_empty() {
            None
        } else {
            Some(row.omdb_api_key)
        },
        row.anilist_client_id
            .filter(|s| !s.trim().is_empty())
            .map(Some),
        row.media_path
            .filter(|s| !s.trim().is_empty())
            .map(std::path::PathBuf::from),
    );
    config.live.apply_streaming(
        Some(row.jackett_enabled),
        Some(row.jackett_url.filter(|s| !s.trim().is_empty())),
        Some(row.jackett_api_key.filter(|s| !s.trim().is_empty())),
        Some(row.streaming_resolution),
        Some(row.preferred_languages),
    );
    config.live.apply_opensubtitles(
        Some(row.opensubtitles_enabled),
        Some(row.opensubtitles_api_key.filter(|s| !s.trim().is_empty())),
    );
    Ok(())
}

pub async fn ensure_app_token(pool: &PgPool, config: &crate::config::Config) -> Result<String> {
    let env_token = config
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);
    let db_token: Option<String> = sqlx::query_scalar(
        "SELECT NULLIF(BTRIM(app_token), '') FROM app_settings WHERE id = 1",
    )
    .fetch_optional(pool)
    .await?
    .flatten();

    let token = match env_token.or(db_token) {
        Some(existing) if crate::pin::is_pairing_code(&existing) => {
            crate::pin::normalize_code(&existing)
        }
        _ => unique_pairing_code(pool).await?,
    };

    sqlx::query(
        r#"
        INSERT INTO app_settings (id, app_token, updated_at)
        VALUES (1, $1, now())
        ON CONFLICT (id) DO UPDATE SET
            app_token = EXCLUDED.app_token,
            updated_at = now()
        "#,
    )
    .bind(&token)
    .execute(pool)
    .await?;

    config.live.set_app_token(token.clone());
    ensure_device_tokens(pool, &token).await?;
    info!(
        code = %crate::pin::format_code(&token),
        "pairing: sign in at / to add TVs (6-digit codes); set ADMIN_PASSWORD to choose the console password"
    );
    Ok(token)
}

pub fn hash_admin_password(password: &str, salt: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(b":");
    hasher.update(password.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn new_admin_password_hash(password: &str) -> String {
    let salt = hex::encode(Uuid::new_v4().as_bytes());
    format!("{}${ }", salt, hash_admin_password(password, &salt))
}

pub fn admin_password_matches(password: &str, stored: &str) -> bool {
    let Some((salt, expected)) = stored.split_once('$') else {
        return false;
    };
    crate::auth::token_matches(&hash_admin_password(password, salt), expected)
}

pub fn admin_session_token(password_hash: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(password_hash.as_bytes());
    hasher.update(b"|pb-admin-session-v1");
    hex::encode(hasher.finalize())
}

fn random_admin_password() -> String {
    let b = Uuid::new_v4();
    let hex = hex::encode(b.as_bytes());
    hex.chars().take(12).collect()
}

pub async fn ensure_admin_password(pool: &PgPool) -> Result<()> {
    let env_pw = std::env::var("ADMIN_PASSWORD")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let stored: Option<String> = sqlx::query_scalar(
        "SELECT NULLIF(BTRIM(admin_password_hash), '') FROM app_settings WHERE id = 1",
    )
    .fetch_optional(pool)
    .await?
    .flatten();

    if let Some(password) = env_pw {
        let hash = new_admin_password_hash(&password);
        sqlx::query(
            r#"
            INSERT INTO app_settings (id, admin_password_hash, updated_at)
            VALUES (1, $1, now())
            ON CONFLICT (id) DO UPDATE SET
                admin_password_hash = EXCLUDED.admin_password_hash,
                updated_at = now()
            "#,
        )
        .bind(&hash)
        .execute(pool)
        .await?;
        info!("admin UI password loaded from ADMIN_PASSWORD");
        return Ok(());
    }
    if stored.is_some() {
        return Ok(());
    }
    let generated = random_admin_password();
    let hash = new_admin_password_hash(&generated);
    sqlx::query(
        r#"
        INSERT INTO app_settings (id, admin_password_hash, updated_at)
        VALUES (1, $1, now())
        ON CONFLICT (id) DO UPDATE SET
            admin_password_hash = COALESCE(app_settings.admin_password_hash, EXCLUDED.admin_password_hash),
            updated_at = now()
        "#,
    )
    .bind(&hash)
    .execute(pool)
    .await?;
    info!(
        password = %generated,
        "admin UI password generated — set ADMIN_PASSWORD to choose your own"
    );
    Ok(())
}

pub async fn admin_password_hash(pool: &PgPool) -> Result<Option<String>> {
    Ok(sqlx::query_scalar(
        "SELECT NULLIF(BTRIM(admin_password_hash), '') FROM app_settings WHERE id = 1",
    )
    .fetch_optional(pool)
    .await?
    .flatten())
}

pub async fn set_admin_password(pool: &PgPool, password: &str) -> Result<()> {
    let hash = new_admin_password_hash(password);
    sqlx::query(
        r#"
        UPDATE app_settings SET admin_password_hash = $1, updated_at = now() WHERE id = 1
        "#,
    )
    .bind(&hash)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct DeviceTokenRow {
    pub id: Uuid,
    pub name: String,
    pub token: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

pub async fn ensure_device_tokens(pool: &PgPool, admin_token: &str) -> Result<()> {
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM device_tokens")
        .fetch_one(pool)
        .await?;
    if count == 0 {
        sqlx::query(
            r#"
            INSERT INTO device_tokens (name, token)
            VALUES ('Default', $1)
            ON CONFLICT (token) DO NOTHING
            "#,
        )
        .bind(admin_token)
        .execute(pool)
        .await?;
    } else {
        // Keep a Default row that mirrors the admin pairing code.
        let exists: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM device_tokens WHERE token = $1 LIMIT 1",
        )
        .bind(admin_token)
        .fetch_optional(pool)
        .await?;
        if exists.is_none() {
            sqlx::query(
                r#"
                UPDATE device_tokens
                SET token = $1
                WHERE name = 'Default'
                  AND NOT EXISTS (SELECT 1 FROM device_tokens WHERE token = $1)
                "#,
            )
            .bind(admin_token)
            .execute(pool)
            .await?;
            sqlx::query(
                r#"
                INSERT INTO device_tokens (name, token)
                VALUES ('Default', $1)
                ON CONFLICT (token) DO NOTHING
                "#,
            )
            .bind(admin_token)
            .execute(pool)
            .await?;
        }
    }

    let default_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM device_tokens WHERE token = $1 OR name = 'Default' ORDER BY created_at ASC LIMIT 1",
    )
    .bind(admin_token)
    .fetch_one(pool)
    .await?;

    sqlx::query("UPDATE user_progress SET token_id = $1 WHERE token_id IS NULL")
        .bind(default_id)
        .execute(pool)
        .await?;

    // Finalize composite primary key once all rows have a token_id.
    let nulls: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_progress WHERE token_id IS NULL")
        .fetch_one(pool)
        .await?;
    if nulls == 0 {
        sqlx::query(
            r#"
            DO $$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.table_constraints
                    WHERE table_name = 'user_progress'
                      AND constraint_name = 'user_progress_token_title_pkey'
                ) THEN
                    ALTER TABLE user_progress
                        ALTER COLUMN token_id SET NOT NULL;
                    ALTER TABLE user_progress
                        ADD CONSTRAINT user_progress_token_title_pkey PRIMARY KEY (token_id, title_id);
                END IF;
            END $$;
            "#,
        )
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn default_device_token(pool: &PgPool) -> Result<(Uuid, String)> {
    let row: (Uuid, String) = sqlx::query_as(
        "SELECT id, name FROM device_tokens ORDER BY created_at ASC LIMIT 1",
    )
    .fetch_one(pool)
    .await?;
    Ok(row)
}

pub async fn unique_pairing_code(pool: &PgPool) -> Result<String> {
    for _ in 0..32 {
        let pin = crate::pin::random_code();
        let taken: bool = sqlx::query_scalar(
            r#"
            SELECT EXISTS(SELECT 1 FROM device_tokens WHERE token = $1)
                OR EXISTS(SELECT 1 FROM app_settings WHERE app_token = $1)
            "#,
        )
        .bind(&pin)
        .fetch_one(pool)
        .await?;
        if !taken {
            return Ok(pin);
        }
    }
    Err(AppError::Internal("could not allocate a pairing code".into()))
}

pub async fn find_device_token(pool: &PgPool, token: &str) -> Result<Option<(Uuid, String)>> {
    let code = crate::pin::normalize_code(token);
    let row: Option<(Uuid, String)> = sqlx::query_as(
        "SELECT id, name FROM device_tokens WHERE token = $1 LIMIT 1",
    )
    .bind(code)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

pub async fn list_device_tokens(pool: &PgPool) -> Result<Vec<DeviceTokenRow>> {
    let rows = sqlx::query_as::<_, DeviceTokenRow>(
        "SELECT id, name, token, created_at FROM device_tokens ORDER BY created_at ASC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

pub async fn create_device_token(pool: &PgPool, name: &str) -> Result<DeviceTokenRow> {
    let token = unique_pairing_code(pool).await?;
    let row = sqlx::query_as::<_, DeviceTokenRow>(
        r#"
        INSERT INTO device_tokens (name, token)
        VALUES ($1, $2)
        RETURNING id, name, token, created_at
        "#,
    )
    .bind(name)
    .bind(token)
    .fetch_one(pool)
    .await?;
    Ok(row)
}

pub async fn revoke_device_token(pool: &PgPool, id: Uuid) -> Result<()> {
    sqlx::query("DELETE FROM device_tokens WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn save_settings(
    pool: &PgPool,
    tmdb: Option<&str>,
    omdb: Option<&str>,
    anilist: Option<Option<&str>>,
    media_path: Option<&str>,
    jackett_enabled: Option<bool>,
    jackett_url: Option<&str>,
    jackett_api_key: Option<&str>,
    streaming_resolution: Option<&str>,
    opensubtitles_enabled: Option<bool>,
    opensubtitles_api_key: Option<&str>,
    preferred_languages: Option<&str>,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO app_settings (
            id, tmdb_api_key, omdb_api_key, anilist_client_id, media_path,
            jackett_enabled, jackett_url, jackett_api_key, streaming_resolution,
            opensubtitles_enabled, opensubtitles_api_key, preferred_languages, updated_at
        )
        VALUES (
            1, COALESCE($1, ''), COALESCE($2, ''), $3, $4,
            COALESCE($5, FALSE), $6, $7, COALESCE($8, '1080p'),
            COALESCE($9, FALSE), $10, COALESCE($11, 'en'), now()
        )
        ON CONFLICT (id) DO UPDATE SET
            tmdb_api_key = COALESCE($1, app_settings.tmdb_api_key),
            omdb_api_key = COALESCE($2, app_settings.omdb_api_key),
            anilist_client_id = COALESCE($3, app_settings.anilist_client_id),
            media_path = COALESCE($4, app_settings.media_path),
            jackett_enabled = COALESCE($5, app_settings.jackett_enabled),
            jackett_url = COALESCE($6, app_settings.jackett_url),
            jackett_api_key = COALESCE($7, app_settings.jackett_api_key),
            streaming_resolution = COALESCE($8, app_settings.streaming_resolution),
            opensubtitles_enabled = COALESCE($9, app_settings.opensubtitles_enabled),
            opensubtitles_api_key = COALESCE($10, app_settings.opensubtitles_api_key),
            preferred_languages = COALESCE($11, app_settings.preferred_languages),
            updated_at = now()
        "#,
    )
    .bind(tmdb)
    .bind(omdb)
    .bind(anilist.flatten())
    .bind(media_path)
    .bind(jackett_enabled)
    .bind(jackett_url)
    .bind(jackett_api_key)
    .bind(streaming_resolution)
    .bind(opensubtitles_enabled)
    .bind(opensubtitles_api_key)
    .bind(preferred_languages)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn load_stream_resume(pool: &PgPool, magnet_key: &str) -> Result<i64> {
    let pos: Option<i64> = sqlx::query_scalar(
        "SELECT resume_position FROM stream_progress WHERE magnet_key = $1",
    )
    .bind(magnet_key)
    .fetch_optional(pool)
    .await?;
    Ok(pos.unwrap_or(0))
}

/// Resume for a title regardless of which magnet the user picks.
pub async fn load_title_resume(pool: &PgPool, title_id: Uuid) -> Result<i64> {
    load_title_resume_for_token(pool, title_id, None).await
}

pub async fn load_title_resume_for_token(
    pool: &PgPool,
    title_id: Uuid,
    token_id: Option<Uuid>,
) -> Result<i64> {
    let user: Option<i64> = if let Some(token_id) = token_id {
        sqlx::query_scalar(
            r#"
            SELECT position_ms FROM user_progress
            WHERE token_id = $1 AND title_id = $2 AND COALESCE(watched, FALSE) = FALSE
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(token_id)
        .bind(title_id)
        .fetch_optional(pool)
        .await?
    } else {
        sqlx::query_scalar(
            r#"
            SELECT position_ms FROM user_progress
            WHERE title_id = $1 AND COALESCE(watched, FALSE) = FALSE
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(title_id)
        .fetch_optional(pool)
        .await?
    };
    let stream: Option<i64> = sqlx::query_scalar(
        r#"
        SELECT resume_position FROM stream_progress
        WHERE title_id = $1
        ORDER BY updated_at DESC
        LIMIT 1
        "#,
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?;
    Ok(user.unwrap_or(0).max(stream.unwrap_or(0)))
}

pub async fn save_stream_resume(
    pool: &PgPool,
    magnet_key: &str,
    title_id: Option<Uuid>,
    title: &str,
    position: i64,
    magnet: Option<&str>,
    season: Option<i32>,
    episode: Option<i32>,
    file_index: Option<i32>,
) -> Result<()> {
    let magnet_uri = magnet.unwrap_or("").trim();
    sqlx::query(
        r#"
        INSERT INTO stream_progress (
            magnet_key, title_id, title, resume_position, updated_at,
            magnet, season, episode, file_index
        )
        VALUES ($1, $2, $3, $4, now(), $5, $6, $7, $8)
        ON CONFLICT (magnet_key) DO UPDATE SET
            title_id = COALESCE(EXCLUDED.title_id, stream_progress.title_id),
            title = EXCLUDED.title,
            resume_position = EXCLUDED.resume_position,
            updated_at = now(),
            magnet = CASE
                WHEN EXCLUDED.magnet <> '' THEN EXCLUDED.magnet
                ELSE stream_progress.magnet
            END,
            season = COALESCE(EXCLUDED.season, stream_progress.season),
            episode = COALESCE(EXCLUDED.episode, stream_progress.episode),
            file_index = COALESCE(EXCLUDED.file_index, stream_progress.file_index)
        "#,
    )
    .bind(magnet_key)
    .bind(title_id)
    .bind(title)
    .bind(position.max(0))
    .bind(magnet_uri)
    .bind(season)
    .bind(episode)
    .bind(file_index)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct StreamBookmarkRow {
    pub magnet: String,
    pub resume_position: i64,
    pub season: Option<i32>,
    pub episode: Option<i32>,
    pub file_index: Option<i32>,
}

/// Last torrent used for this title (and optional SxxExx). Empty magnet = none.
pub async fn load_stream_bookmark(
    pool: &PgPool,
    title_id: Uuid,
    season: Option<i32>,
    episode: Option<i32>,
) -> Result<Option<StreamBookmarkRow>> {
    // Prefer an exact season/episode match (series resume).
    let exact: Option<StreamBookmarkRow> = sqlx::query_as(
        r#"
        SELECT magnet, resume_position, season, episode, file_index
        FROM stream_progress
        WHERE title_id = $1
          AND COALESCE(magnet, '') <> ''
          AND season IS NOT DISTINCT FROM $2
          AND episode IS NOT DISTINCT FROM $3
        ORDER BY updated_at DESC
        LIMIT 1
        "#,
    )
    .bind(title_id)
    .bind(season)
    .bind(episode)
    .fetch_optional(pool)
    .await?;
    if exact.is_some() {
        return Ok(exact);
    }

    // Movies (and legacy rows): accept the newest magnet for this title when the
    // client omitted S/E or an older session stored S01E01 by mistake.
    if season.is_none() && episode.is_none() {
        let any: Option<StreamBookmarkRow> = sqlx::query_as(
            r#"
            SELECT magnet, resume_position, season, episode, file_index
            FROM stream_progress
            WHERE title_id = $1
              AND COALESCE(magnet, '') <> ''
            ORDER BY updated_at DESC
            LIMIT 1
            "#,
        )
        .bind(title_id)
        .fetch_optional(pool)
        .await?;
        return Ok(any);
    }

    Ok(None)
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct JackettListingRow {
    pub id: Uuid,
    pub magnet: String,
    pub torrent_title: String,
    pub seeders: i32,
    pub peers: i32,
    pub rating: i32,
    pub health: String,
    pub size: String,
    pub tracker: String,
    pub indexer: String,
    pub language: String,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct JackettSyncRow {
    pub syncing: bool,
    pub last_full_sync_at: Option<chrono::DateTime<chrono::Utc>>,
    #[allow(dead_code)]
    pub last_update_at: Option<chrono::DateTime<chrono::Utc>>,
    pub titles_done: i32,
    pub titles_total: i32,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct JackettTitleWork {
    pub id: Uuid,
    pub title: String,
    pub kind: String,
    pub year: Option<i32>,
}

pub async fn jackett_sync_status(pool: &PgPool) -> Result<JackettSyncRow> {
    let row: Option<JackettSyncRow> = sqlx::query_as(
        r#"
        SELECT syncing, last_full_sync_at, last_update_at, titles_done, titles_total, last_error
        FROM jackett_sync_state WHERE id = 1
        "#,
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.unwrap_or(JackettSyncRow {
        syncing: false,
        last_full_sync_at: None,
        last_update_at: None,
        titles_done: 0,
        titles_total: 0,
        last_error: None,
    }))
}

pub async fn jackett_begin_sync(pool: &PgPool, total: i32, reset_progress: bool) -> Result<()> {
    if reset_progress {
        sqlx::query(
            r#"
            UPDATE jackett_sync_state SET
                syncing = TRUE,
                titles_done = 0,
                titles_total = $1,
                last_error = NULL
            WHERE id = 1
            "#,
        )
        .bind(total)
        .execute(pool)
        .await?;
    } else {
        sqlx::query(
            r#"
            UPDATE jackett_sync_state SET
                syncing = TRUE,
                titles_total = GREATEST(titles_total, $1),
                last_error = NULL
            WHERE id = 1
            "#,
        )
        .bind(total)
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn jackett_bump_progress(pool: &PgPool, done: i32, total: i32) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE jackett_sync_state SET
            titles_done = $1,
            titles_total = $2,
            last_update_at = now()
        WHERE id = 1
        "#,
    )
    .bind(done)
    .bind(total)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn jackett_finish_sync(pool: &PgPool, full: bool, error: Option<&str>) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE jackett_sync_state SET
            syncing = FALSE,
            last_full_sync_at = CASE
                WHEN $2 OR last_full_sync_at IS NULL THEN now()
                ELSE last_full_sync_at
            END,
            last_update_at = now(),
            last_error = $1
        WHERE id = 1
        "#,
    )
    .bind(error)
    .bind(full)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn jackett_reset_checked(pool: &PgPool) -> Result<()> {
    sqlx::query("UPDATE titles SET jackett_checked_at = NULL")
        .execute(pool)
        .await?;
    sqlx::query(
        r#"
        UPDATE jackett_sync_state SET
            last_full_sync_at = NULL,
            titles_done = 0,
            last_error = NULL
        WHERE id = 1
        "#,
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn jackett_pending_titles(pool: &PgPool, stale_hours: i32, limit: i64) -> Result<Vec<JackettTitleWork>> {
    Ok(sqlx::query_as(
        r#"
        SELECT id, title, kind, year
        FROM titles
        WHERE jackett_checked_at IS NULL
           OR ($1 > 0 AND jackett_checked_at < now() - make_interval(hours => $1))
        ORDER BY jackett_checked_at NULLS FIRST, updated_at DESC
        LIMIT $2
        "#,
    )
    .bind(stale_hours)
    .bind(limit)
    .fetch_all(pool)
    .await?)
}

pub async fn jackett_mark_checked(pool: &PgPool, title_id: Uuid) -> Result<()> {
    sqlx::query("UPDATE titles SET jackett_checked_at = now() WHERE id = $1")
        .bind(title_id)
        .execute(pool)
        .await?;
    Ok(())
}

#[allow(dead_code)]
pub async fn jackett_is_checked(pool: &PgPool, title_id: Uuid) -> Result<bool> {
    let at: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
        "SELECT jackett_checked_at FROM titles WHERE id = $1",
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?
    .flatten();
    Ok(at.is_some())
}

pub async fn jackett_checked_count(pool: &PgPool) -> Result<i32> {
    let n: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::bigint FROM titles WHERE jackett_checked_at IS NOT NULL",
    )
    .fetch_one(pool)
    .await?;
    Ok(n as i32)
}

pub async fn replace_jackett_listings(
    pool: &PgPool,
    title_id: Uuid,
    listings: &[JackettListingRow],
) -> Result<()> {
    sqlx::query("DELETE FROM jackett_listings WHERE title_id = $1")
        .bind(title_id)
        .execute(pool)
        .await?;
    for row in listings {
        sqlx::query(
            r#"
            INSERT INTO jackett_listings (
                id, title_id, magnet, torrent_title, seeders, peers, rating, health,
                size, tracker, indexer, language, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
            ON CONFLICT (title_id, magnet) DO UPDATE SET
                torrent_title = EXCLUDED.torrent_title,
                seeders = EXCLUDED.seeders,
                peers = EXCLUDED.peers,
                rating = EXCLUDED.rating,
                health = EXCLUDED.health,
                size = EXCLUDED.size,
                tracker = EXCLUDED.tracker,
                indexer = EXCLUDED.indexer,
                language = EXCLUDED.language,
                updated_at = now()
            "#,
        )
        .bind(row.id)
        .bind(title_id)
        .bind(&row.magnet)
        .bind(&row.torrent_title)
        .bind(row.seeders)
        .bind(row.peers)
        .bind(row.rating)
        .bind(&row.health)
        .bind(&row.size)
        .bind(&row.tracker)
        .bind(&row.indexer)
        .bind(&row.language)
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn upsert_jackett_listings(
    pool: &PgPool,
    title_id: Uuid,
    listings: &[JackettListingRow],
) -> Result<()> {
    for row in listings {
        sqlx::query(
            r#"
            INSERT INTO jackett_listings (
                id, title_id, magnet, torrent_title, seeders, peers, rating, health,
                size, tracker, indexer, language, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
            ON CONFLICT (title_id, magnet) DO UPDATE SET
                torrent_title = EXCLUDED.torrent_title,
                seeders = EXCLUDED.seeders,
                peers = EXCLUDED.peers,
                rating = EXCLUDED.rating,
                health = EXCLUDED.health,
                size = EXCLUDED.size,
                tracker = EXCLUDED.tracker,
                indexer = EXCLUDED.indexer,
                language = EXCLUDED.language,
                updated_at = now()
            "#,
        )
        .bind(row.id)
        .bind(title_id)
        .bind(&row.magnet)
        .bind(&row.torrent_title)
        .bind(row.seeders)
        .bind(row.peers)
        .bind(row.rating)
        .bind(&row.health)
        .bind(&row.size)
        .bind(&row.tracker)
        .bind(&row.indexer)
        .bind(&row.language)
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn jackett_listings_for_title(pool: &PgPool, title_id: Uuid) -> Result<Vec<JackettListingRow>> {
    Ok(sqlx::query_as(
        r#"
        SELECT id, magnet, torrent_title, seeders, peers, rating, health, size, tracker, indexer, language
        FROM jackett_listings
        WHERE title_id = $1 AND seeders >= 2
        ORDER BY seeders DESC
        LIMIT 40
        "#,
    )
    .bind(title_id)
    .fetch_all(pool)
    .await?)
}

/// Cache key for stream picker results (title + optional S/E, else query text).
pub fn stream_search_cache_key(
    title_id: Option<Uuid>,
    query: &str,
    kind: &str,
    season: Option<i32>,
    episode: Option<i32>,
) -> String {
    let s = season.unwrap_or(0);
    let e = episode.unwrap_or(0);
    if let Some(id) = title_id {
        format!("title:{id}:{s}:{e}")
    } else {
        let q = query.trim().to_ascii_lowercase();
        format!("query:{kind}:{q}:{s}:{e}")
    }
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct StreamSearchCacheRow {
    pub sources: serde_json::Value,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

/// Fresh cache hit: sources updated within `max_age`.
pub async fn stream_search_cache_get(
    pool: &PgPool,
    cache_key: &str,
    max_age: Duration,
) -> Result<Option<serde_json::Value>> {
    let row: Option<StreamSearchCacheRow> = sqlx::query_as(
        r#"
        SELECT sources, updated_at
        FROM stream_search_cache
        WHERE cache_key = $1
        "#,
    )
    .bind(cache_key)
    .fetch_optional(pool)
    .await?;
    let Some(row) = row else {
        return Ok(None);
    };
    let age = chrono::Utc::now()
        .signed_duration_since(row.updated_at)
        .to_std()
        .unwrap_or(Duration::from_secs(u64::MAX));
    if age > max_age {
        return Ok(None);
    }
    Ok(Some(row.sources))
}

pub async fn stream_search_cache_upsert(
    pool: &PgPool,
    cache_key: &str,
    title_id: Option<Uuid>,
    season: Option<i32>,
    episode: Option<i32>,
    sources: &serde_json::Value,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO stream_search_cache (cache_key, title_id, season, episode, sources, updated_at)
        VALUES ($1, $2, $3, $4, $5, now())
        ON CONFLICT (cache_key) DO UPDATE SET
            title_id = EXCLUDED.title_id,
            season = EXCLUDED.season,
            episode = EXCLUDED.episode,
            sources = EXCLUDED.sources,
            updated_at = now()
        "#,
    )
    .bind(cache_key)
    .bind(title_id)
    .bind(season)
    .bind(episode)
    .bind(sources)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn stream_search_cache_delete_key(pool: &PgPool, cache_key: &str) -> Result<()> {
    sqlx::query("DELETE FROM stream_search_cache WHERE cache_key = $1")
        .bind(cache_key)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn stream_search_cache_delete_title(pool: &PgPool, title_id: Uuid) -> Result<()> {
    sqlx::query("DELETE FROM stream_search_cache WHERE title_id = $1")
        .bind(title_id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Create Season 1 + numbered episodes when a series/anime has no episode list yet.
pub async fn ensure_episode_list(pool: &PgPool, title_id: Uuid, episode_count: i32) -> Result<()> {
    let count = episode_count.clamp(1, 200);
    let existing: Option<(Uuid,)> =
        sqlx::query_as("SELECT id FROM seasons WHERE title_id = $1 AND season_number = 1 LIMIT 1")
            .bind(title_id)
            .fetch_optional(pool)
            .await?;
    let season_id = if let Some((id,)) = existing {
        id
    } else {
        let (id,): (Uuid,) = sqlx::query_as(
            r#"
            INSERT INTO seasons (title_id, season_number, name, episode_count)
            VALUES ($1, 1, 'Season 1', $2)
            ON CONFLICT (title_id, season_number) DO UPDATE SET
                episode_count = GREATEST(COALESCE(seasons.episode_count, 0), EXCLUDED.episode_count)
            RETURNING id
            "#,
        )
        .bind(title_id)
        .bind(count)
        .fetch_one(pool)
        .await?;
        id
    };
    sqlx::query("UPDATE seasons SET episode_count = GREATEST(COALESCE(episode_count, 0), $2) WHERE id = $1")
        .bind(season_id)
        .bind(count)
        .execute(pool)
        .await?;
    for n in 1..=count {
        sqlx::query(
            r#"
            INSERT INTO episodes (season_id, episode_number, name)
            VALUES ($1, $2, $3)
            ON CONFLICT (season_id, episode_number) DO NOTHING
            "#,
        )
        .bind(season_id)
        .bind(n)
        .bind(format!("Episode {n}"))
        .execute(pool)
        .await?;
    }
    Ok(())
}

pub async fn fill_season_episodes(pool: &PgPool, season_id: Uuid, episode_count: i32) -> Result<()> {
    let count = episode_count.clamp(1, 200);
    for n in 1..=count {
        sqlx::query(
            r#"
            INSERT INTO episodes (season_id, episode_number, name)
            VALUES ($1, $2, $3)
            ON CONFLICT (season_id, episode_number) DO NOTHING
            "#,
        )
        .bind(season_id)
        .bind(n)
        .bind(format!("Episode {n}"))
        .execute(pool)
        .await?;
    }
    Ok(())
}

/// Wipe catalog data. Keeps console password, Jackett settings, and device pairing codes.
pub async fn clear_catalog(pool: &PgPool) -> Result<u64> {
    let mut tx = pool.begin().await?;
    let deleted = sqlx::query("DELETE FROM titles")
        .execute(&mut *tx)
        .await?
        .rows_affected();
    sqlx::query("DELETE FROM stream_progress")
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        r#"
        UPDATE sync_state SET
            last_sync_at = NULL,
            syncing = FALSE,
            total_titles = 0,
            last_error = NULL,
            phase = NULL,
            progress_done = 0,
            progress_total = 0,
            workers_active = 0
        WHERE id = 1
        "#,
    )
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        r#"
        UPDATE jackett_sync_state SET
            syncing = FALSE,
            last_full_sync_at = NULL,
            last_update_at = NULL,
            titles_done = 0,
            titles_total = 0,
            last_error = NULL
        WHERE id = 1
        "#,
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(deleted)
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct CatalogListRow {
    pub id: Uuid,
    pub title: String,
    pub kind: String,
    pub year: Option<i32>,
}

/// 0–1 progress for poster bars.
/// Movies: position/duration.
/// Series/anime: (episodes before current + in-episode fraction) / total episodes.
pub async fn title_progress_percent(
    pool: &PgPool,
    title_id: Uuid,
    episode_id: Option<Uuid>,
    position_ms: i64,
    duration_ms: Option<i64>,
    watched: bool,
) -> Result<f64> {
    if watched {
        return Ok(1.0);
    }
    let kind: Option<String> = sqlx::query_scalar("SELECT kind FROM titles WHERE id = $1")
        .bind(title_id)
        .fetch_optional(pool)
        .await?;
    let kind = kind.unwrap_or_default();
    let ep_frac = match duration_ms.filter(|d| *d > 0) {
        Some(d) => (position_ms as f64 / d as f64).clamp(0.0, 1.0),
        None => {
            if position_ms > 2000 {
                0.05
            } else {
                0.0
            }
        }
    };
    if kind != "series" && kind != "anime" {
        return Ok(ep_frac);
    }
    let total: i64 = sqlx::query_scalar(
        r#"
        SELECT COUNT(*)::bigint
        FROM episodes e
        JOIN seasons s ON s.id = e.season_id
        WHERE s.title_id = $1 AND s.season_number > 0
        "#,
    )
    .bind(title_id)
    .fetch_one(pool)
    .await?;
    if total <= 0 {
        return Ok(ep_frac);
    }
    let Some(eid) = episode_id else {
        return Ok((ep_frac / total as f64).clamp(0.0, 0.99));
    };
    let idx: Option<i64> = sqlx::query_scalar(
        r#"
        WITH ordered AS (
            SELECT e.id,
                   ROW_NUMBER() OVER (ORDER BY s.season_number ASC, e.episode_number ASC) AS rn
            FROM episodes e
            JOIN seasons s ON s.id = e.season_id
            WHERE s.title_id = $1 AND s.season_number > 0
        )
        SELECT rn FROM ordered WHERE id = $2
        "#,
    )
    .bind(title_id)
    .bind(eid)
    .fetch_optional(pool)
    .await?;
    let Some(rn) = idx else {
        return Ok(ep_frac.clamp(0.0, 0.99));
    };
    let done_before = (rn - 1).max(0) as f64;
    Ok(((done_before + ep_frac) / total as f64).clamp(0.0, 0.99))
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct EpisodeProgressRow {
    pub episode_id: Uuid,
    pub position_ms: i64,
    pub duration_ms: Option<i64>,
    pub watched: bool,
}

/// Upsert per-episode progress. Marks watched at ~85% (credits / near-end).
pub async fn upsert_episode_progress(
    pool: &PgPool,
    token_id: Uuid,
    title_id: Uuid,
    episode_id: Uuid,
    position_ms: i64,
    duration_ms: Option<i64>,
    force_watched: bool,
) -> Result<()> {
    let pos = position_ms.max(0);
    let watched = force_watched
        || duration_ms
            .map(|d| d > 0 && pos as f64 >= d as f64 * 0.85)
            .unwrap_or(false);
    sqlx::query(
        r#"
        INSERT INTO episode_progress (token_id, episode_id, title_id, position_ms, duration_ms, watched, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, now())
        ON CONFLICT (token_id, episode_id) DO UPDATE SET
            position_ms = CASE
                WHEN episode_progress.watched THEN episode_progress.position_ms
                ELSE EXCLUDED.position_ms
            END,
            duration_ms = COALESCE(EXCLUDED.duration_ms, episode_progress.duration_ms),
            watched = episode_progress.watched OR EXCLUDED.watched,
            title_id = EXCLUDED.title_id,
            updated_at = now()
        "#,
    )
    .bind(token_id)
    .bind(episode_id)
    .bind(title_id)
    .bind(if watched { 0_i64 } else { pos })
    .bind(duration_ms)
    .bind(watched)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn episode_progress_for_season(
    pool: &PgPool,
    token_id: Uuid,
    season_id: Uuid,
) -> Result<Vec<EpisodeProgressRow>> {
    let rows = sqlx::query_as::<_, EpisodeProgressRow>(
        r#"
        SELECT ep.episode_id, ep.position_ms, ep.duration_ms, ep.watched
        FROM episode_progress ep
        JOIN episodes e ON e.id = ep.episode_id
        WHERE ep.token_id = $1 AND e.season_id = $2
        "#,
    )
    .bind(token_id)
    .bind(season_id)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// Whether this episode is the last in the series (season_number > 0).
pub async fn is_last_episode(pool: &PgPool, title_id: Uuid, episode_id: Uuid) -> Result<bool> {
    let row: Option<(bool,)> = sqlx::query_as(
        r#"
        WITH ordered AS (
            SELECT e.id,
                   ROW_NUMBER() OVER (ORDER BY s.season_number ASC, e.episode_number ASC) AS rn,
                   COUNT(*) OVER () AS total
            FROM episodes e
            JOIN seasons s ON s.id = e.season_id
            WHERE s.title_id = $1 AND s.season_number > 0
        )
        SELECT rn >= total FROM ordered WHERE id = $2
        "#,
    )
    .bind(title_id)
    .bind(episode_id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| r.0).unwrap_or(false))
}

/// Paginated title list for the server console Catalog tab.
pub async fn list_catalog_titles(
    pool: &PgPool,
    query: &str,
    kind: &str,
    limit: i64,
    offset: i64,
) -> Result<(Vec<CatalogListRow>, i64)> {
    let q = query.trim();
    let kind = kind.trim().to_ascii_uppercase();
    let kind_filter = matches!(kind.as_str(), "MOVIE" | "SERIES" | "ANIME");
    let like = if q.is_empty() {
        None
    } else {
        Some(format!("%{}%", q.replace('%', "\\%").replace('_', "\\_")))
    };

    let total: i64 = if let Some(ref like) = like {
        if kind_filter {
            sqlx::query_scalar(
                "SELECT COUNT(*)::bigint FROM titles WHERE kind = $1 AND title ILIKE $2 ESCAPE '\\'",
            )
            .bind(&kind)
            .bind(like)
            .fetch_one(pool)
            .await?
        } else {
            sqlx::query_scalar("SELECT COUNT(*)::bigint FROM titles WHERE title ILIKE $1 ESCAPE '\\'")
                .bind(like)
                .fetch_one(pool)
                .await?
        }
    } else if kind_filter {
        sqlx::query_scalar("SELECT COUNT(*)::bigint FROM titles WHERE kind = $1")
            .bind(&kind)
            .fetch_one(pool)
            .await?
    } else {
        sqlx::query_scalar("SELECT COUNT(*)::bigint FROM titles")
            .fetch_one(pool)
            .await?
    };

    let rows: Vec<CatalogListRow> = if let Some(ref like) = like {
        if kind_filter {
            sqlx::query_as(
                r#"
                SELECT id, title, kind, year
                FROM titles
                WHERE kind = $1 AND title ILIKE $2 ESCAPE '\'
                ORDER BY title ASC
                LIMIT $3 OFFSET $4
                "#,
            )
            .bind(&kind)
            .bind(like)
            .bind(limit)
            .bind(offset)
            .fetch_all(pool)
            .await?
        } else {
            sqlx::query_as(
                r#"
                SELECT id, title, kind, year
                FROM titles
                WHERE title ILIKE $1 ESCAPE '\'
                ORDER BY title ASC
                LIMIT $2 OFFSET $3
                "#,
            )
            .bind(like)
            .bind(limit)
            .bind(offset)
            .fetch_all(pool)
            .await?
        }
    } else if kind_filter {
        sqlx::query_as(
            r#"
            SELECT id, title, kind, year
            FROM titles
            WHERE kind = $1
            ORDER BY title ASC
            LIMIT $2 OFFSET $3
            "#,
        )
        .bind(&kind)
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query_as(
            r#"
            SELECT id, title, kind, year
            FROM titles
            ORDER BY title ASC
            LIMIT $1 OFFSET $2
            "#,
        )
        .bind(limit)
        .bind(offset)
        .fetch_all(pool)
        .await?
    };

    Ok((rows, total))
}

pub async fn delete_title_by_id(pool: &PgPool, id: Uuid) -> Result<bool> {
    let result = sqlx::query("DELETE FROM titles WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}
