use serde::Deserialize;
use serde_json::json;
use tracing::{info, warn};
use uuid::Uuid;

use super::{throttle, IngestContext};
use crate::error::{AppError, Result};
use crate::ingest::tmdb::{reindex, replace_credit_people, CreditPerson, upsert_ratings};

const ANILIST_URL: &str = "https://graphql.anilist.co";

const TRENDING_QUERY: &str = r#"
query ($page: Int, $perPage: Int) {
  Page(page: $page, perPage: $perPage) {
    media(type: ANIME, sort: TRENDING_DESC) {
      id
      idMal
      title { romaji english native }
      description(asHtml: false)
      coverImage { extraLarge large }
      bannerImage
      genres
      averageScore
      popularity
      seasonYear
      duration
      format
      status
      episodes
      characters(perPage: 16, sort: ROLE) {
        edges {
          role
          node {
            name { full }
            image { large }
          }
          voiceActors(language: JAPANESE, sort: RELEVANCE) {
            name { full }
            image { large }
          }
        }
      }
      staff(perPage: 8) {
        edges {
          role
          node {
            name { full }
            image { large }
          }
        }
      }
    }
  }
}
"#;

const POPULAR_QUERY: &str = r#"
query ($page: Int, $perPage: Int) {
  Page(page: $page, perPage: $perPage) {
    media(type: ANIME, sort: POPULARITY_DESC) {
      id
      idMal
      title { romaji english native }
      description(asHtml: false)
      coverImage { extraLarge large }
      bannerImage
      genres
      averageScore
      popularity
      seasonYear
      duration
      format
      status
      episodes
      characters(perPage: 16, sort: ROLE) {
        edges {
          role
          node {
            name { full }
            image { large }
          }
          voiceActors(language: JAPANESE, sort: RELEVANCE) {
            name { full }
            image { large }
          }
        }
      }
      staff(perPage: 8) {
        edges {
          role
          node {
            name { full }
            image { large }
          }
        }
      }
    }
  }
}
"#;

const MEDIA_QUERY: &str = r#"
query ($id: Int) {
  Media(id: $id, type: ANIME) {
    id
    idMal
    title { romaji english native }
    description(asHtml: false)
    coverImage { extraLarge large }
    bannerImage
    genres
    averageScore
    popularity
    seasonYear
    duration
    format
    status
    episodes
    characters(perPage: 16, sort: ROLE) {
      edges {
        role
        node {
          name { full }
          image { large }
        }
        voiceActors(language: JAPANESE, sort: RELEVANCE) {
          name { full }
          image { large }
        }
      }
    }
    staff(perPage: 8) {
      edges {
        role
        node {
          name { full }
          image { large }
        }
      }
    }
  }
}
"#;

#[derive(Debug, Deserialize)]
struct AniResponse {
    data: Option<AniData>,
}

#[derive(Debug, Deserialize)]
struct AniData {
    #[serde(rename = "Page")]
    page: AniPage,
}

#[derive(Debug, Deserialize)]
struct AniPage {
    media: Vec<AniMedia>,
}

#[derive(Debug, Deserialize)]
struct AniMedia {
    id: i32,
    #[serde(rename = "idMal")]
    id_mal: Option<i32>,
    title: AniTitle,
    description: Option<String>,
    #[serde(rename = "coverImage")]
    cover_image: Option<AniCover>,
    #[serde(rename = "bannerImage")]
    banner_image: Option<String>,
    genres: Option<Vec<String>>,
    #[serde(rename = "averageScore")]
    average_score: Option<i32>,
    popularity: Option<i32>,
    #[serde(rename = "seasonYear")]
    season_year: Option<i32>,
    duration: Option<i32>,
    format: Option<String>,
    episodes: Option<i32>,
    characters: Option<AniConnection>,
    staff: Option<AniConnection>,
}

#[derive(Debug, Deserialize)]
struct AniConnection {
    edges: Option<Vec<AniEdge>>,
}

#[derive(Debug, Deserialize)]
struct AniEdge {
    role: Option<String>,
    node: Option<AniPersonNode>,
    #[serde(rename = "voiceActors")]
    voice_actors: Option<Vec<AniPersonNode>>,
}

#[derive(Debug, Deserialize)]
struct AniPersonNode {
    name: Option<AniPersonName>,
    image: Option<AniPersonImage>,
}

