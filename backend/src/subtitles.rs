use std::path::Path;

use serde::Deserialize;
use sqlx::PgPool;
use uuid::Uuid;

use crate::config::LiveSettings;
use crate::error::{AppError, Result};

const OPENSUBTITLES_API: &str = "https://api.opensubtitles.com/api/v1";
const WYZIE_API: &str = "https://sub.wyzie.io";
const USER_AGENT: &str = "PeanutButter v0.2";
const MAX_SUBTITLE_BYTES: usize = 5 * 1024 * 1024;

/// Search hit — body is fetched only after the user picks a row.
#[derive(Debug, Clone)]
pub struct SubtitleHit {
    pub id: String,
    pub language: String,
    pub label: String,
    pub format: String,
    pub source: String,
    pub download_url: String,
}

#[derive(Debug, Clone)]
pub struct Subtitle {
    pub id: Uuid,
    pub language: String,
    pub label: String,
    pub format: String,
    pub content: String,
    pub source: String,
}

#[derive(sqlx::FromRow)]
struct SubtitleRow {
    id: Uuid,
    language: String,
    label: String,
    format: String,
    content: String,
    source: String,
}

impl From<SubtitleRow> for Subtitle {
    fn from(row: SubtitleRow) -> Self {
        Self {
            id: row.id,
            language: row.language,
            label: row.label,
            format: row.format,
            content: row.content,
            source: row.source,
        }
    }
}

#[derive(sqlx::FromRow)]
struct FileMeta {
    file_path: String,
    title: String,
    imdb_id: Option<String>,
    kind: String,
    season_number: Option<i32>,
    episode_number: Option<i32>,
    title_id: Uuid,
}

#[derive(sqlx::FromRow)]
struct TitleMeta {
    title: String,
    imdb_id: Option<String>,
    kind: String,
}

/// Fetch subtitles for one local file, only if they are not already cached.
pub async fn ensure_for_file(
    pool: &PgPool,
    http: &reqwest::Client,
    live: &LiveSettings,
    file_id: Uuid,
    preferred_lang: &str,
) -> Result<Vec<Subtitle>> {
    let existing = load_for_file(pool, file_id).await?;
    let wanted = normalize_lang(preferred_lang);
    if existing.iter().any(|s| s.language == wanted) {
        return Ok(existing);
    }

    let meta: Option<FileMeta> = sqlx::query_as(
        r#"
        SELECT
            f.file_path,
            t.title,
            t.imdb_id,
            t.kind,
            s.season_number,
            e.episode_number,
            t.id as title_id
        FROM file_references f
        JOIN titles t ON t.id = f.title_id
        LEFT JOIN seasons s ON s.id = f.season_id
        LEFT JOIN episodes e ON e.id = f.episode_id
        WHERE f.id = $1
        "#,
    )
    .bind(file_id)
    .fetch_optional(pool)
    .await?;

    let Some(meta) = meta else {
        return Err(AppError::NotFound("file reference not found".into()));
    };

    if existing.is_empty() {
        if let Some(sidecar) = read_sidecar(&meta.file_path, preferred_lang) {
            insert_file_sub(pool, file_id, &sidecar).await?;
            return load_for_file(pool, file_id).await;
        }
    }

    let parsed = crate::media::scanner::parse_filename(&meta.file_path);
    let season = meta.season_number.or_else(|| parsed.as_ref().and_then(|p| p.season));
    let episode = meta.episode_number.or_else(|| parsed.as_ref().and_then(|p| p.episode));
    let is_episode = season.is_some() && episode.is_some() && meta.kind != "movie";

    fetch_and_store(
        pool,
        http,
        live,
        meta.title_id,
        &meta.title,
        meta.imdb_id.as_deref(),
        if is_episode { season } else { None },
        if is_episode { episode } else { None },
        preferred_lang,
        Some(file_id),
    )
    .await?;

    let mut out = load_for_file(pool, file_id).await?;
    if out.is_empty() {
        out = load_for_title(pool, meta.title_id, season, episode).await?;
    }
    Ok(out)
}

