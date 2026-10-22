use std::time::Duration;

use async_graphql::parser::types::{DocumentOperations, OperationType, Selection};
use moka::future::Cache;
use serde_json::Value;

/// Mutations that only change the calling device's own rows (progress,
/// favourites, stream bookmarks). They must not flush every device's cache —
/// players send these every few seconds.
const PERSONAL_MUTATIONS: &[&str] = &[
    "updateProgress",
    "streamResume",
    "setFavorite",
    "setWatched",
    "startStream",
    "stopStream",
];

#[derive(Debug, PartialEq, Eq)]
pub enum RequestKind {
    Query,
    /// Only [PERSONAL_MUTATIONS]: invalidate the caller's entries.
    PersonalMutation,
    /// Anything else that writes (or can't be parsed): invalidate everything.
    GlobalMutation,
}

pub fn classify(query: &str) -> RequestKind {
    let Ok(doc) = async_graphql::parser::parse_query(query) else {
        // Unparseable requests fail in execution anyway; never serve them
        // from cache and be conservative about writes.
        return RequestKind::GlobalMutation;
    };
    let ops: Vec<_> = match &doc.operations {
        DocumentOperations::Single(op) => vec![op],
        DocumentOperations::Multiple(map) => map.values().collect(),
    };
    let mut saw_mutation = false;
    for op in ops {
        if op.node.ty != OperationType::Mutation {
            continue;
        }
        saw_mutation = true;
        for item in &op.node.selection_set.node.items {
            match &item.node {
                Selection::Field(f) if PERSONAL_MUTATIONS.contains(&f.node.name.node.as_str()) => {}
                _ => return RequestKind::GlobalMutation,
            }
        }
    }
    if saw_mutation {
        RequestKind::PersonalMutation
    } else {
        RequestKind::Query
    }
}

#[derive(Clone)]
pub struct GqlCache {
    inner: Cache<String, Value>,
}

impl GqlCache {
    pub fn new() -> Self {
        Self {
            inner: Cache::builder()
                .max_capacity(512)
                .time_to_live(Duration::from_secs(30))
                .support_invalidation_closures()
                .build(),
        }
    }

    /// Keys are `"{token_scope}:{query}:{variables}"`.
    pub fn key(token_scope: &str, query: &str, variables: &impl std::fmt::Debug) -> String {
        format!("{token_scope}:{query}:{variables:?}")
    }

    pub async fn get(&self, key: &str) -> Option<Value> {
        self.inner.get(key).await
    }

    pub async fn insert(&self, key: String, value: Value) {
        self.inner.insert(key, value).await;
    }

    pub fn invalidate(&self) {
        self.inner.invalidate_all();
    }

    /// Drop only one device's cached responses.
    pub fn invalidate_scope(&self, token_scope: &str) {
        let prefix = format!("{token_scope}:");
        // Only fails if closures weren't enabled at build time; fall back.
        if self
            .inner
            .invalidate_entries_if(move |k, _| k.starts_with(&prefix))
            .is_err()
        {
            self.inner.invalidate_all();
        }
    }
}

impl Default for GqlCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_requests() {
        assert_eq!(classify("query { homeFeed(kind: MOVIE) { trending { id } } }"), RequestKind::Query);
        assert_eq!(classify("{ genres }"), RequestKind::Query);
        assert_eq!(
            classify("mutation M($t: ID!) { updateProgress(titleId: $t, positionMs: 1) { ok } }"),
            RequestKind::PersonalMutation
        );
        assert_eq!(
            classify("# leading comment\nmutation { updateSettings(input: {}) { ok } }"),
            RequestKind::GlobalMutation
        );
        assert_eq!(
            classify("mutation { setWatched(titleId: \"x\", watched: true) { ok } deleteTitle(id: \"x\") { ok } }"),
            RequestKind::GlobalMutation
        );
        assert_eq!(classify("not graphql"), RequestKind::GlobalMutation);
    }
}