#[derive(Debug, Deserialize)]
struct AniPersonName {
    full: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AniPersonImage {
    large: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AniTitle {
    romaji: Option<String>,
    english: Option<String>,
    native: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AniCover {
    #[serde(rename = "extraLarge")]
    extra_large: Option<String>,
    large: Option<String>,
}

pub async fn sync_trending(ctx: &IngestContext) -> Result<()> {
    info!("fetching anime from AniList");
    for (query, pages) in [(TRENDING_QUERY, 5usize), (POPULAR_QUERY, 4usize)] {
        for page in 1..=pages {
            let body = json!({
                "query": query,
                "variables": { "page": page, "perPage": 50 }
            });
            let resp = ctx
                .http
                .post(ANILIST_URL)
                .header("Content-Type", "application/json")
                .header("Accept", "application/json")
                .json(&body)
                .send()
                .await?;
            let status = resp.status();
            if !status.is_success() {
                let text = resp.text().await.unwrap_or_default();
                return Err(AppError::Provider(format!(
                    "AniList {status}: {}",
                    text.chars().take(200).collect::<String>()
                )));
            }
            let parsed: AniResponse = resp.json().await?;
            let Some(data) = parsed.data else {
                warn!(page, "AniList returned no data");
                break;
            };
            for media in data.page.media {
                if let Err(e) = upsert_anime(ctx, media).await {
                    warn!(error = %e, "anime upsert failed");
                }
            }
            throttle().await;
        }
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
struct AniMediaResponse {
    data: Option<AniMediaData>,
}

#[derive(Debug, Deserialize)]
struct AniMediaData {
    #[serde(rename = "Media")]
    media: Option<AniMedia>,
}

pub async fn fill_missing_people(ctx: &IngestContext) -> Result<()> {
    let rows: Vec<(Uuid, i32)> = sqlx::query_as(
        r#"
        SELECT t.id, t.anilist_id
        FROM titles t
        WHERE t.kind = 'anime'
          AND t.anilist_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM title_people p WHERE p.title_id = t.id)
        ORDER BY t.updated_at DESC NULLS LAST
        LIMIT 400
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    if rows.is_empty() {
        return crate::ingest::jikan::fill_missing_people(ctx).await;
    }
    info!(count = rows.len(), "filling missing anime cast from AniList");
    for (id, anilist_id) in rows {
        match fetch_media(ctx, anilist_id).await {
            Ok(Some(media)) => {
                let people = anilist_people(&media);
                if people.is_empty() {
                    warn!(%id, anilist_id, "AniList returned no people");
                } else if let Err(e) = replace_credit_people(ctx, id, &people).await {
                    warn!(%id, error = %e, "anime people write failed");
                }
            }
            Ok(None) => warn!(%id, anilist_id, "AniList media missing"),
            Err(e) if e.to_string().contains("anilist_unavailable") => {
                warn!("AniList is unavailable; stopping AniList people backfill");
                break;
            }
            Err(e) => warn!(%id, anilist_id, error = %e, "AniList people fetch failed"),
        }
        throttle().await;
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    }
    crate::ingest::jikan::fill_missing_people(ctx).await
}

pub async fn refresh_by_id(ctx: &IngestContext, anilist_id: i32) -> Result<Uuid> {
    let media = fetch_media(ctx, anilist_id)
        .await?
        .ok_or_else(|| AppError::NotFound("AniList title not found".into()))?;
    upsert_anime(ctx, media).await
}

async fn fetch_media(ctx: &IngestContext, anilist_id: i32) -> Result<Option<AniMedia>> {
    let body = json!({
        "query": MEDIA_QUERY,
        "variables": { "id": anilist_id }
    });
    let resp = ctx
        .http
        .post(ANILIST_URL)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .json(&body)
        .send()
        .await?;
    let status = resp.status();
    if status.as_u16() == 429 {
        warn!(anilist_id, "AniList rate limited; backing off");
        tokio::time::sleep(std::time::Duration::from_secs(8)).await;
        return Ok(None);
    }
    if status.as_u16() == 403 {
        return Err(AppError::Provider("anilist_unavailable".into()));
    }
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(AppError::Provider(format!(
            "AniList {status}: {}",
            text.chars().take(200).collect::<String>()
        )));
    }
    let parsed: AniMediaResponse = resp.json().await?;
    Ok(parsed.data.and_then(|d| d.media))
}

async fn upsert_anime(ctx: &IngestContext, media: AniMedia) -> Result<Uuid> {
    let people = anilist_people(&media);
    let title = media
        .title
        .english
        .clone()
        .or_else(|| media.title.romaji.clone())
        .or_else(|| media.title.native.clone())
        .unwrap_or_else(|| format!("AniList {}", media.id));
    let original = media
        .title
        .romaji
        .or(media.title.native)
        .filter(|s| s != &title);
    let description = media.description.map(|d| strip_html(&d));
    let poster = media
        .cover_image
        .as_ref()
        .and_then(|c| c.extra_large.clone().or_else(|| c.large.clone()));
    let score = media.average_score.map(|s| s as f64);

    let existing: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM titles WHERE anilist_id = $1")
        .bind(media.id)
        .fetch_optional(&ctx.pool)
        .await?;

    let id = if let Some((id,)) = existing {
        sqlx::query(
            r#"
            UPDATE titles SET
                kind = 'anime', title = $2, original_title = $3, synopsis = $4, description = $4,
                year = $5, runtime_minutes = $6, poster_path = $7, backdrop_path = $8,
                mal_id = COALESCE($9, mal_id), last_synced_at = now()
            WHERE id = $1
            "#,
        )
        .bind(id)
        .bind(&title)
        .bind(&original)
        .bind(&description)
        .bind(media.season_year)
        .bind(media.duration)
        .bind(&poster)
        .bind(&media.banner_image)
        .bind(media.id_mal)
        .execute(&ctx.pool)
        .await?;
        id
    } else {
        let row: (Uuid,) = sqlx::query_as(
            r#"
            INSERT INTO titles (
                kind, title, original_title, synopsis, description, year, runtime_minutes,
                poster_path, backdrop_path, anilist_id, mal_id, last_synced_at
            ) VALUES ('anime', $1, $2, $3, $3, $4, $5, $6, $7, $8, $9, now())
            RETURNING id
            "#,
        )
        .bind(&title)
        .bind(&original)
        .bind(&description)
        .bind(media.season_year)
        .bind(media.duration)
        .bind(&poster)
        .bind(&media.banner_image)
        .bind(media.id)
        .bind(media.id_mal)
        .fetch_one(&ctx.pool)
        .await?;
        row.0
    };

    sqlx::query("DELETE FROM title_genres WHERE title_id = $1")
        .bind(id)
        .execute(&ctx.pool)
        .await?;
    for name in media.genres.unwrap_or_default() {
        let name = name.trim().to_string();
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
        .bind(&name)
        .fetch_one(&ctx.pool)
        .await?;
        sqlx::query(
            "INSERT INTO title_genres (title_id, genre_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(genre_id)
        .execute(&ctx.pool)
        .await?;
    }

    let format = media.format.clone().unwrap_or_default().to_ascii_uppercase();
    if !matches!(format.as_str(), "MOVIE" | "MUSIC") {
        let count = media.episodes.filter(|n| *n > 0).unwrap_or(12);
        sqlx::query(
            "UPDATE titles SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('episodes', $2::int) WHERE id = $1",
        )
        .bind(id)
        .bind(count)
        .execute(&ctx.pool)
        .await?;
        if let Err(e) = crate::db::ensure_episode_list(&ctx.pool, id, count).await {
            warn!(error = %e, %id, "anime episode list failed");
        }
    }

    upsert_ratings(ctx, id, None, None, None, None, score, media.popularity, None).await?;
    replace_credit_people(ctx, id, &people).await?;
    reindex(ctx, id).await?;
    Ok(id)
}

fn anilist_people(media: &AniMedia) -> Vec<CreditPerson> {
    let mut people = Vec::new();
    if let Some(edges) = media.characters.as_ref().and_then(|c| c.edges.as_ref()) {
        for (i, edge) in edges.iter().take(16).enumerate() {
            let Some(node) = edge.node.as_ref() else { continue };
            let Some(character_name) = node
                .name
                .as_ref()
                .and_then(|n| n.full.clone())
                .filter(|n| !n.is_empty())
            else {
                continue;
            };
            let actor = edge.voice_actors.as_ref().and_then(|actors| actors.first());
            let name = actor
                .and_then(|a| a.name.as_ref().and_then(|n| n.full.clone()))
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| character_name.clone());
            let image = actor
                .and_then(|a| a.image.as_ref().and_then(|img| img.large.clone()))
                .or_else(|| node.image.as_ref().and_then(|img| img.large.clone()));
            let role = match edge.role.as_deref() {
                Some("MAIN") => Some("Main".to_string()),
                Some("SUPPORTING") => Some("Supporting".to_string()),
                Some("BACKGROUND") => Some("Background".to_string()),
                other => other.map(|s| s.to_string()),
            };
            people.push(CreditPerson {
                name,
                character: if actor.is_some() {
                    Some(character_name)
                } else {
                    role
                },
                job: None,
                department: "cast",
                profile_path: image,
                sort_order: i as i32,
            });
        }
    }
    if let Some(edges) = media.staff.as_ref().and_then(|c| c.edges.as_ref()) {
        for (i, edge) in edges.iter().take(8).enumerate() {
            let Some(node) = edge.node.as_ref() else { continue };
            let Some(name) = node.name.as_ref().and_then(|n| n.full.clone()).filter(|n| !n.is_empty()) else {
                continue;
            };
            people.push(CreditPerson {
                name,
                character: None,
                job: edge.role.clone(),
                department: "crew",
                profile_path: node.image.as_ref().and_then(|img| img.large.clone()),
                sort_order: i as i32,
            });
        }
    }
    people
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
    html_unescape(&out).split_whitespace().collect::<Vec<_>>().join(" ")
}

fn html_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&nbsp;", " ")
        .replace("<br>", " ")
        .replace("<br />", " ")
}