pub async fn fetch_for_title(
    pool: &PgPool,
    http: &reqwest::Client,
    live: &LiveSettings,
    title_id: Uuid,
    preferred_lang: &str,
    season: Option<i32>,
    episode: Option<i32>,
    file_id: Option<Uuid>,
) -> Result<Vec<Subtitle>> {
    if let Some(file_id) = file_id {
        return ensure_for_file(pool, http, live, file_id, preferred_lang).await;
    }

    let wanted = normalize_lang(preferred_lang);
    let existing = load_for_title(pool, title_id, season, episode).await?;
    if existing.iter().any(|s| s.language == wanted) {
        return Ok(existing);
    }

    let meta: Option<TitleMeta> = sqlx::query_as(
        "SELECT title, imdb_id, kind FROM titles WHERE id = $1",
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?;
    let Some(meta) = meta else {
        return Err(AppError::NotFound("title not found".into()));
    };
    let is_episode = season.is_some() && episode.is_some() && meta.kind != "movie";

    fetch_and_store(
        pool,
        http,
        live,
        title_id,
        &meta.title,
        meta.imdb_id.as_deref(),
        if is_episode { season } else { None },
        if is_episode { episode } else { None },
        preferred_lang,
        None,
    )
    .await?;

    load_for_title(pool, title_id, season, episode).await
}

async fn fetch_and_store(
    pool: &PgPool,
    http: &reqwest::Client,
    live: &LiveSettings,
    title_id: Uuid,
    title: &str,
    imdb_id: Option<&str>,
    season: Option<i32>,
    episode: Option<i32>,
    preferred_lang: &str,
    file_id: Option<Uuid>,
) -> Result<()> {
    if !live.opensubtitles_configured() {
        return Ok(());
    }
    let Some(api_key) = live.opensubtitles_api_key() else {
        return Ok(());
    };
    match fetch_opensubtitles(
        http,
        &api_key,
        title,
        imdb_id,
        season,
        episode,
        preferred_lang,
    )
    .await
    {
        Ok(Some(remote)) => {
            insert_title_sub(pool, title_id, season, episode, &remote).await?;
            if let Some(file_id) = file_id {
                insert_file_sub(pool, file_id, &remote).await?;
            }
        }
        Ok(None) => {
            tracing::info!(title, "no OpenSubtitles results");
        }
        Err(e) => {
            tracing::warn!(error = %e, title, "OpenSubtitles download failed");
            return Err(e);
        }
    }
    Ok(())
}

async fn load_for_file(pool: &PgPool, file_id: Uuid) -> Result<Vec<Subtitle>> {
    let rows: Vec<SubtitleRow> = sqlx::query_as(
        r#"
        SELECT id, language, label, format, content, source
        FROM subtitles
        WHERE file_id = $1
        ORDER BY created_at
        "#,
    )
    .bind(file_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Subtitle::from).collect())
}

async fn load_for_title(
    pool: &PgPool,
    title_id: Uuid,
    season: Option<i32>,
    episode: Option<i32>,
) -> Result<Vec<Subtitle>> {
    let rows: Vec<SubtitleRow> = sqlx::query_as(
        r#"
        SELECT id, language, label, format, content, source
        FROM title_subtitles
        WHERE title_id = $1
          AND COALESCE(season_number, 0) = COALESCE($2, 0)
          AND COALESCE(episode_number, 0) = COALESCE($3, 0)
        ORDER BY created_at
        "#,
    )
    .bind(title_id)
    .bind(season)
    .bind(episode)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Subtitle::from).collect())
}

async fn insert_file_sub(pool: &PgPool, file_id: Uuid, sub: &Subtitle) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO subtitles (id, file_id, language, label, format, content, source)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (file_id, language) DO NOTHING
        "#,
    )
    .bind(sub.id)
    .bind(file_id)
    .bind(&sub.language)
    .bind(&sub.label)
    .bind(&sub.format)
    .bind(&sub.content)
    .bind(&sub.source)
    .execute(pool)
    .await?;
    Ok(())
}

