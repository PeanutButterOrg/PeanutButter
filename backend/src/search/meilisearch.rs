use std::sync::Arc;

use meilisearch_sdk::client::Client;
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
        let task = index.add_or_replace(&[doc], Some("id")).await?;
        let _ = task.wait_for_completion(&self.inner.client, None, None).await;
        Ok(())
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
            .with_offset(offset);
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
