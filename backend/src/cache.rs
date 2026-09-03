use std::time::Duration;

use moka::future::Cache;
use serde_json::Value;

#[derive(Clone)]
pub struct GqlCache {
    inner: Cache<String, Value>,
}

impl GqlCache {
    pub fn new() -> Self {
        Self {
            inner: Cache::builder()
                .max_capacity(256)
                .time_to_live(Duration::from_secs(30))
                .build(),
        }
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
}

impl Default for GqlCache {
    fn default() -> Self {
        Self::new()
    }
}