async fn insert_title_sub(
    pool: &PgPool,
    title_id: Uuid,
    season: Option<i32>,
    episode: Option<i32>,
    sub: &Subtitle,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO title_subtitles (
            id, title_id, language, label, format, content, source, season_number, episode_number
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT DO NOTHING
        "#,
    )
    .bind(sub.id)
    .bind(title_id)
    .bind(&sub.language)
    .bind(&sub.label)
    .bind(&sub.format)
    .bind(&sub.content)
    .bind(&sub.source)
    .bind(season)
    .bind(episode)
    .execute(pool)
    .await?;
    Ok(())
}

#[derive(Debug, Deserialize)]
struct OsSearch {
    data: Option<Vec<OsItem>>,
}

#[derive(Debug, Deserialize)]
struct OsItem {
    attributes: Option<OsAttrs>,
}

#[derive(Debug, Deserialize)]
struct OsAttrs {
    language: Option<String>,
    files: Option<Vec<OsFile>>,
}

#[derive(Debug, Deserialize)]
struct OsFile {
    file_id: Option<i64>,
    file_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OsDownload {
    link: Option<String>,
}

async fn fetch_opensubtitles(
    http: &reqwest::Client,
    api_key: &str,
    title: &str,
    imdb_id: Option<&str>,
    season: Option<i32>,
    episode: Option<i32>,
    preferred_lang: &str,
) -> Result<Option<Subtitle>> {
    let lang = normalize_lang(preferred_lang);
    let mut url = reqwest::Url::parse(&format!("{OPENSUBTITLES_API}/subtitles"))
        .map_err(|e| AppError::Provider(e.to_string()))?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("languages", &lang);
        q.append_pair("query", title);
        if let Some(imdb) = normalize_imdb(imdb_id) {
            q.append_pair("imdb_id", imdb.trim_start_matches("tt"));
        }
        if let (Some(s), Some(e)) = (season, episode) {
            q.append_pair("type", "episode");
            q.append_pair("season_number", &s.to_string());
            q.append_pair("episode_number", &e.to_string());
        } else {
            q.append_pair("type", "movie");
        }
        q.append_pair("order_by", "download_count");
        q.append_pair("order_direction", "desc");
    }
    let resp = http
        .get(url)
        .header("Api-Key", api_key)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "application/json")
        .send()
        .await?;
    if resp.status().as_u16() == 401 || resp.status().as_u16() == 403 {
        return Err(AppError::Provider(
            "OpenSubtitles rejected the API key. Check it in Settings.".into(),
        ));
    }
    if !resp.status().is_success() {
        return Err(AppError::Provider(format!(
            "OpenSubtitles search HTTP {}",
            resp.status()
        )));
    }
    let body: OsSearch = resp.json().await?;
    let mut file_ids = Vec::new();
    for item in body.data.unwrap_or_default() {
        let Some(attrs) = item.attributes else { continue };
        let item_lang = normalize_lang(attrs.language.as_deref().unwrap_or(&lang));
        if item_lang != lang && item_lang != "en" {
            continue;
        }
        for file in attrs.files.unwrap_or_default() {
            let Some(id) = file.file_id else { continue };
            let name = file.file_name.unwrap_or_default().to_ascii_lowercase();
            if name.ends_with(".sub") {
                continue;
            }
            file_ids.push((lang_rank(&item_lang, &lang), id));
        }
    }
    file_ids.sort_by_key(|(rank, _)| *rank);
    for (_, file_id) in file_ids.into_iter().take(6) {
        match download_os_file(http, api_key, file_id).await {
            Ok(content) => {
                return Ok(Some(Subtitle {
                    id: Uuid::new_v4(),
                    language: lang.clone(),
                    label: language_label(&lang),
                    format: "srt".into(),
                    content,
                    source: "opensubtitles".into(),
                }));
            }
            Err(e) => {
                tracing::debug!(error = %e, file_id, "skipping OpenSubtitles file");
            }
        }
    }
    Ok(None)
}

