use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap, Request};
use axum::middleware::Next;
use axum::response::{IntoResponse, Redirect, Response};
use std::net::{IpAddr, SocketAddr};
use uuid::Uuid;

use crate::error::AppError;
use crate::HttpState;

#[derive(Clone, Debug)]
pub struct AuthSession {
    pub token_id: Uuid,
    pub is_admin: bool,
    pub name: String,
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
/// can open `/stream/{id}` without custom HTTP headers.
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

pub fn authorize_headers(headers: &HeaderMap, expected: &str) -> Result<(), AppError> {
    let Some(provided) = extract_token(headers) else {
        return Err(AppError::Unauthorized("missing API token".into()));
    };
    if token_matches(provided, expected) {
        Ok(())
    } else {
        Err(AppError::Unauthorized("invalid API token".into()))
    }
}

#[allow(dead_code)]
pub fn is_loopback(addr: &SocketAddr) -> bool {
    addr.ip().is_loopback()
}

#[allow(dead_code)]
pub fn pairing_allowed(addr: &SocketAddr) -> bool {
    match addr.ip() {
        IpAddr::V4(ip) => ip.is_loopback() || ip.is_private(),
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unique_local()
                || ip.to_ipv4_mapped().is_some_and(|v4| v4.is_private())
        }
    }
}

pub async fn resolve_session(
    state: &HttpState,
    headers: &HeaderMap,
) -> Result<AuthSession, AppError> {
    let Some(provided) = extract_token(headers) else {
        return Err(AppError::Unauthorized("missing API token".into()));
    };
    let admin = state.app.config.app_token();
    if crate::pin::codes_equal(provided, &admin) {
        let (id, name) = crate::db::default_device_token(&state.app.pool).await?;
        return Ok(AuthSession {
            token_id: id,
            is_admin: true,
            name,
        });
    }
    let code = crate::pin::normalize_code(provided);
    if let Some((id, name)) = crate::db::find_device_token(&state.app.pool, &code).await? {
        return Ok(AuthSession {
            token_id: id,
            is_admin: false,
            name,
        });
    }
    Err(AppError::Unauthorized("invalid API token".into()))
}

pub async fn gate(
    ConnectInfo(_addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    req: Request<axum::body::Body>,
    next: Next,
) -> Result<Response, AppError> {
    let path = req.uri().path();
    let method = req.method();
    if method == axum::http::Method::OPTIONS || path == "/health" {
        return Ok(next.run(req).await);
    }
    // Public art proxy — TVs often lack DNS for image.tmdb.org / YouTube.
    if (path.starts_with("/art/")
        && (method == axum::http::Method::GET || method == axum::http::Method::HEAD))
    {
        return Ok(next.run(req).await);
    }
    // Opaque stream session IDs are the capability token — external Android
    // players (VLC/mpv) cannot set X-Api-Key headers. Optional ?key= still works.
    if path.starts_with("/stream/")
        && (method == axum::http::Method::GET || method == axum::http::Method::HEAD)
    {
        return Ok(next.run(req).await);
    }
    if path == "/" || path == "/tokens" {
        return Ok(next.run(req).await);
    }
    // Console Sync tab uses the admin session cookie (not a device pairing token).
    if path.starts_with("/sync/") {
        if crate::admin::has_session(&state, req.headers()).await {
            return Ok(next.run(req).await);
        }
        return Err(AppError::Unauthorized("sign in to the server console".into()));
    }
    if method == axum::http::Method::GET && path == "/graphql" {
        if crate::admin::has_session(&state, req.headers()).await {
            return Ok(next.run(req).await);
        }
        return Ok(Redirect::to("/").into_response());
    }
    let _ = resolve_session_with_query(&state, req.headers(), req.uri().query()).await?;
    Ok(next.run(req).await)
}

async fn resolve_session_with_query(
    state: &HttpState,
    headers: &HeaderMap,
    query: Option<&str>,
) -> Result<AuthSession, AppError> {
    if let Ok(session) = resolve_session(state, headers).await {
        return Ok(session);
    }
    // Fallback: query key for external players on /stream/*.
    let Some(provided) = extract_token_from_query(query) else {
        return Err(AppError::Unauthorized("missing API token".into()));
    };
    let admin = state.app.config.app_token();
    if crate::pin::codes_equal(provided, &admin) {
        let (id, name) = crate::db::default_device_token(&state.app.pool).await?;
        return Ok(AuthSession {
            token_id: id,
            is_admin: true,
            name,
        });
    }
    // Re-run resolve via a synthetic header so DB lookup stays in one place.
    let mut synthetic = HeaderMap::new();
    synthetic.insert(
        "x-api-key",
        provided
            .parse()
            .map_err(|_| AppError::Unauthorized("invalid API token".into()))?,
    );
    resolve_session(state, &synthetic).await
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
}
