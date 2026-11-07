//! Catalog add-ons (e.g. Streaming Catalogs: "Netflix", "HBO Max", "Disney+"
//! lists) in the home Trending row.
//!
//! [sync] fetches the top of every enabled add-on catalog
//! (`GET {base}/catalog/{type}/{id}.json`, Stremio protocol), imports titles
//! that aren't in the catalog yet from TMDB by IMDb id, and stores the ranks
//! in `addon_catalog_items`. The Trending row then mixes a few of them in
//! ([mix]: every third slot at most, one title once) and tags each card
//! with the services it's on ([ServiceTag]). Nothing else changes: no extra
//! rows, no tags outside Trending.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::Value;
use tracing::{info, warn};
use uuid::Uuid;

use crate::graphql::types::ServiceTag;
use crate::ingest::IngestContext;
use crate::providers::{Addon, AddonCatalog};

/// Top items kept from each list. Trending shows only a few of them; the
/// rest stand in when the top ones are filtered out (language, unreleased).
pub const ITEMS_PER_CATALOG: usize = 20;
const FETCH_TIMEOUT: Duration = Duration::from_secs(15);
/// Tags shown per card at most.
const MAX_TAGS: usize = 3;

static SYNCING: AtomicBool = AtomicBool::new(false);

/// Run [sync] in the background (skipped when one is already running).
pub fn spawn_sync(ctx: IngestContext) {
    tokio::spawn(async move {
        if SYNCING.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Err(e) = sync(&ctx).await {
            warn!(error = %e, "add-on catalog sync failed");
        }
        SYNCING.store(false, Ordering::SeqCst);
    });
}

/// Refresh the stored lists of every enabled catalog add-on; drop the lists
/// of add-ons that were disabled or removed. A list that fails to load keeps
/// its previous items.
pub async fn sync(ctx: &IngestContext) -> crate::error::Result<()> {
    let addons: Vec<Addon> = crate::providers::snapshot()
        .addons
        .into_iter()
        .filter(|a| a.enabled && !a.catalogs.is_empty())
        .collect();
    let keep: Vec<String> = addons.iter().map(|a| a.id.clone()).collect();
    sqlx::query("DELETE FROM addon_catalog_items WHERE NOT (addon_id = ANY($1))")
        .bind(&keep)
        .execute(&ctx.pool)
        .await?;
    for addon in &addons {
        for cat in &addon.catalogs {
            let ids = match fetch_ids(&ctx.http, &addon.url, cat).await {
                Ok(ids) => ids,
                Err(e) => {
                    warn!(addon = %addon.name, catalog = %cat.name, error = %e, "add-on catalog unavailable");
                    continue;
                }
            };
            let media = if cat.kind == "movie" { "movie" } else { "series" };
            for imdb in &ids {
                let known: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM titles WHERE imdb_id = $1 LIMIT 1")
                    .bind(imdb)
                    .fetch_optional(&ctx.pool)
                    .await?;
                if known.is_none() {
                    let r = crate::ingest::tmdb::TitleRef::Imdb(imdb.clone());
                    if let Err(e) = crate::ingest::tmdb::ingest_by_ref(ctx, &r, Some(media)).await {
                        warn!(%imdb, error = %e, "couldn't import add-on catalog title");
                    }
                }
            }
            let mut tx = ctx.pool.begin().await?;
            sqlx::query("DELETE FROM addon_catalog_items WHERE addon_id = $1 AND catalog_id = $2 AND media = $3")
                .bind(&addon.id)
                .bind(&cat.id)
                .bind(media)
                .execute(&mut *tx)
                .await?;
            for (rank, imdb) in ids.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO addon_catalog_items (addon_id, catalog_id, media, service, imdb_id, rank) \
                     VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING",
                )
                .bind(&addon.id)
                .bind(&cat.id)
                .bind(media)
                .bind(&cat.name)
                .bind(imdb)
                .bind(rank as i32 + 1)
                .execute(&mut *tx)
                .await?;
            }
            tx.commit().await?;
            info!(addon = %addon.name, catalog = %cat.name, media, items = ids.len(), "add-on catalog synced");
        }
    }
    Ok(())
}

async fn fetch_ids(http: &reqwest::Client, base: &str, cat: &AddonCatalog) -> Result<Vec<String>, String> {
    let url = format!("{base}/catalog/{}/{}.json", cat.kind, cat.id);
    let res = http
        .get(&url)
        .timeout(FETCH_TIMEOUT)
        .send()
        .await
        .map_err(|e| if e.is_timeout() { "timed out".to_string() } else { "unreachable".to_string() })?;
    if !res.status().is_success() {
        return Err(format!("HTTP {}", res.status().as_u16()));
    }
    let body: Value = res.json().await.map_err(|_| "not a Stremio catalog response".to_string())?;
    Ok(imdb_ids(body.get("metas").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default()))
}

