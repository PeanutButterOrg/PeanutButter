use std::sync::Arc;

use meilisearch_sdk::client::Client;
use meilisearch_sdk::search::MatchingStrategies;
use meilisearch_sdk::settings::{MinWordSizeForTypos, TypoToleranceSettings};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use uuid::Uuid;

use crate::db::models::TitleRow;
use crate::error::Result;

const INDEX: &str = "titles";

#[derive(Clone)]
pub struct SearchClient {
    inner: Arc<Inner>,
}

struct Inner {
    client: Client,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TitleDocument {
    pub id: String,
    pub title: String,
    pub original_title: String,
    pub synopsis: String,
    pub kind: String,
    pub year: i32,
    pub genres: Vec<String>,
    pub rating: f64,
    pub poster_path: String,
}

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub id: Uuid,
    pub title: String,
    pub kind: String,
    pub year: Option<i32>,
    pub poster_path: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SearchPage {
    pub hits: Vec<SearchHit>,
    pub estimated_total: usize,
}

impl SearchClient {
    pub async fn new(url: &str, master_key: &str) -> Result<Self> {
        let key = if master_key.is_empty() {
            None
        } else {
            Some(master_key)
        };
        let client = Client::new(url, key)?;
        let this = Self {
            inner: Arc::new(Inner { client }),
        };
        this.ensure_index().await?;
        Ok(this)
    }

    async fn ensure_index(&self) -> Result<()> {
        let index = self.inner.client.index(INDEX);
        match index
            .set_filterable_attributes(&["kind", "year", "genres"])
            .await
        {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not set filterable attributes"),
        }
        match index
            .set_sortable_attributes(&["year", "title", "rating"])
            .await
        {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not set sortable attributes"),
        }
        match index
            .set_searchable_attributes(&["title", "original_title", "synopsis"])
            .await
        {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not set searchable attributes"),
        }
        // exactness before sort so "The Matrix" beats a longer title that merely
        // contains those words. Typos must not match synopsis text.
        match index
            .set_ranking_rules([
                "words",
                "typo",
                "proximity",
                "attribute",
                "exactness",
                "sort",
            ])
            .await
        {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not set ranking rules"),
        }
        let typo = TypoToleranceSettings {
            enabled: Some(true),
            disable_on_attributes: Some(vec!["synopsis".to_string()]),
            disable_on_words: None,
            min_word_size_for_typos: Some(MinWordSizeForTypos {
                one_typo: Some(5),
                two_typos: Some(9),
            }),
        };
        match index.set_typo_tolerance(&typo).await {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not set typo tolerance"),
        }
        info!("meilisearch index `{INDEX}` is ready");
        Ok(())
    }

    pub async fn health(&self) -> bool {
        self.inner.client.health().await.is_ok()
    }

    pub async fn index_title(&self, title: &TitleRow, genres: &[String], rating: Option<f64>) -> Result<()> {
        let doc = TitleDocument {
            id: title.id.to_string(),
            title: title.title.clone(),
            original_title: title.original_title.clone().unwrap_or_default(),
            synopsis: title
                .synopsis
                .clone()
                .or_else(|| title.description.clone())
                .unwrap_or_default(),
            kind: title.kind.clone(),
            year: title.year.unwrap_or(0),
            genres: genres.to_vec(),
            rating: rating.unwrap_or(0.0),
            poster_path: title.poster_path.clone().unwrap_or_default(),
        };
        let index = self.inner.client.index(INDEX);
        // Fire-and-forget: waiting for Meili per title was the #1 sync bottleneck.
        let _ = index.add_or_replace(&[doc], Some("id")).await?;
        Ok(())
    }

    pub async fn index_titles_batch(
        &self,
        docs: &[TitleDocument],
    ) -> Result<()> {
        if docs.is_empty() {
            return Ok(());
        }
        let index = self.inner.client.index(INDEX);
        let _ = index.add_or_replace(docs, Some("id")).await?;
        Ok(())
    }

    pub fn title_document(
        title: &TitleRow,
        genres: &[String],
        rating: Option<f64>,
    ) -> TitleDocument {
        TitleDocument {
            id: title.id.to_string(),
            title: title.title.clone(),
            original_title: title.original_title.clone().unwrap_or_default(),
            synopsis: title
                .synopsis
                .clone()
                .or_else(|| title.description.clone())
                .unwrap_or_default(),
            kind: title.kind.clone(),
            year: title.year.unwrap_or(0),
            genres: genres.to_vec(),
            rating: rating.unwrap_or(0.0),
            poster_path: title.poster_path.clone().unwrap_or_default(),
        }
    }

    pub async fn delete_title(&self, id: Uuid) -> Result<()> {
        let index = self.inner.client.index(INDEX);
        let task = index.delete_document(id.to_string()).await?;
        let _ = task.wait_for_completion(&self.inner.client, None, None).await;
        Ok(())
    }

    pub async fn clear_all(&self) -> Result<()> {
        let index = self.inner.client.index(INDEX);
        match index.delete_all_documents().await {
            Ok(task) => {
                let _ = task.wait_for_completion(&self.inner.client, None, None).await;
            }
            Err(e) => warn!(error = %e, "could not clear meilisearch index"),
        }
        Ok(())
    }

