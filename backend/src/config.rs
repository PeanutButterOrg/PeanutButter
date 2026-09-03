use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use crate::error::{AppError, Result};

#[derive(Clone, Debug)]
pub struct LiveSettings {
    inner: Arc<RwLock<LiveInner>>,
}

#[derive(Debug, Clone)]
struct LiveInner {
    tmdb: String,
    omdb: String,
    anilist: Option<String>,
    media_path: PathBuf,
    app_token: String,
    jackett_enabled: bool,
    jackett_url: Option<String>,
    jackett_api_key: Option<String>,
    streaming_resolution: String,
    opensubtitles_enabled: bool,
    opensubtitles_api_key: Option<String>,
}

impl LiveSettings {
    fn new(tmdb: String, omdb: String, anilist: Option<String>, media_path: PathBuf, app_token: String) -> Self {
        Self {
            inner: Arc::new(RwLock::new(LiveInner {
                tmdb,
                omdb,
                anilist,
                media_path,
                app_token,
                jackett_enabled: false,
                jackett_url: optional_env("JACKETT_URL"),
                jackett_api_key: optional_env("JACKETT_API_KEY"),
                streaming_resolution: env_or("STREAMING_RESOLUTION", "1080p"),
                opensubtitles_enabled: false,
                opensubtitles_api_key: optional_env("OPENSUBTITLES_API_KEY"),
            })),
        }
    }

    pub fn tmdb_key(&self) -> String {
        self.inner.read().expect("settings lock").tmdb.clone()
    }

    pub fn omdb_key(&self) -> String {
        self.inner.read().expect("settings lock").omdb.clone()
    }

    pub fn anilist_id(&self) -> Option<String> {
        self.inner.read().expect("settings lock").anilist.clone()
    }

    pub fn media_path(&self) -> PathBuf {
        self.inner.read().expect("settings lock").media_path.clone()
    }

    pub fn app_token(&self) -> String {
        self.inner.read().expect("settings lock").app_token.clone()
    }

    pub fn jackett_enabled(&self) -> bool {
        self.inner.read().expect("settings lock").jackett_enabled
    }

    pub fn jackett_url(&self) -> Option<String> {
        self.inner.read().expect("settings lock").jackett_url.clone()
    }

    pub fn jackett_api_key(&self) -> Option<String> {
        self.inner.read().expect("settings lock").jackett_api_key.clone()
    }

    pub fn jackett_configured(&self) -> bool {
        let g = self.inner.read().expect("settings lock");
        g.jackett_enabled
            && g.jackett_url.as_deref().is_some_and(|s| !s.trim().is_empty())
            && g.jackett_api_key.as_deref().is_some_and(|s| !s.trim().is_empty())
    }

    pub fn streaming_resolution(&self) -> String {
        self.inner.read().expect("settings lock").streaming_resolution.clone()
    }

    pub fn set_app_token(&self, token: String) {
        self.inner.write().expect("settings lock").app_token = token;
    }

    pub fn apply(
        &self,
        tmdb: Option<String>,
        omdb: Option<String>,
        anilist: Option<Option<String>>,
        media_path: Option<PathBuf>,
    ) {
        let mut g = self.inner.write().expect("settings lock");
        if let Some(v) = tmdb {
            g.tmdb = v;
        }
        if let Some(v) = omdb {
            g.omdb = v;
        }
        if let Some(v) = anilist {
            g.anilist = v.filter(|s| !s.trim().is_empty());
        }
        if let Some(v) = media_path {
            g.media_path = v;
        }
    }

    pub fn apply_streaming(
        &self,
        jackett_enabled: Option<bool>,
        jackett_url: Option<Option<String>>,
        jackett_api_key: Option<Option<String>>,
        streaming_resolution: Option<String>,
    ) {
        let mut g = self.inner.write().expect("settings lock");
        if let Some(v) = jackett_enabled {
            g.jackett_enabled = v;
        }
        if let Some(v) = jackett_url {
            g.jackett_url = v.filter(|s| !s.trim().is_empty());
        }
        if let Some(v) = jackett_api_key {
            g.jackett_api_key = v.filter(|s| !s.trim().is_empty());
        }
        if let Some(v) = streaming_resolution {
            if matches!(v.as_str(), "2160p" | "1080p" | "720p" | "480p") {
                g.streaming_resolution = v;
            }
        }
    }

    pub fn opensubtitles_enabled(&self) -> bool {
        self.inner.read().expect("settings lock").opensubtitles_enabled
    }

    pub fn opensubtitles_api_key(&self) -> Option<String> {
        self.inner
            .read()
            .expect("settings lock")
            .opensubtitles_api_key
            .clone()
    }

