use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use notify::{Config as NotifyConfig, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use regex::Regex;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tracing::{info, warn};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::config::Config;
use crate::error::Result;
use crate::search::SearchClient;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedMediaFile {
    pub title: String,
    pub year: i32,
    pub quality: String,
    pub container: String,
    pub season: Option<i32>,
    pub episode: Option<i32>,
}

/// Parse `{title}.{year}.{quality}.{container}` and optional `SxxExx`.
pub fn parse_filename(name: &str) -> Option<ParsedMediaFile> {
    let name = Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(name);

    static RE_EP: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    static RE_BASIC: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();

    let re_ep = RE_EP.get_or_init(|| {
        Regex::new(
            r"(?i)^(?P<title>.+?)\.(?P<year>(?:19|20)\d{2})\.[Ss](?P<season>\d{1,2})[Ee](?P<episode>\d{1,2})\.(?P<quality>\d{3,4}p|4k|8k|hdr)\.(?P<container>[A-Za-z0-9]+)$",
        )
        .expect("episode filename regex")
    });
    let re_basic = RE_BASIC.get_or_init(|| {
        Regex::new(
            r"(?i)^(?P<title>.+?)\.(?P<year>(?:19|20)\d{2})\.(?P<quality>\d{3,4}p|4k|8k|hdr)\.(?P<container>[A-Za-z0-9]+)$",
        )
        .expect("basic filename regex")
    });

    if let Some(caps) = re_ep.captures(name) {
        return Some(ParsedMediaFile {
            title: normalize_title(&caps["title"]),
            year: caps["year"].parse().ok()?,
            quality: caps["quality"].to_lowercase(),
            container: caps["container"].to_lowercase(),
            season: caps["season"].parse().ok(),
            episode: caps["episode"].parse().ok(),
        });
    }
    if let Some(caps) = re_basic.captures(name) {
        return Some(ParsedMediaFile {
            title: normalize_title(&caps["title"]),
            year: caps["year"].parse().ok()?,
            quality: caps["quality"].to_lowercase(),
            container: caps["container"].to_lowercase(),
            season: None,
            episode: None,
        });
    }
    None
}

fn normalize_title(raw: &str) -> String {
    raw.replace(['.', '_'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub async fn scan_library(
    pool: &sqlx::PgPool,
    config: &Config,
    search: &SearchClient,
) -> Result<usize> {
    let root = config.media_path();
    if !root.exists() {
        warn!(path = %root.display(), "MEDIA_PATH does not exist; skipping scan");
        return Ok(0);
    }

    let mut matched = 0usize;
    let video_ext = ["mkv", "mp4", "avi", "webm", "mov", "m4v"];
    for entry in WalkDir::new(root).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.components().any(|c| c.as_os_str() == ".peanutbutter-streams") {
            continue;
        }
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        if !video_ext.contains(&ext.as_str()) {
            continue;
        }
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        let Some(parsed) = parse_filename(name) else {
            continue;
        };
        match upsert_file_reference(pool, config, path, &parsed).await {
            Ok(true) => {
                matched += 1;
                let _ = search;
            }
            Ok(false) => {}
            Err(e) => warn!(file = %path.display(), error = %e, "file match failed"),
        }
    }
    info!(matched, "library scan complete");
    if let Err(e) = backfill_codecs(pool).await {
        warn!(error = %e, "codec backfill failed");
    }
    Ok(matched)
}

async fn upsert_file_reference(
    pool: &sqlx::PgPool,
    config: &Config,
    path: &Path,
    parsed: &ParsedMediaFile,
) -> Result<bool> {
    let title_id = match_title(pool, &parsed.title, parsed.year).await?;
    let Some(title_id) = title_id else {
        return Ok(false);
    };

    let (season_id, episode_id) = match (parsed.season, parsed.episode) {
        (Some(s), Some(e)) => lookup_episode(pool, title_id, s, e).await?,
        _ => (None, None),
    };

    let meta = tokio::fs::metadata(path).await.ok();
    let size_bytes = meta.map(|m| m.len() as i64);
    let file_path = path.to_string_lossy().to_string();
    let hash = content_hash_quick(path, size_bytes).await;
    let (codec, audio_codec) = probe_codecs(path).await;

    let row: (Uuid,) = sqlx::query_as(
        r#"
        INSERT INTO file_references (
            title_id, season_id, episode_id, kind, quality, container, codec, audio_codec,
            size_bytes, file_path, http_url, content_hash, available_peers, last_check
        ) VALUES ($1,$2,$3,'local',$4,$5,$6,$7,$8,$9,NULL,$10,1, now())
        ON CONFLICT (file_path) DO UPDATE SET
            title_id = EXCLUDED.title_id,
            season_id = EXCLUDED.season_id,
            episode_id = EXCLUDED.episode_id,
            quality = EXCLUDED.quality,
            container = EXCLUDED.container,
            codec = COALESCE(EXCLUDED.codec, file_references.codec),
            audio_codec = COALESCE(EXCLUDED.audio_codec, file_references.audio_codec),
            size_bytes = EXCLUDED.size_bytes,
            content_hash = EXCLUDED.content_hash,
            last_check = now()
        RETURNING id
        "#,
    )
    .bind(title_id)
    .bind(season_id)
    .bind(episode_id)
    .bind(&parsed.quality)
    .bind(&parsed.container)
    .bind(codec.as_deref())
    .bind(audio_codec.as_deref())
    .bind(size_bytes)
    .bind(&file_path)
    .bind(&hash)
    .fetch_one(pool)
    .await?;

    let url = config.playback_url(row.0);
    sqlx::query("UPDATE file_references SET http_url = $2 WHERE id = $1")
        .bind(row.0)
        .bind(&url)
        .execute(pool)
        .await?;
    Ok(true)
}

async fn match_title(pool: &sqlx::PgPool, title: &str, year: i32) -> Result<Option<Uuid>> {
    let needle = title.to_lowercase();
    let row: Option<(Uuid,)> = sqlx::query_as(
        r#"
        SELECT id FROM titles
        WHERE year = $2
          AND (
            lower(title) = $1
            OR lower(replace(title, ':', '')) = $1
            OR lower(coalesce(original_title, '')) = $1
            OR lower(title) LIKE '%' || $1 || '%'
          )
        ORDER BY CASE WHEN lower(title) = $1 THEN 0 ELSE 1 END, length(title)
        LIMIT 1
        "#,
    )
    .bind(&needle)
    .bind(year)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| r.0))
}

async fn lookup_episode(
    pool: &sqlx::PgPool,
    title_id: Uuid,
    season: i32,
    episode: i32,
) -> Result<(Option<Uuid>, Option<Uuid>)> {
    let row: Option<(Uuid, Uuid)> = sqlx::query_as(
        r#"
        SELECT s.id, e.id
        FROM seasons s
        JOIN episodes e ON e.season_id = s.id
        WHERE s.title_id = $1 AND s.season_number = $2 AND e.episode_number = $3
        "#,
    )
    .bind(title_id)
    .bind(season)
    .bind(episode)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(s, e)| (Some(s), Some(e))).unwrap_or((None, None)))
}