    pub async fn search(
        &self,
        query: &str,
        kind: Option<&str>,
        page: usize,
        per_page: usize,
    ) -> Result<SearchPage> {
        let index = self.inner.client.index(INDEX);
        let offset = page.saturating_sub(1).saturating_mul(per_page);
        let mut req = index.search();
        req.with_query(query)
            .with_limit(per_page)
            .with_offset(offset)
            .with_matching_strategy(MatchingStrategies::FREQUENCY);
        let filter;
        if let Some(kind) = kind {
            filter = format!("kind = \"{kind}\"");
            req.with_filter(&filter);
        }
        let results = req.execute::<TitleDocument>().await?;
        let hits = results
            .hits
            .into_iter()
            .filter_map(|h| {
                let doc = h.result;
                let id = Uuid::parse_str(&doc.id).ok()?;
                Some(SearchHit {
                    id,
                    title: doc.title,
                    kind: doc.kind,
                    year: if doc.year > 0 { Some(doc.year) } else { None },
                    poster_path: if doc.poster_path.is_empty() {
                        None
                    } else {
                        Some(doc.poster_path)
                    },
                })
            })
            .collect();
        Ok(SearchPage {
            hits,
            estimated_total: results.estimated_total_hits.unwrap_or(0),
        })
    }
}

/// How well [query] names this title. Higher is a closer match.
/// A trailing year (`dune 2021`) boosts the matching release and sinks others.
pub fn search_relevance(query: &str, title: &str, original_title: &str, year: Option<i32>) -> i32 {
    let folded = fold_search(query);
    let (q, wanted_year) = split_trailing_year(&folded);
    let primary = score_name(q, &fold_search(title));
    let original = score_name(q, &fold_search(original_title)).saturating_sub(50);
    let mut score = primary.max(original);
    if q.is_empty() {
        if let (Some(want), Some(have)) = (wanted_year, year) {
            if want == have {
                return 500;
            }
        }
        return 0;
    }
    if let (Some(want), Some(have)) = (wanted_year, year) {
        if want == have {
            score += 1500;
        } else if score > 0 {
            score -= 200;
        }
    }
    score
}

fn fold_search(raw: &str) -> String {
    raw.chars()
        .flat_map(|c| c.to_lowercase())
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn split_trailing_year(folded: &str) -> (&str, Option<i32>) {
    let Some((rest, year_tok)) = folded.rsplit_once(' ') else {
        return year_only(folded);
    };
    match parse_year_token(year_tok) {
        Some(year) => (rest, Some(year)),
        None => (folded, None),
    }
}

fn year_only(folded: &str) -> (&str, Option<i32>) {
    match parse_year_token(folded) {
        Some(year) => ("", Some(year)),
        None => (folded, None),
    }
}

fn parse_year_token(token: &str) -> Option<i32> {
    if token.len() != 4 {
        return None;
    }
    let year: i32 = token.parse().ok()?;
    if (1900..=2100).contains(&year) {
        Some(year)
    } else {
        None
    }
}

fn score_name(q: &str, name: &str) -> i32 {
    if q.is_empty() || name.is_empty() {
        return 0;
    }
    if name == q {
        return 10_000;
    }
    let q_tokens: Vec<&str> = q.split(' ').filter(|t| !t.is_empty()).collect();
    let name_tokens: Vec<&str> = name.split(' ').filter(|t| !t.is_empty()).collect();
    if q_tokens.is_empty() {
        return 0;
    }
    if name.starts_with(q) {
        return 8_000;
    }
    if name.contains(q) {
        return 6_000;
    }
    let matched = q_tokens
        .iter()
        .filter(|t| name_tokens.iter().any(|n| *n == **t))
        .count();
    let prefix_matched = q_tokens
        .iter()
        .filter(|t| name_tokens.iter().any(|n| n.starts_with(**t)))
        .count();
    if matched == q_tokens.len() {
        let extra = name_tokens.len().saturating_sub(q_tokens.len()) as i32;
        return 5_000 - extra * 40;
    }
    if prefix_matched == q_tokens.len() {
        let extra = name_tokens.len().saturating_sub(q_tokens.len()) as i32;
        return 3_000 - extra * 20;
    }
    (matched as i32) * 200 + (prefix_matched as i32) * 50
}

#[cfg(test)]
mod tests {
    use super::search_relevance;

    #[test]
    fn exact_title_beats_a_longer_one() {
        let exact = search_relevance("the matrix", "The Matrix", "", Some(1999));
        let sequel = search_relevance("the matrix", "The Matrix Reloaded", "", Some(2003));
        assert!(exact > sequel, "{exact} should beat {sequel}");
    }

    #[test]
    fn hyphenated_title_matches_spaced_query() {
        let score = search_relevance("spider man", "Spider-Man", "", Some(2002));
        assert!(score >= 10_000, "{score}");
    }

    #[test]
    fn typed_year_prefers_that_release() {
        let y2021 = search_relevance("dune 2021", "Dune", "", Some(2021));
        let y1984 = search_relevance("dune 2021", "Dune", "", Some(1984));
        assert!(y2021 > y1984, "{y2021} should beat {y1984}");
    }

    #[test]
    fn title_match_beats_unrelated_name() {
        let hit = search_relevance("inception", "Inception", "", Some(2010));
        let miss = search_relevance("inception", "The Office", "", Some(2005));
        assert!(hit > miss, "{hit} should beat {miss}");
    }
}
