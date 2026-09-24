//! Proxy TMDB / YouTube thumbnails through this host so LAN clients (Android TVs
//! without working DNS) never need to resolve image.tmdb.org / img.youtube.com.

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use tracing::warn;

use crate::error::AppError;
use crate::HttpState;

fn valid_tmdb_size(size: &str) -> bool {
    matches!(
        size,
        "w92" | "w154" | "w185" | "w342" | "w500" | "w780" | "w1280" | "original" | "h632"
    )
}

fn safe_image_path(path: &str) -> Option<&str> {
    let trimmed = path.trim().trim_start_matches('/');
    if trimmed.is_empty() || trimmed.contains("..") || trimmed.contains('\\') {
        return None;
    }
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '/' || c == '.' || c == '_' || c == '-')
    {
        return None;
    }
    Some(trimmed)
}

fn safe_youtube_key(key: &str) -> Option<&str> {
    let trimmed = key.trim();
    if trimmed.is_empty() || trimmed.len() > 32 {
        return None;
    }
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some(trimmed)
}

async fn proxy_bytes(state: &HttpState, upstream: &str) -> Result<Response, AppError> {
    let response = state
        .app
        .http
        .get(upstream)
        .header(header::ACCEPT, "image/*,*/*;q=0.8")
        .send()
        .await
        .map_err(|e| {
            warn!(error = %e, upstream, "art proxy upstream failed");
            AppError::Provider(format!("art fetch failed: {e}"))
        })?;

    let status = response.status();
    if !status.is_success() {
        return Ok((
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            format!("upstream returned {status}"),
        )
            .into_response());
    }

    let content_type = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    let bytes = response.bytes().await.map_err(|e| {
        warn!(error = %e, upstream, "art proxy body failed");
        AppError::Provider(format!("art body failed: {e}"))
    })?;

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&content_type).unwrap_or_else(|_| HeaderValue::from_static("image/jpeg")),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=604800"),
    );

    let mut res = Response::new(Body::from(bytes));
    *res.status_mut() = StatusCode::OK;
    *res.headers_mut() = headers;
    Ok(res)
}

/// GET /art/tmdb/{size}/{*path} → https://image.tmdb.org/t/p/{size}/{path}
pub async fn proxy_tmdb(
    Path((size, path)): Path<(String, String)>,
    State(state): State<HttpState>,
) -> Result<Response, AppError> {
    if !valid_tmdb_size(&size) {
        return Err(AppError::BadRequest("invalid TMDB image size".into()));
    }
    let Some(safe) = safe_image_path(&path) else {
        return Err(AppError::BadRequest("invalid TMDB image path".into()));
    };
    let upstream = format!("https://image.tmdb.org/t/p/{size}/{safe}");
    proxy_bytes(&state, &upstream).await
}

/// GET /art/youtube/{key} → https://img.youtube.com/vi/{key}/hqdefault.jpg
pub async fn proxy_youtube(
    Path(key): Path<String>,
    State(state): State<HttpState>,
) -> Result<Response, AppError> {
    let Some(safe) = safe_youtube_key(&key) else {
        return Err(AppError::BadRequest("invalid YouTube id".into()));
    };
    let upstream = format!("https://img.youtube.com/vi/{safe}/hqdefault.jpg");
    proxy_bytes(&state, &upstream).await
}