    pub fn opensubtitles_configured(&self) -> bool {
        let g = self.inner.read().expect("settings lock");
        g.opensubtitles_enabled
            && g.opensubtitles_api_key
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty())
    }

    pub fn apply_opensubtitles(&self, enabled: Option<bool>, api_key: Option<Option<String>>) {
        let mut g = self.inner.write().expect("settings lock");
        if let Some(v) = enabled {
            g.opensubtitles_enabled = v;
        }
        if let Some(v) = api_key {
            g.opensubtitles_api_key = v.filter(|s| !s.trim().is_empty());
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub meili_url: String,
    pub meili_master_key: String,
    pub live: LiveSettings,
    pub bind_addr: String,
    pub public_url: String,
    pub api_key: Option<String>,
    pub sync_cron_popular: String,
    pub sync_cron_stale: String,
    pub version: &'static str,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let api_key = optional_env("API_KEY");
        let anilist = optional_env("ANILIST_CLIENT_ID");
        let media_path = PathBuf::from(env_or("MEDIA_PATH", "./media"));
        Ok(Self {
            database_url: required("DATABASE_URL")?,
            meili_url: env_or("MEILI_URL", "http://127.0.0.1:7700"),
            meili_master_key: env_or("MEILI_MASTER_KEY", ""),
            live: LiveSettings::new(
                env_or("TMDB_API_KEY", ""),
                env_or("OMDB_API_KEY", ""),
                anilist,
                media_path,
                api_key.clone().unwrap_or_default(),
            ),
            bind_addr: env_or("BIND_ADDR", "0.0.0.0:8080"),
            public_url: env_or("PUBLIC_URL", "http://127.0.0.1:8080"),
            api_key,
            sync_cron_popular: env_or("SYNC_CRON_POPULAR", "0 0 */6 * * *"),
            sync_cron_stale: env_or("SYNC_CRON_STALE", "0 30 3 * * *"),
            version: env!("CARGO_PKG_VERSION"),
        })
    }

    pub fn tmdb_key(&self) -> String {
        self.live.tmdb_key()
    }

    pub fn omdb_key(&self) -> String {
        self.live.omdb_key()
    }

    pub fn anilist_id(&self) -> Option<String> {
        self.live.anilist_id()
    }

    pub fn media_path(&self) -> PathBuf {
        self.live.media_path()
    }

    pub fn app_token(&self) -> String {
        self.live.app_token()
    }

    pub fn playback_url(&self, file_id: uuid::Uuid) -> String {
        format!(
            "{}/files/{}",
            self.public_url.trim_end_matches('/'),
            file_id
        )
    }

    pub fn poster_url(&self, path: &Option<String>) -> Option<String> {
        absolute_image_url(path)
    }
}

pub fn absolute_image_url(path: &Option<String>) -> Option<String> {
    let p = path.as_ref()?.trim();
    if p.is_empty() {
        return None;
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return Some(p.to_string());
    }
    let trimmed = p.trim_start_matches('/');
    Some(format!("https://image.tmdb.org/t/p/w780/{trimmed}"))
}

pub fn still_url(path: &Option<String>) -> Option<String> {
    let p = path.as_ref()?.trim();
    if p.is_empty() {
        return None;
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return Some(p.to_string());
    }
    let trimmed = p.trim_start_matches('/');
    Some(format!("https://image.tmdb.org/t/p/w500/{trimmed}"))
}

pub fn profile_url(path: &Option<String>) -> Option<String> {
    let p = path.as_ref()?.trim();
    if p.is_empty() {
        return None;
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return Some(p.to_string());
    }
    let trimmed = p.trim_start_matches('/');
    Some(format!("https://image.tmdb.org/t/p/w185/{trimmed}"))
}

pub fn logo_url(path: &Option<String>) -> Option<String> {
    let p = path.as_ref()?.trim();
    if p.is_empty() {
        return None;
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return Some(p.to_string());
    }
    let trimmed = p.trim_start_matches('/');
    Some(format!("https://image.tmdb.org/t/p/w500/{trimmed}"))
}

pub fn backdrop_url(path: &Option<String>) -> Option<String> {
    let p = path.as_ref()?.trim();
    if p.is_empty() {
        return None;
    }
    if p.starts_with("http://") || p.starts_with("https://") {
        return Some(p.to_string());
    }
    let trimmed = p.trim_start_matches('/');
    Some(format!("https://image.tmdb.org/t/p/w1280/{trimmed}"))
}

fn required(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| AppError::Config(format!("missing required env var {key}")))
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn optional_env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|s| !s.trim().is_empty())
}
