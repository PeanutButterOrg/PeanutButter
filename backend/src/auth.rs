use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap, Method, Request};
use axum::middleware::Next;
use axum::response::{IntoResponse, Redirect, Response};
use axum::Json;
use moka::future::Cache;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::OnceLock;
use std::time::Duration;
use tracing::warn;
use uuid::Uuid;

use crate::error::AppError;
use crate::ratelimit::{self, Bucket};
use crate::HttpState;

#[derive(Clone, Debug)]
pub struct AuthSession {
    pub token_id: Uuid,
    pub is_admin: bool,
    #[allow(dead_code)]
    pub name: String,
}

impl AuthSession {
    /// Server-wide changes (keys, media folder, catalog edits) are admin-only.
    pub fn require_admin(&self) -> async_graphql::Result<()> {
        if self.is_admin {
            Ok(())
        } else {
            Err(async_graphql::Error::new(
                "Only the server's admin device can change this. Use the server console.",
            ))
        }
    }
}

pub fn token_matches(provided: &str, expected: &str) -> bool {
    if provided.len() != expected.len() || expected.is_empty() {
        return false;
    }
    provided
        .bytes()
        .zip(expected.bytes())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

pub fn extract_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("x-api-key")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            headers
                .get(header::AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.strip_prefix("Bearer "))
                .filter(|s| !s.is_empty())
        })
}

/// Also accept `?key=` / `?token=` so external Android players (VLC, mpv)
/// can open media URLs without custom HTTP headers.
pub fn extract_token_from_query(query: Option<&str>) -> Option<&str> {
    let q = query?;
    for pair in q.split('&') {
        let mut parts = pair.splitn(2, '=');
        let name = parts.next()?.to_ascii_lowercase();
        if name != "key" && name != "token" {
            continue;
        }
        let value = parts.next().unwrap_or("").trim();
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

/// Resolved keys, so every request isn't a database round trip.
fn session_cache() -> &'static Cache<String, AuthSession> {
    static CACHE: OnceLock<Cache<String, AuthSession>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Cache::builder()
            .max_capacity(10_000)
            .time_to_live(Duration::from_secs(60))
            .build()
    })
}

/// Call after removing a device or changing its role.
pub fn forget_sessions() {
    session_cache().invalidate_all();
}

pub async fn resolve_token(state: &HttpState, provided: &str) -> Result<AuthSession, AppError> {
    let provided = provided.trim();
    let cache_key = crate::db::hash_device_key(provided);
    if let Some(hit) = session_cache().get(&cache_key).await {
        return Ok(hit);
    }
    let device = if crate::db::looks_like_device_key(provided) {
        crate::db::find_device_by_key(&state.app.pool, provided).await?
    } else {
        let legacy = crate::db::find_device_by_legacy_code(&state.app.pool, provided).await?;
        if let Some(d) = &legacy {
            warn!(device = %d.name, "legacy 6-digit code used as API token; update the app");
        }
        legacy
    };
    let Some(device) = device else {
        return Err(AppError::Unauthorized("invalid API token".into()));
    };
    let session = AuthSession {
        token_id: device.id,
        is_admin: device.is_admin,
        name: device.name,
    };
    session_cache().insert(cache_key, session.clone()).await;
    Ok(session)
}

fn is_media_get(method: &Method, path: &str) -> bool {
    (method == Method::GET || method == Method::HEAD)
        && (path.starts_with("/stream/")
            || path.starts_with("/files/")
            || path.starts_with("/updates/files/"))
}