async fn content_hash_quick(path: &Path, size: Option<i64>) -> Option<String> {
    let mut hasher = Sha256::new();
    hasher.update(path.to_string_lossy().as_bytes());
    if let Some(sz) = size {
        hasher.update(sz.to_le_bytes());
    }
    Some(hex::encode(hasher.finalize()))
}

pub fn start_watcher(
    pool: sqlx::PgPool,
    config: Config,
    search: SearchClient,
) -> Result<Option<RecommendedWatcher>> {
    let root = config.media_path();
    if !root.exists() {
        warn!(path = %root.display(), "MEDIA_PATH missing; file watcher disabled");
        return Ok(None);
    }

    let (tx, mut rx) = mpsc::unbounded_channel::<PathBuf>();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<notify::Event>| {
            if let Ok(event) = res {
                if matches!(
                    event.kind,
                    EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
                ) {
                    for p in event.paths {
                        let _ = tx.send(p);
                    }
                }
            }
        },
        NotifyConfig::default(),
    )
    .map_err(|e| crate::error::AppError::Internal(format!("watcher: {e}")))?;

    watcher
        .watch(&root, RecursiveMode::Recursive)
        .map_err(|e| crate::error::AppError::Internal(format!("watch path: {e}")))?;

    let cfg = Arc::new(config);
    tokio::spawn(async move {
        loop {
            // Debounce bursts of filesystem events.
            match rx.recv().await {
                Some(_) => {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    while rx.try_recv().is_ok() {}
                    if let Err(e) = scan_library(&pool, cfg.as_ref(), &search).await {
                        warn!(error = %e, "rescan after fs event failed");
                    }
                }
                None => break,
            }
        }
    });

    info!(path = %root.display(), "watching media library for changes");
    Ok(Some(watcher))
}

#[derive(Debug, serde::Deserialize)]
struct Ffprobe {
    streams: Option<Vec<FfprobeStream>>,
}

