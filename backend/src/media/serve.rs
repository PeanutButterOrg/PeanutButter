use std::io::SeekFrom;

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::error::AppError;
use crate::HttpState;

pub async fn serve_file(
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    State(state): State<HttpState>,
) -> Result<Response, AppError> {

    let row: Option<(String, Option<String>)> =
        sqlx::query_as("SELECT file_path, container FROM file_references WHERE id = $1")
            .bind(id)
            .fetch_optional(&state.app.pool)
            .await?;
    let Some((file_path, container)) = row else {
        return Err(AppError::NotFound("file reference not found".into()));
    };

    let path = std::path::Path::new(&file_path);
    if !path.exists() {
        return Err(AppError::NotFound("media file missing on disk".into()));
    }

    let file = File::open(path).await?;
    let meta = file.metadata().await?;
    let len = meta.len();
    let mime = mime_guess::from_path(path)
        .first_or_octet_stream()
        .to_string();
    let _ = container;

    if let Some(range) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
        if let Some((start, end)) = parse_range(range, len) {
            return range_response(file, start, end, len, &mime).await;
        }
        return Err(AppError::BadRequest("invalid range".into()));
    }

    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CONTENT_LENGTH, len)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "private, max-age=3600")
        .body(body)
        .map_err(|e| AppError::Internal(e.to_string()))?)
}

async fn range_response(
    mut file: File,
    start: u64,
    end: u64,
    total: u64,
    mime: &str,
) -> Result<Response, AppError> {
    file.seek(SeekFrom::Start(start)).await?;
    let length = end - start + 1;
    let limited = file.take(length);
    let stream = ReaderStream::new(limited);
    let body = Body::from_stream(stream);
    Ok(Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CONTENT_LENGTH, length)
        .header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        )
        .header(header::ACCEPT_RANGES, "bytes")
        .body(body)
        .map_err(|e| AppError::Internal(e.to_string()))?)
}

pub(crate) fn parse_range(header: &str, len: u64) -> Option<(u64, u64)> {
    let header = header.strip_prefix("bytes=")?;
    let first = header.split(',').next()?.trim();
    let (start_s, end_s) = first.split_once('-')?;
    if start_s.is_empty() {
        let suffix: u64 = end_s.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        let start = len.saturating_sub(suffix);
        return Some((start, len.saturating_sub(1)));
    }
    let start: u64 = start_s.parse().ok()?;
    if start >= len {
        return None;
    }
    let end = if end_s.is_empty() {
        len.saturating_sub(1)
    } else {
        end_s.parse::<u64>().ok()?.min(len.saturating_sub(1))
    };
    if end < start {
        return None;
    }
    Some((start, end))
}

#[cfg(test)]
mod tests {
    use super::parse_range;

    #[test]
    fn range_start_end() {
        assert_eq!(parse_range("bytes=0-1", 100), Some((0, 1)));
        assert_eq!(parse_range("bytes=10-", 100), Some((10, 99)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=100-101", 100), None);
    }
}