pub async fn gate(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    mut req: Request<axum::body::Body>,
    next: Next,
) -> Result<Response, AppError> {
    let path = req.uri().path().to_string();
    let method = req.method().clone();
    if method == Method::OPTIONS || path == "/health" || path == "/pair" {
        return Ok(next.run(req).await);
    }
    // Public art proxy — TVs often lack DNS for image.tmdb.org / YouTube.
    if path.starts_with("/art/") && (method == Method::GET || method == Method::HEAD) {
        return Ok(next.run(req).await);
    }
    // Opaque stream session IDs are the capability token — external Android
    // players (VLC/mpv) cannot set X-Api-Key headers. Optional ?key= still works.
    if path.starts_with("/stream/") && (method == Method::GET || method == Method::HEAD) {
        return Ok(next.run(req).await);
    }
    if path == "/" || path == "/tokens" {
        return Ok(next.run(req).await);
    }
    // Console Sync tab uses the admin session cookie (not a device token).
    if path.starts_with("/sync/") {
        if crate::admin::has_session(&state, req.headers()).await {
            return Ok(next.run(req).await);
        }
        return Err(AppError::Unauthorized("sign in to the server console".into()));
    }
    if method == Method::GET && path == "/graphql" {
        if crate::admin::has_session(&state, req.headers()).await {
            return Ok(next.run(req).await);
        }
        return Ok(Redirect::to("/").into_response());
    }

    let ip = addr.ip();
    if ratelimit::is_blocked(Bucket::Auth, ip) {
        return Err(AppError::TooManyRequests("auth".into()));
    }
    // Keys only travel in the URL for media opened by external players.
    let provided = extract_token(req.headers())
        .or_else(|| {
            is_media_get(&method, &path)
                .then(|| extract_token_from_query(req.uri().query()))
                .flatten()
        })
        .map(str::to_owned);
    let Some(provided) = provided else {
        return Err(AppError::Unauthorized("missing API token".into()));
    };
    match resolve_token(&state, &provided).await {
        Ok(session) => {
            req.extensions_mut().insert(session);
            Ok(next.run(req).await)
        }
        Err(e) => {
            if matches!(e, AppError::Unauthorized(_)) {
                ratelimit::record_failure(Bucket::Auth, ip);
            }
            Err(e)
        }
    }
}

#[derive(Deserialize)]
pub struct PairRequest {
    code: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResponse {
    key: String,
    device_name: String,
}

/// POST /pair `{ "code": "482193" }` → `{ "key": "pbk_…", "deviceName": … }`.
/// The only place a 6-digit code is accepted from new apps.
pub async fn pair(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    Json(body): Json<PairRequest>,
) -> Result<Json<PairResponse>, AppError> {
    let ip = addr.ip();
    if ratelimit::is_blocked(Bucket::Credential, ip) {
        return Err(AppError::TooManyRequests("pair".into()));
    }
    match crate::db::exchange_pairing_code(&state.app.pool, &body.code).await? {
        Some((device, key)) => Ok(Json(PairResponse {
            key,
            device_name: device.name,
        })),
        None => {
            ratelimit::record_failure(Bucket::Credential, ip);
            Err(AppError::Unauthorized(
                "That pairing code is wrong or expired. Create a new one in the server console."
                    .into(),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_tokens() {
        assert!(token_matches("abc123", "abc123"));
        assert!(!token_matches("abc123", "abc124"));
        assert!(!token_matches("abc", "abcd"));
        assert!(!token_matches("", "secret"));
    }

    #[test]
    fn pairing_codes() {
        assert!(crate::pin::is_pairing_code("482193"));
        assert!(crate::pin::is_pairing_code("482 193"));
        assert_eq!(crate::pin::normalize_code("482 193"), "482193");
        assert_eq!(crate::pin::format_code("482193"), "482 193");
        assert!(crate::pin::codes_equal("482 193", "482193"));
        assert!(!crate::pin::is_pairing_code("not-a-pin"));
    }

    #[test]
    fn query_keys_only_for_media() {
        assert!(is_media_get(&Method::GET, "/files/abc"));
        assert!(is_media_get(&Method::HEAD, "/stream/abc"));
        assert!(!is_media_get(&Method::POST, "/graphql"));
        assert!(!is_media_get(&Method::GET, "/graphql"));
    }
}