#[derive(Debug, serde::Deserialize)]
struct FfprobeStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
}

async fn probe_codecs(path: &Path) -> (Option<String>, Option<String>) {
    let from_name = codecs_from_filename(path);
    let path_buf = path.to_path_buf();
    let probed = tokio::task::spawn_blocking(move || {
        let path_str = path_buf.to_str()?;
        let output = std::process::Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=codec_type,codec_name",
                "-of",
                "json",
                path_str,
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let parsed: Ffprobe = serde_json::from_slice(&output.stdout).ok()?;
        let mut video = None;
        let mut audio = None;
        for stream in parsed.streams.unwrap_or_default() {
            match stream.codec_type.as_deref() {
                Some("video") if video.is_none() => video = stream.codec_name,
                Some("audio") if audio.is_none() => audio = stream.codec_name,
                _ => {}
            }
        }
        Some((video, audio))
    })
    .await
    .ok()
    .flatten()
    .unwrap_or((None, None));
    (probed.0.or(from_name.0), probed.1.or(from_name.1))
}

fn codecs_from_filename(path: &Path) -> (Option<String>, Option<String>) {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase();
    let video = if token_in(&name, &["x265", "h265", "hevc", "hev1"]) {
        Some("hevc")
    } else if token_in(&name, &["x264", "h264", "avc1", "avc"]) {
        Some("h264")
    } else if token_in(&name, &["av1", "av01"]) {
        Some("av1")
    } else if token_in(&name, &["vp9"]) {
        Some("vp9")
    } else {
        None
    };
    let audio = if token_in(&name, &["truehd", "atmos"]) {
        Some("truehd")
    } else if token_in(&name, &["eac3", "ddp", "dd+"]) {
        Some("eac3")
    } else if token_in(&name, &["dtshd", "dts-hd", "dts"]) {
        Some("dts")
    } else if token_in(&name, &["ac3", "dd5", "dd2"]) {
        Some("ac3")
    } else if token_in(&name, &["flac"]) {
        Some("flac")
    } else if token_in(&name, &["aac"]) {
        Some("aac")
    } else if token_in(&name, &["opus"]) {
        Some("opus")
    } else {
        None
    };
    (video.map(str::to_string), audio.map(str::to_string))
}

fn token_in(name: &str, tokens: &[&str]) -> bool {
    tokens.iter().any(|token| {
        name.split(|c: char| !c.is_ascii_alphanumeric())
            .any(|part| part == *token)
            || name.contains(token)
    })
}

async fn backfill_codecs(pool: &sqlx::PgPool) -> Result<usize> {
    let rows: Vec<(Uuid, String)> = sqlx::query_as(
        r#"
        SELECT id, file_path
        FROM file_references
        WHERE file_path IS NOT NULL
          AND (codec IS NULL OR audio_codec IS NULL)
        LIMIT 400
        "#,
    )
    .fetch_all(pool)
    .await?;
    let mut updated = 0usize;
    for (id, file_path) in rows {
        let path = PathBuf::from(&file_path);
        if !path.exists() {
            continue;
        }
        let (codec, audio_codec) = probe_codecs(&path).await;
        if codec.is_none() && audio_codec.is_none() {
            continue;
        }
        sqlx::query(
            r#"
            UPDATE file_references SET
                codec = COALESCE($2, codec),
                audio_codec = COALESCE($3, audio_codec)
            WHERE id = $1
            "#,
        )
        .bind(id)
        .bind(codec.as_deref())
        .bind(audio_codec.as_deref())
        .execute(pool)
        .await?;
        updated += 1;
    }
    if updated > 0 {
        info!(updated, "backfilled audio/video codecs");
    }
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::parse_filename;

    #[test]
    fn parses_movie_filename() {
        let p = parse_filename("The.Matrix.1999.1080p.mkv").unwrap();
        assert_eq!(p.title, "The Matrix");
        assert_eq!(p.year, 1999);
        assert_eq!(p.quality, "1080p");
        assert_eq!(p.container, "mkv");
        assert_eq!(p.season, None);
    }

    #[test]
    fn parses_episode_filename() {
        let p = parse_filename("Breaking.Bad.2008.S01E01.1080p.mkv").unwrap();
        assert_eq!(p.title, "Breaking Bad");
        assert_eq!(p.season, Some(1));
        assert_eq!(p.episode, Some(1));
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_filename("notes.txt").is_none());
        assert!(parse_filename("movie.mkv").is_none());
    }
}
