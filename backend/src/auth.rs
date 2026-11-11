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

/// Console pages' JSON feeds: signed in with the console cookie, not a device key.
fn is_console_feed(path: &str) -> bool {
    path.starts_with("/sync/") || path == "/updates/progress"
}

/// Console endpoints that act on the console cookie.
fn is_console_post(path: &str) -> bool {
    matches!(path, "/" | "/tokens" | "/sync/start" | "/sync/flush")
}

/// "http://h:3001/x" → ("http", "h:3001"), lowercased.
fn origin_parts(url: &str) -> Option<(String, String)> {
    let url = reqwest::Url::parse(url.trim()).ok()?;
    let host = url.host_str()?.to_ascii_lowercase();
    let authority = match url.port() {
        Some(p) => format!("{host}:{p}"),
        None => host,
    };
    Some((url.scheme().to_ascii_lowercase(), authority))
}

/// A browser request from the console's own page: its Origin (or Referer)
/// names the host it was sent to, or the configured public URL. Requests with
/// neither header aren't from a browser page and can't carry a forged cookie.
pub fn same_origin(headers: &HeaderMap, public_url: &str) -> bool {
    let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
    let Some(source) = header("origin").or_else(|| header("referer")) else {
        return true;
    };
    let Some((_, authority)) = origin_parts(source) else {
        // "null" (sandboxed frames, some redirects) or garbage.
        return false;
    };
    let hosts = [header("host"), header("x-forwarded-host")];
    if hosts
        .iter()
        .flatten()
        .filter_map(|h| h.split(',').next())
        .any(|h| h.trim().eq_ignore_ascii_case(&authority))
    {
        return true;
    }
    origin_parts(public_url).is_some_and(|p| origin_parts(source) == Some(p))
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
    // Console forms sign in with a cookie, so a page on another origin could
    // post them with the admin's session (SameSite=Lax doesn't separate ports
    // on the same host, e.g. Jackett on :9117). Refuse cross-origin posts.
    if method == Method::POST
        && is_console_post(&path)
        && !same_origin(req.headers(), &state.app.config.public_url)
    {
        return Err(AppError::Forbidden("cross-site console request refused".into()));
    }
    if path == "/" || path == "/tokens" {
        return Ok(next.run(req).await);
    }
    // Console Sync tab uses the admin session cookie (not a device token).
    if is_console_feed(&path) {
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
    if ratelimit::is_blocked(Bucket::Pairing, ip) {
        return Err(AppError::TooManyRequests("pair".into()));
    }
    match crate::db::exchange_pairing_code(&state.app.pool, &body.code).await? {
        Some((device, key)) => Ok(Json(PairResponse {
            key,
            device_name: device.name,
        })),
        None => {
            ratelimit::record_failure(Bucket::Pairing, ip);
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
    fn console_feeds_use_the_console_session() {
        assert!(is_console_feed("/sync/status"));
        assert!(is_console_feed("/updates/progress"));
        // Apps fetch these with their device key.
        assert!(!is_console_feed("/updates/latest"));
        assert!(!is_console_feed("/updates/files/v1/app.apk"));
    }

    fn hdrs(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(*k, v.parse().unwrap());
        }
        h
    }

    #[test]
    fn console_posts_must_come_from_the_console() {
        let public = "http://192.168.1.5:3001";
        // Same host the browser sent the form to.
        assert!(same_origin(&hdrs(&[("host", "192.168.1.5:3001"), ("origin", "http://192.168.1.5:3001")]), public));
        // Another app on the same machine (Jackett's port): refused.
        assert!(!same_origin(&hdrs(&[("host", "192.168.1.5:3001"), ("origin", "http://192.168.1.5:9117")]), public));
        assert!(!same_origin(&hdrs(&[("host", "192.168.1.5:3001"), ("origin", "https://evil.example")]), public));
        assert!(!same_origin(&hdrs(&[("host", "192.168.1.5:3001"), ("origin", "null")]), public));
        // Referer when there is no Origin.
        assert!(same_origin(&hdrs(&[("host", "pb.local:3001"), ("referer", "http://pb.local:3001/?tab=devices")]), public));
        // Behind a proxy that rewrites Host.
        assert!(same_origin(&hdrs(&[("host", "api:8080"), ("x-forwarded-host", "tv.example.com"), ("origin", "https://tv.example.com")]), public));
        // Public URL match.
        assert!(same_origin(&hdrs(&[("host", "api:8080"), ("origin", "http://192.168.1.5:3001")]), public));
        // No browser headers at all (curl, scripts).
        assert!(same_origin(&hdrs(&[("host", "x")]), public));
        assert!(is_console_post("/sync/flush"));
        assert!(!is_console_post("/graphql"));
        assert!(!is_console_post("/pair"));
    }

    #[test]
    fn query_keys_only_for_media() {
        assert!(is_media_get(&Method::GET, "/files/abc"));
        assert!(is_media_get(&Method::HEAD, "/stream/abc"));
        assert!(!is_media_get(&Method::POST, "/graphql"));
        assert!(!is_media_get(&Method::GET, "/graphql"));
    }
}
