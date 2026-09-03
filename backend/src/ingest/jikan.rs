use serde::Deserialize;
use tracing::{info, warn};
use uuid::Uuid;

use super::{throttle, IngestContext};
use crate::error::{AppError, Result};
use crate::ingest::tmdb::{replace_credit_people, CreditPerson};

const JIKAN_CHARS: &str = "https://api.jikan.moe/v4/anime/{id}/characters";

#[derive(Debug, Deserialize)]
struct JikanResponse {
    data: Option<Vec<JikanEdge>>,
}

#[derive(Debug, Deserialize)]
struct JikanEdge {
    character: JikanCharacter,
    #[allow(dead_code)]
    role: Option<String>,
    voice_actors: Option<Vec<JikanVoice>>,
}

#[derive(Debug, Deserialize)]
struct JikanCharacter {
    name: Option<String>,
    images: Option<JikanImages>,
}

#[derive(Debug, Deserialize)]
struct JikanVoice {
    language: Option<String>,
    person: Option<JikanPerson>,
}

#[derive(Debug, Deserialize)]
struct JikanPerson {
    name: Option<String>,
    images: Option<JikanImages>,
}

#[derive(Debug, Deserialize)]
struct JikanImages {
    jpg: Option<JikanJpg>,
}

#[derive(Debug, Deserialize)]
struct JikanJpg {
    image_url: Option<String>,
}

pub async fn fill_missing_people(ctx: &IngestContext) -> Result<()> {
    let rows: Vec<(Uuid, i32)> = sqlx::query_as(
        r#"
        SELECT t.id, t.mal_id
        FROM titles t
        WHERE t.kind = 'anime'
          AND t.mal_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM title_people p WHERE p.title_id = t.id)
        ORDER BY t.updated_at DESC NULLS LAST
        LIMIT 400
        "#,
    )
    .fetch_all(&ctx.pool)
    .await?;

    if rows.is_empty() {
        return Ok(());
    }
    info!(count = rows.len(), "filling missing anime cast from Jikan/MAL");
    for (id, mal_id) in rows {
        match fetch_characters(ctx, mal_id).await {
            Ok(people) if people.is_empty() => {
                warn!(%id, mal_id, "Jikan returned no people");
            }
            Ok(people) => {
                if let Err(e) = replace_credit_people(ctx, id, &people).await {
                    warn!(%id, error = %e, "anime people write failed");
                }
            }
            Err(e) if e.to_string().contains("429") => {
                warn!("Jikan rate limited; pausing people backfill");
                tokio::time::sleep(std::time::Duration::from_secs(8)).await;
            }
            Err(e) => warn!(%id, mal_id, error = %e, "Jikan people fetch failed"),
        }
        throttle().await;
        tokio::time::sleep(std::time::Duration::from_millis(350)).await;
    }
    Ok(())
}

async fn fetch_characters(ctx: &IngestContext, mal_id: i32) -> Result<Vec<CreditPerson>> {
    let url = JIKAN_CHARS.replace("{id}", &mal_id.to_string());
    let resp = ctx.http.get(url).header("Accept", "application/json").send().await?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        return Err(AppError::Provider(format!(
            "Jikan {status}: {}",
            text.chars().take(160).collect::<String>()
        )));
    }
    let parsed: JikanResponse = resp.json().await?;
    Ok(jikan_people(&parsed.data.unwrap_or_default()))
}

fn jikan_people(edges: &[JikanEdge]) -> Vec<CreditPerson> {
    let mut people = Vec::new();
    for (i, edge) in edges.iter().take(16).enumerate() {
        let Some(character_name) = edge
            .character
            .name
            .as_ref()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let va = edge.voice_actors.as_ref().and_then(|actors| {
            actors
                .iter()
                .find(|a| a.language.as_deref() == Some("Japanese"))
                .or_else(|| actors.first())
        });
        let actor_name = va
            .and_then(|a| a.person.as_ref())
            .and_then(|p| p.name.clone())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let image = va
            .and_then(|a| a.person.as_ref())
            .and_then(|p| image_url(p.images.as_ref()))
            .or_else(|| image_url(edge.character.images.as_ref()));
        people.push(CreditPerson {
            name: actor_name.unwrap_or_else(|| character_name.clone()),
            character: Some(character_name),
            job: None,
            department: "cast",
            profile_path: image,
            sort_order: i as i32,
        });
    }
    people
}

fn image_url(images: Option<&JikanImages>) -> Option<String> {
    images
        .and_then(|img| img.jpg.as_ref())
        .and_then(|jpg| jpg.image_url.clone())
        .filter(|s| !s.is_empty())
}