async fn download_os_file(http: &reqwest::Client, api_key: &str, file_id: i64) -> Result<String> {
    let resp = http
        .post(format!("{OPENSUBTITLES_API}/download"))
        .header("Api-Key", api_key)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "application/json")
        .json(&serde_json::json!({ "file_id": file_id }))
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(AppError::Provider(format!(
            "OpenSubtitles download HTTP {}",
            resp.status()
        )));
    }
    let body: OsDownload = resp.json().await?;
    let Some(link) = body.link.filter(|s| !s.is_empty()) else {
        return Err(AppError::Provider("OpenSubtitles returned no download link".into()));
    };
    download_srt(http, &link).await
}

async fn download_srt(http: &reqwest::Client, url: &str) -> Result<String> {
    let resp = http.get(url).header("User-Agent", USER_AGENT).send().await?;
    if !resp.status().is_success() {
        return Err(AppError::Provider(format!(
            "subtitle file HTTP {}",
            resp.status()
        )));
    }
    let bytes = resp.bytes().await?;
    if bytes.len() > MAX_SUBTITLE_BYTES {
        return Err(AppError::Provider("subtitle file too large".into()));
    }
    if bytes.starts_with(b"PK") {
        return Err(AppError::Provider("zip subtitles are not supported".into()));
    }
    let text = decode_subtitle_bytes(&bytes)?;
    // Wyzie may return WebVTT; accept either cue format.
    if !looks_like_srt(&text) && !looks_like_vtt(&text) {
        return Err(AppError::Provider("response was not an SRT/VTT file".into()));
    }
    Ok(text)
}

fn looks_like_vtt(text: &str) -> bool {
    let sample = text.chars().take(800).collect::<String>();
    sample.contains("-->")
        && (sample.trim_start().starts_with("WEBVTT") || sample.contains("WEBVTT"))
}