/// IMDb ids of a catalog's `metas`, in order, once each, at most [ITEMS_PER_CATALOG].
fn imdb_ids(metas: &[Value]) -> Vec<String> {
    let is_imdb = |s: &str| s.len() > 2 && s.starts_with("tt") && s[2..].bytes().all(|b| b.is_ascii_digit());
    let mut seen = HashSet::new();
    metas
        .iter()
        .filter_map(|m| {
            let id = m.get("id").and_then(Value::as_str).map(str::trim);
            let imdb = m.get("imdb_id").and_then(Value::as_str).map(str::trim);
            id.filter(|s| is_imdb(s)).or(imdb.filter(|s| is_imdb(s))).map(str::to_string)
        })
        .filter(|id| seen.insert(id.clone()))
        .take(ITEMS_PER_CATALOG)
        .collect()
}

/// Badge slug for a list name: known services by name, else a slug of it.
pub fn service_id(name: &str) -> String {
    let n: String = name.to_ascii_lowercase().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    const KNOWN: &[(&str, &str)] = &[
        ("netflix", "netflix"),
        ("hbo", "hbo"),
        ("max", "hbo"),
        ("disney", "disney"),
        ("prime", "prime"),
        ("amazon", "prime"),
        ("appletv", "apple"),
        ("apple", "apple"),
        ("hulu", "hulu"),
        ("paramount", "paramount"),
        ("peacock", "peacock"),
        ("crunchyroll", "crunchyroll"),
        ("hotstar", "hotstar"),
        ("zee5", "zee5"),
        ("sonyliv", "sonyliv"),
        ("mubi", "mubi"),
        ("starz", "starz"),
        ("showtime", "showtime"),
        ("curiosity", "curiositystream"),
        ("discovery", "discovery"),
    ];
    KNOWN
        .iter()
        .find(|(key, _)| if *key == "max" { n == "max" || n.starts_with("max") } else { n.contains(key) })
        .map(|(_, id)| id.to_string())
        .unwrap_or(n)
}

/// One title per entry, taking each service's #1, then each one's #2, …
/// (`rows` are (title, service, rank)), so no single service fills the row.
pub fn round_robin(rows: &[(Uuid, String, i32)]) -> Vec<Uuid> {
    let mut by_service: Vec<(String, Vec<(i32, Uuid)>)> = Vec::new();
    for (id, service, rank) in rows {
        match by_service.iter_mut().find(|(s, _)| s == service) {
            Some((_, list)) => list.push((*rank, *id)),
            None => by_service.push((service.clone(), vec![(*rank, *id)])),
        }
    }
    for (_, list) in &mut by_service {
        list.sort();
    }
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let longest = by_service.iter().map(|(_, l)| l.len()).max().unwrap_or(0);
    for i in 0..longest {
        for (_, list) in &by_service {
            if let Some((_, id)) = list.get(i) {
                if seen.insert(*id) {
                    out.push(*id);
                }
            }
        }
    }
    out
}

/// Trending as it was, with add-on titles in every third slot (fewer when
/// there aren't enough), each title once, `limit` in all.
pub fn mix<T>(trending: Vec<T>, addon: Vec<T>, id: impl Fn(&T) -> Uuid, limit: usize) -> Vec<T> {
    let mut seen = HashSet::new();
    let mut a = trending.into_iter().peekable();
    let mut b = addon.into_iter().peekable();
    let mut out = Vec::with_capacity(limit);
    let mut take = |it: &mut std::iter::Peekable<std::vec::IntoIter<T>>, out: &mut Vec<T>| -> bool {
        for t in it.by_ref() {
            if seen.insert(id(&t)) {
                out.push(t);
                return true;
            }
        }
        false
    };
    while out.len() < limit {
        let addon_slot = out.len() % 3 == 2;
        let got = if addon_slot {
            take(&mut b, &mut out) || take(&mut a, &mut out)
        } else {
            take(&mut a, &mut out) || take(&mut b, &mut out)
        };
        if !got {
            break;
        }
    }
    out
}