/// Search Wyzie by TMDB (preferred) or IMDb — never downloads the file body.
pub async fn search_wyzie_for_title(
    pool: &PgPool,
    http: &reqwest::Client,
    live: &LiveSettings,
    title_id: Uuid,
    preferred_lang: &str,
    season: Option<i32>,
    episode: Option<i32>,
) -> Result<Vec<SubtitleHit>> {
    let Some(api_key) = live.wyzie_api_key() else {
        return Ok(vec![]);
    };
    let meta: Option<(Option<i32>, Option<String>, String)> = sqlx::query_as(
        r#"SELECT tmdb_id, imdb_id, title FROM titles WHERE id = $1"#,
    )
    .bind(title_id)
    .fetch_optional(pool)
    .await?;
    let Some((tmdb_id, imdb_id, title)) = meta else {
        return Ok(vec![]);
    };
    let lang = normalize_lang(preferred_lang);
    let mut url =
        reqwest::Url::parse(&format!("{WYZIE_API}/search")).map_err(|e| AppError::Provider(e.to_string()))?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("key", &api_key);
        q.append_pair("language", &lang);
        q.append_pair("format", "srt");
        if let Some(id) = tmdb_id {
            q.append_pair("id", &id.to_string());
        } else if let Some(imdb) = normalize_imdb(imdb_id.as_deref()) {
            q.append_pair("id", &imdb);
        } else {
            tracing::info!(%title, "Wyzie search skipped — no TMDB/IMDb id");
            return Ok(vec![]);
        }
        if let (Some(s), Some(e)) = (season, episode) {
            q.append_pair("season", &s.to_string());
            q.append_pair("episode", &e.to_string());
        }
    }
    let resp = http
        .get(url)
        .header("User-Agent", USER_AGENT)
        .header("Accept", "application/json")
        .send()
        .await?;
    if resp.status().as_u16() == 401 || resp.status().as_u16() == 403 {
        return Err(AppError::Provider(
            "Wyzie rejected the API key. Check it in Settings (store.wyzie.io).".into(),
        ));
    }
    if resp.status().as_u16() == 429 {
        return Err(AppError::Provider(
            "Wyzie daily request limit reached. Try again tomorrow or upgrade the key.".into(),
        ));
    }
    if !resp.status().is_success() {
        return Err(AppError::Provider(format!(
            "Wyzie search HTTP {}",
            resp.status()
        )));
    }
    let body: serde_json::Value = resp.json().await?;
    let rows = body
        .as_array()
        .cloned()
        .or_else(|| body.get("data").and_then(|v| v.as_array()).cloned())
        .unwrap_or_default();
    let mut out = Vec::new();
    for row in rows {
        let download = row
            .get("url")
            .or_else(|| row.get("downloadUrl"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        if download.is_empty() {
            continue;
        }
        let row_lang = normalize_lang(
            row.get("language")
                .or_else(|| row.get("lang"))
                .and_then(|v| v.as_str())
                .unwrap_or(&lang),
        );
        // Prefer exact language; keep English as soft fallback when preferred isn't present.
        if row_lang != lang && row_lang != "en" && lang != "en" {
            continue;
        }
        // `display` is just the language name ("English") — prefer release / file.
        let release = row
            .get("release")
            .or_else(|| row.get("matchedRelease"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let file_name = row
            .get("fileName")
            .or_else(|| row.get("filename"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let origin = row
            .get("origin")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let source = row
            .get("source")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let hi = row
            .get("isHearingImpaired")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let ai = row.get("ai").and_then(|v| v.as_bool()).unwrap_or(false);
        let format = row
            .get("format")
            .and_then(|v| v.as_str())
            .unwrap_or("srt")
            .to_ascii_lowercase();
        let id = row
            .get("id")
            .map(|v| v.to_string().trim_matches('"').to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("wyzie-{}", out.len() + 1));
        let detail = if !release.is_empty() {
            release.to_string()
        } else if !file_name.is_empty() {
            file_name
                .trim_end_matches(".srt")
                .trim_end_matches(".vtt")
                .trim_end_matches(".ass")
                .to_string()
        } else if !origin.is_empty() || !source.is_empty() {
            [origin, source]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" · ")
        } else {
            String::new()
        };
        let mut label = if detail.is_empty() {
            language_label(&row_lang)
        } else {
            format!("{} · {detail}", language_label(&row_lang))
        };
        if hi {
            label.push_str(" · HI");
        }
        if ai {
            label.push_str(" · AI");
        }
        out.push(SubtitleHit {
            id,
            language: row_lang,
            label,
            format,
            source: "wyzie".into(),
            download_url: download,
        });
        if out.len() >= 24 {
            break;
        }
    }
    // Prefer preferred language first.
    out.sort_by_key(|h| if h.language == lang { 0 } else { 1 });
    Ok(out)
}

/// Download a previously listed Wyzie (or other) subtitle URL.
pub async fn download_remote_subtitle(
    http: &reqwest::Client,
    download_url: &str,
    language: &str,
    label: &str,
    format: &str,
    source: &str,
) -> Result<Subtitle> {
    let url = download_url.trim();
    if url.is_empty() || !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(AppError::BadRequest("Invalid subtitle download URL.".into()));
    }
    // Only allow Wyzie CDN hosts for safety.
    let host = reqwest::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_ascii_lowercase()));
    let allowed = matches!(
        host.as_deref(),
        Some("sub.wyzie.io") | Some("cdn.wyzie.io") | Some("wyzie.io")
    );
    if !allowed {
        return Err(AppError::BadRequest(
            "Subtitle download host is not allowed.".into(),
        ));
    }
    let content = download_srt(http, url).await?;
    let fmt = if looks_like_vtt(&content) {
        "vtt".into()
    } else if format.trim().is_empty() {
        "srt".into()
    } else {
        format.to_ascii_lowercase()
    };
    Ok(Subtitle {
        id: Uuid::new_v4(),
        language: normalize_lang(language),
        label: if label.trim().is_empty() {
            language_label(&normalize_lang(language))
        } else {
            label.trim().into()
        },
        format: fmt,
        content,
        source: if source.trim().is_empty() {
            "wyzie".into()
        } else {
            source.trim().into()
        },
    })
}

fn decode_subtitle_bytes(bytes: &[u8]) -> Result<String> {
    let trimmed = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    Ok(String::from_utf8_lossy(trimmed).into_owned())
}

fn looks_like_srt(text: &str) -> bool {
    let sample = text.chars().take(800).collect::<String>();
    sample.contains("-->") && !sample.trim_start().starts_with('<')
}

fn read_sidecar(video_path: &str, preferred_lang: &str) -> Option<Subtitle> {
    let path = Path::new(video_path);
    let stem = path.file_stem()?.to_str()?;
    let dir = path.parent()?;
    let lang = normalize_lang(preferred_lang);
    let candidates = [
        dir.join(format!("{stem}.srt")),
        dir.join(format!("{stem}.{lang}.srt")),
        dir.join(format!("{stem}.en.srt")),
        dir.join(format!("{stem}.eng.srt")),
    ];
    for candidate in candidates {
        if !candidate.is_file() {
            continue;
        }
        let bytes = std::fs::read(&candidate).ok()?;
        if bytes.len() > MAX_SUBTITLE_BYTES {
            continue;
        }
        let content = decode_subtitle_bytes(&bytes).ok()?;
        if !looks_like_srt(&content) {
            continue;
        }
        return Some(Subtitle {
            id: Uuid::new_v4(),
            language: lang.clone(),
            label: language_label(&lang),
            format: "srt".into(),
            content,
            source: "sidecar".into(),
        });
    }
    None
}

pub fn normalize_imdb(raw: Option<&str>) -> Option<String> {
    let value = raw?.trim();
    if value.is_empty() {
        return None;
    }
    let digits = value.trim_start_matches("tt").trim_start_matches("TT");
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some(format!("tt{digits}"))
}

fn normalize_lang(lang: &str) -> String {
    match lang.trim().to_ascii_lowercase().as_str() {
        "eng" | "english" | "en-us" | "en-gb" => "en".into(),
        "fre" | "fra" | "french" => "fr".into(),
        "ger" | "deu" | "german" => "de".into(),
        "spa" | "spanish" => "es".into(),
        "ita" | "italian" => "it".into(),
        "por" | "pob" | "portuguese" => "pt".into(),
        "jpn" | "japanese" => "ja".into(),
        "kor" | "korean" => "ko".into(),
        "chi" | "zho" | "chinese" => "zh".into(),
        "hin" | "hindi" => "hi".into(),
        "ara" | "arabic" => "ar".into(),
        "tur" | "turkish" => "tr".into(),
        "rus" | "russian" => "ru".into(),
        "tha" | "thai" => "th".into(),
        "ind" | "indonesian" => "id".into(),
        other if other.len() >= 2 => other.chars().take(2).collect(),
        _ => "en".into(),
    }
}

fn language_label(lang: &str) -> String {
    match normalize_lang(lang).as_str() {
        "en" => "English".into(),
        "fr" => "French".into(),
        "de" => "German".into(),
        "es" => "Spanish".into(),
        "it" => "Italian".into(),
        "pt" => "Portuguese".into(),
        "ja" => "Japanese".into(),
        "ko" => "Korean".into(),
        "zh" => "Chinese".into(),
        "hi" => "Hindi".into(),
        "ar" => "Arabic".into(),
        "tr" => "Turkish".into(),
        "ru" => "Russian".into(),
        "th" => "Thai".into(),
        "id" => "Indonesian".into(),
        other => other.to_uppercase(),
    }
}

fn lang_rank(lang: &str, preferred: &str) -> i32 {
    let normalized = normalize_lang(lang);
    let preferred = normalize_lang(preferred);
    if normalized == preferred {
        0
    } else if normalized == "en" {
        1
    } else {
        5
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imdb_ids_normalize() {
        assert_eq!(normalize_imdb(Some("tt0133093")).as_deref(), Some("tt0133093"));
        assert_eq!(normalize_imdb(Some("0133093")).as_deref(), Some("tt0133093"));
        assert_eq!(normalize_imdb(Some("")), None);
        assert_eq!(normalize_imdb(None), None);
    }

    #[test]
    fn english_ranks_first() {
        assert!(lang_rank("eng", "en") < lang_rank("ger", "en"));
        assert_eq!(normalize_lang("ENG"), "en");
        assert_eq!(normalize_lang("jpn"), "ja");
    }

    #[test]
    fn srt_detection() {
        assert!(looks_like_srt("1\n00:00:01,000 --> 00:00:02,000\nHello\n"));
        assert!(!looks_like_srt("<html>nope</html>"));
    }
}