/// Tags for each title: the services whose lists have it, best rank first.
pub fn tags(rows: &[(Uuid, String, i32)]) -> HashMap<Uuid, Vec<ServiceTag>> {
    let mut sorted: Vec<&(Uuid, String, i32)> = rows.iter().collect();
    sorted.sort_by(|a, b| a.2.cmp(&b.2).then_with(|| a.1.cmp(&b.1)));
    let mut out: HashMap<Uuid, Vec<ServiceTag>> = HashMap::new();
    for (id, service, _) in sorted {
        let list = out.entry(*id).or_default();
        let tag = ServiceTag { id: service_id(service), name: service.clone() };
        if list.len() < MAX_TAGS && !list.iter().any(|t| t.id == tag.id) {
            list.push(tag);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn u(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    #[test]
    fn reads_imdb_ids_from_catalog_metas() {
        let metas = vec![
            json!({"id": "tt23289160", "imdb_id": "tt23289160", "name": "Godzilla Minus One", "type": "movie"}),
            json!({"id": "kitsu:1", "name": "Anime"}),
            json!({"id": "tmdb:5", "imdb_id": "tt0000005"}),
            json!({"id": "tt23289160"}),
            json!({"name": "no id"}),
        ];
        assert_eq!(imdb_ids(&metas), vec!["tt23289160", "tt0000005"]);
        let many: Vec<Value> = (0..50).map(|i| json!({"id": format!("tt{i:07}")})).collect();
        assert_eq!(imdb_ids(&many).len(), ITEMS_PER_CATALOG);
    }

    #[test]
    fn service_ids_for_badges() {
        assert_eq!(service_id("Netflix"), "netflix");
        assert_eq!(service_id("HBO Max"), "hbo");
        assert_eq!(service_id("Max"), "hbo");
        assert_eq!(service_id("Disney+"), "disney");
        assert_eq!(service_id("Prime  Video"), "prime");
        assert_eq!(service_id("Apple TV+"), "apple");
        assert_eq!(service_id("Paramount+"), "paramount");
        assert_eq!(service_id("Top Picks"), "toppicks");
    }

    #[test]
    fn round_robin_takes_each_services_best_first_and_dedupes() {
        let rows = vec![
            (u(1), "Netflix".into(), 1),
            (u(2), "Netflix".into(), 2),
            (u(3), "Netflix".into(), 3),
            (u(4), "HBO Max".into(), 1),
            (u(1), "HBO Max".into(), 2), // also on Netflix
            (u(5), "Disney+".into(), 1),
        ];
        assert_eq!(round_robin(&rows), vec![u(1), u(4), u(5), u(2), u(3)]);
    }

    #[test]
    fn mix_puts_addon_titles_in_every_third_slot_without_duplicates() {
        let trending: Vec<Uuid> = (1..=20).map(u).collect();
        // u(2) is on TMDB trending and on an add-on list: listed once.
        let addon = vec![u(2), u(101), u(102), u(103), u(104), u(105), u(106), u(107)];
        let row = mix(trending, addon, |x| *x, 18);
        assert_eq!(row.len(), 18);
        let unique: HashSet<_> = row.iter().collect();
        assert_eq!(unique.len(), 18, "{row:?}");
        assert_eq!(&row[..6], &[u(1), u(2), u(101), u(3), u(4), u(102)]);
        assert_eq!(row.iter().filter(|x| x.as_u128() > 100).count(), 6);
    }

    #[test]
    fn mix_without_addon_lists_is_trending_unchanged() {
        let trending: Vec<Uuid> = (1..=20).map(u).collect();
        assert_eq!(mix(trending.clone(), vec![], |x| *x, 18), trending[..18].to_vec());
        // Short trending: add-on titles fill in.
        let row = mix(vec![u(1)], vec![u(101), u(102)], |x| *x, 18);
        assert_eq!(row, vec![u(1), u(101), u(102)]);
    }

    #[test]
    fn tags_are_unique_per_service_and_capped() {
        let rows = vec![
            (u(1), "Netflix".into(), 4),
            (u(1), "HBO Max".into(), 1),
            (u(1), "Max".into(), 2),
            (u(1), "Disney+".into(), 3),
            (u(1), "Prime Video".into(), 5),
        ];
        let t = tags(&rows);
        let names: Vec<&str> = t[&u(1)].iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["HBO Max", "Disney+", "Netflix"]);
    }

    /// Network test against the real Streaming Catalogs add-on:
    /// `cargo test -- --ignored live_streaming_catalogs --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn live_streaming_catalogs() {
        let base = "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club";
        let http = reqwest::Client::new();
        let manifest: Value = http.get(format!("{base}/manifest.json")).send().await.unwrap().json().await.unwrap();
        let cats: Vec<AddonCatalog> = manifest["catalogs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| AddonCatalog {
                kind: c["type"].as_str().unwrap().into(),
                id: c["id"].as_str().unwrap().into(),
                name: c["name"].as_str().unwrap().split_whitespace().collect::<Vec<_>>().join(" "),
            })
            .collect();
        for cat in &cats {
            let ids = fetch_ids(&http, base, cat).await.unwrap();
            println!("{:<7} {:<12} {:<10} {} ids, first {:?}", cat.kind, cat.name, service_id(&cat.name), ids.len(), ids.first());
            assert!(!ids.is_empty());
        }
    }
}
