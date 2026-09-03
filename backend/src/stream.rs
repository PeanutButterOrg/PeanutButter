use std::collections::{HashMap, HashSet};
use std::io::SeekFrom;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::{Path as AxumPath, State};
use axum::http::{header, HeaderMap, Method, StatusCode};
use axum::response::Response;
use librqbit::limits::LimitsConfig;
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent, PeerConnectionOptions,
    Session, SessionOptions, TorrentMetaV1Info,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::{Mutex, RwLock};
use bytes::Bytes;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::error::AppError;
use crate::graphql::types::StreamSession;
use crate::HttpState;

const VIDEO_EXT: &[&str] = &["mkv", "mp4", "avi", "webm", "mov", "m4v"];
const HEAD_BYTES: u64 = 6 * 1024 * 1024;   // pre-buffer 6 MB before declaring ready
const MIN_HEAD_BYTES: u64 = 2 * 1024 * 1024; // accept 2 MB if peers are slow
const MIN_PLAYABLE_BYTES: u64 = 80 * 1024 * 1024;
const STREAM_CHUNK: usize = 256 * 1024;        // 256 KB read chunks for smooth HTTP streaming
const UPLOAD_BPS: u32 = 20 * 1024; // cap upload at 20 KB/s
const EXTRA_TRACKERS: &[&str] = &[
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.coppersurfer.tk:6969/announce",
    "udp://tracker.leechers-paradise.org:6969/announce",
];

#[derive(Clone)]
pub struct StreamService {
    inner: Arc<StreamInner>,
}

struct StreamInner {
    session: tokio::sync::OnceCell<Arc<Session>>,
    sessions: RwLock<HashMap<String, Arc<Mutex<LiveStream>>>>,
    output_root: PathBuf,
    public_url: String,
}

struct LiveStream {
    id: String,
    #[allow(dead_code)]
    magnet: String,
    title: String,
    seeders: i32,
    peers: i32,
    resume_position: i64,
    status: String,
    error: Option<String>,
    handle: Option<Arc<ManagedTorrent>>,
    file_id: Option<usize>,
    file_name: Option<String>,
    season: Option<i32>,
    episode: Option<i32>,
}

fn stream_output_root(media_path: PathBuf) -> PathBuf {
    std::env::var("STREAM_PATH")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| media_path.join(".peanutbutter-streams"))
}

fn torrent_listen_range() -> std::ops::Range<u16> {
    match std::env::var("TORRENT_LISTEN_PORT") {
        Ok(raw) if !raw.trim().is_empty() => {
            let start = raw.trim().parse::<u16>().unwrap_or(6881);
            let end = start.saturating_add(1);
            if end > start {
                start..end
            } else {
                6881..6882
            }
        }
        _ => 6881..6981,
    }
}

impl StreamService {
    pub fn new(media_path: PathBuf, public_url: String) -> Self {
        Self {
            inner: Arc::new(StreamInner {
                session: tokio::sync::OnceCell::new(),
                sessions: RwLock::new(HashMap::new()),
                output_root: stream_output_root(media_path),
                public_url,
            }),
        }
    }

    pub async fn start(
        &self,
        magnet: String,
        title: String,
        resume_position: i64,
        preferred_resolution: String,
        seeders: i32,
        peers: i32,
        season: Option<i32>,
        episode: Option<i32>,
    ) -> Result<StreamSession, AppError> {
        let magnet = magnet.trim().to_string();
        if magnet.is_empty() {
            return Err(AppError::BadRequest(
                "That torrent link is missing. Try another result.".into(),
            ));
        }
        let id = Uuid::new_v4().to_string();
        let live = Arc::new(Mutex::new(LiveStream {
            id: id.clone(),
            magnet: magnet.clone(),
            title: title.clone(),
            seeders,
            peers,
            resume_position,
            status: "starting".into(),
            error: None,
            handle: None,
            file_id: None,
            file_name: None,
            season,
            episode,
        }));
        self.inner.sessions.write().await.insert(id.clone(), live.clone());
        let boot = live.clone();
        let inner = self.inner.clone();
        tokio::spawn(async move {
            if let Err(e) = bootstrap_torrent(inner, boot.clone(), magnet, preferred_resolution).await {
                let mut g = boot.lock().await;
                g.status = "error".into();
                g.error = Some(friendly_stream_error(&e));
            }
        });
        let g = live.lock().await;
        Ok(self.to_graphql(&id, &g).await)
    }

    pub async fn status(&self, session_id: &str) -> Option<StreamSession> {
        let map = self.inner.sessions.read().await;
        let live = map.get(session_id)?;
        let g = live.lock().await;
        Some(self.to_graphql(session_id, &g).await)
    }

    pub async fn set_resume(&self, session_id: &str, position: i64) -> bool {
        let map = self.inner.sessions.read().await;
        let Some(live) = map.get(session_id) else {
            return false;
        };
        live.lock().await.resume_position = position.max(0);
        true
    }

    pub async fn stop(&self, session_id: &str) -> bool {
        let removed = {
            let mut map = self.inner.sessions.write().await;
            map.remove(session_id)
        };
        if let Some(live_arc) = removed {
            let (handle, folder) = {
                let live = live_arc.lock().await;
                let folder = self.inner.output_root.join(&live.id);
                (live.handle.clone(), folder)
            };
            // Drop the torrent handle first so librqbit releases file locks.
            drop(handle);
            // Then wipe the per-session folder that holds downloaded pieces.
            if folder.exists() {
                let _ = tokio::fs::remove_dir_all(&folder).await;
            }
            true
        } else {
            false
        }
    }

    /// Wipe all leftover stream folders on startup / app restart.
    pub async fn cleanup_stale(&self) {
        let root = &self.inner.output_root;
        let Ok(mut rd) = tokio::fs::read_dir(root).await else { return };
        while let Ok(Some(entry)) = rd.next_entry().await {
            let p = entry.path();
            if p.is_dir() {
                let _ = tokio::fs::remove_dir_all(&p).await;
            }
        }
    }

    pub fn magnet_key(magnet: &str) -> String {
        hex::encode(Sha256::digest(magnet.trim().as_bytes()))
    }

    async fn to_graphql(&self, id: &str, live: &LiveStream) -> StreamSession {
        let (progress, seeders, peers, download_mbps, buffer_progress) = if let Some(handle) = &live.handle {
            let stats = handle.stats();
            let progress = if stats.total_bytes == 0 {
                0.0
            } else {
                (stats.progress_bytes as f64 / stats.total_bytes as f64) as f32
            };
            let live_peers = stats
                .live
                .as_ref()
                .map(|s| s.snapshot.peer_stats.live as i32)
                .unwrap_or(0);
            let download_mbps = stats
                .live
                .as_ref()
                .map(|s| s.download_speed.mbps)
                .unwrap_or(0.0);
            let buffer_progress = if let Some(file_id) = live.file_id {
                let got = stats.file_progress.get(file_id).copied().unwrap_or(0);
                let total = handle
                    .with_metadata(|m| m.file_infos.get(file_id).map(|f| f.len).unwrap_or(0))
                    .unwrap_or(0);
                if total == 0 {
                    0.0
                } else {
                    (got as f64 / total as f64) as f32
                }
            } else {
                progress
            };
            (
                progress,
                live.seeders.max(live_peers),
                live.peers.max(live_peers),
                download_mbps,
                buffer_progress,
            )
        } else {
            (0.0, live.seeders, live.peers, 0.0, 0.0)
        };
        let stream_url = if live.status == "ready" {
            format!(
                "{}/stream/{}",
                self.inner.public_url.trim_end_matches('/'),
                id
            )
        } else {
            String::new()
        };
        StreamSession {
            id: id.to_string(),
            title: live.title.clone(),
            progress,
            buffer_progress,
            download_mbps,
            seeders,
            peers,
            resume_position: live.resume_position as i32,
            status: live
                .error
                .as_ref()
                .map(|e| format!("error: {e}"))
                .unwrap_or_else(|| live.status.clone()),
            stream_url,
        }
    }

    async fn live(&self, session_id: &str) -> Option<Arc<Mutex<LiveStream>>> {
        self.inner.sessions.read().await.get(session_id).cloned()
    }
}

async fn bootstrap_torrent(
    inner: Arc<StreamInner>,
    live: Arc<Mutex<LiveStream>>,
    magnet: String,
    preferred_resolution: String,
) -> Result<(), String> {
    let session = inner
        .session
        .get_or_try_init(|| async {
            tokio::fs::create_dir_all(&inner.output_root)
                .await
                .map_err(|_| {
                    "Couldn’t prepare the stream folder on the server. Try again.".to_string()
                })?;
            Session::new_with_opts(
                inner.output_root.clone(),
                SessionOptions {
                    disable_dht: false,
                    disable_dht_persistence: false,
                    enable_upnp_port_forwarding: true,
                    listen_port_range: Some(torrent_listen_range()),
                    // Keep 512 pieces (≈ 256 MB for 512KB pieces) in memory before flushing.
                    // This prevents constant disk flushes that stall sequential reads.
                    defer_writes_up_to: Some(512),
                    concurrent_init_limit: Some(16),
                    peer_opts: Some(PeerConnectionOptions {
                        connect_timeout: Some(Duration::from_secs(4)),
                        read_write_timeout: Some(Duration::from_secs(12)),
                        keep_alive_interval: Some(Duration::from_secs(10)),
                    }),
                    ratelimits: torrent_limits(),
                    ..Default::default()
                },
            )
            .await
            .map_err(|_| "Couldn’t start the stream engine. Try again.".to_string())
        })
        .await
        .map_err(|e| e.to_string())?
        .clone();

    let folder = inner.output_root.join(&live.lock().await.id);
    tokio::fs::create_dir_all(&folder)
        .await
        .map_err(|_| "Couldn’t prepare the stream folder on the server. Try again.".to_string())?;

    let (preferred_resolution, season, episode) = {
        let g = live.lock().await;
        (preferred_resolution, g.season, g.episode)
    };

    let listed = session
        .add_torrent(
            AddTorrent::from_url(&magnet),
            Some(AddTorrentOptions {
                list_only: true,
                overwrite: true,
                output_folder: Some(folder.to_string_lossy().into_owned()),
                force_tracker_interval: Some(Duration::from_secs(8)),
                defer_writes: Some(true),
                peer_opts: Some(PeerConnectionOptions {
                    connect_timeout: Some(Duration::from_secs(4)),
                    read_write_timeout: Some(Duration::from_secs(12)),
                    keep_alive_interval: Some(Duration::from_secs(10)),
                }),
                trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
                ratelimits: torrent_limits(),
                ..Default::default()
            }),
        )
        .await
        .map_err(|e| friendly_stream_error(&e.to_string()))?;

    let listed_videos = match &listed {
        AddTorrentResponse::ListOnly(resp) => videos_from_info(&resp.info),
        AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => {
            videos_from_handle(handle)
        }
    };
    let file_id = pick_playable_video(&listed_videos, &preferred_resolution, season, episode)
        .ok_or_else(|| "This torrent doesn’t contain a playable video file. Try another result.".to_string())?;

    let handle = match listed {
        AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => handle,
        AddTorrentResponse::ListOnly(_) => {
            let added = session
                .add_torrent(
                    AddTorrent::from_url(&magnet),
                    Some(AddTorrentOptions {
                        overwrite: true,
                        only_files: Some(vec![file_id]),
                        output_folder: Some(folder.to_string_lossy().into_owned()),
                        force_tracker_interval: Some(Duration::from_secs(8)),
                        defer_writes: Some(true),
                        peer_opts: Some(PeerConnectionOptions {
                            connect_timeout: Some(Duration::from_secs(4)),
                            read_write_timeout: Some(Duration::from_secs(12)),
                            keep_alive_interval: Some(Duration::from_secs(10)),
                        }),
                        trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
                        ratelimits: torrent_limits(),
                        ..Default::default()
                    }),
                )
                .await
                .map_err(|e| friendly_stream_error(&e.to_string()))?;
            match added {
                AddTorrentResponse::Added(_, h) | AddTorrentResponse::AlreadyManaged(_, h) => h,
                AddTorrentResponse::ListOnly(_) => {
                    return Err("This torrent failed to start. Try another result.".into())
                }
            }
        }
    };

    let _ = session
        .update_only_files(&handle, &HashSet::from([file_id]))
        .await;
    tokio::time::timeout(Duration::from_secs(90), handle.wait_until_initialized())
        .await
        .map_err(|_| "Couldn’t find enough peers to start this stream. Try another result.".to_string())?
        .map_err(|e| friendly_stream_error(&e.to_string()))?;
    let _ = session
        .update_only_files(&handle, &HashSet::from([file_id]))
        .await;
    let resume_ms = live.lock().await.resume_position;
    wait_for_stream_head(&handle, file_id, resume_ms).await;
    let file_name = handle
        .with_metadata(|m| {
            m.file_infos
                .get(file_id)
                .map(|f| f.relative_filename.to_string_lossy().into_owned())
        })
        .ok()
        .flatten();

    let mut g = live.lock().await;
    g.handle = Some(handle);
    g.file_id = Some(file_id);
    g.file_name = file_name;
    g.status = "ready".into();
    Ok(())
}

async fn wait_for_stream_head(handle: &Arc<ManagedTorrent>, file_id: usize, resume_ms: i64) {
    let Ok(mut prefetch) = handle.clone().stream(file_id) else {
        return;
    };
    let len = prefetch.len();
    // Prefer pieces around the resume timestamp so any magnet can start mid-title.
    // ~2.5 MB/s is a conservative 1080p estimate.
    let est = ((resume_ms.max(0) as u64).saturating_mul(2_500_000) / 1000).min(len.saturating_sub(1));
    let start = est.saturating_sub(HEAD_BYTES / 4);
    let _ = prefetch.seek(SeekFrom::Start(start)).await;
    let target = HEAD_BYTES.min(len.saturating_sub(start)).max(1);
    let min_ready = MIN_HEAD_BYTES.min(target);
    let mut got = 0u64;
    let mut buf = vec![0u8; 128 * 1024];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while got < target && tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(2), prefetch.read(&mut buf)).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => got += n as u64,
            Ok(Err(_)) => tokio::time::sleep(Duration::from_millis(200)).await,
            Err(_) => {
                if got >= min_ready {
                    break;
                }
            }
        }
    }
    let _ = prefetch.seek(SeekFrom::Start(start)).await;
    tokio::spawn(async move {
        let _keep = prefetch;
        std::future::pending::<()>().await
    });
}

fn friendly_stream_error(raw: &str) -> String {
    let t = raw.to_ascii_lowercase();
    if t.contains("timeout") || t.contains("timed out") || t.contains("peers") {
        return "Couldn’t find enough peers to start this stream. Try another result.".into();
    }
    if t.contains("no video") || t.contains("playable video") {
        return "This torrent doesn’t contain a playable video file. Try another result.".into();
    }
    if t.contains("magnet") && (t.contains("invalid") || t.contains("missing") || t.contains("parse")) {
        return "That torrent link isn’t valid. Try another result.".into();
    }
    if t.contains("failed to start") || t.contains("listed without") {
        return "This torrent failed to start. Try another result.".into();
    }
    if t.contains("connection refused") || t.contains("unreachable") {
        return "Couldn’t reach peers for this torrent. Try another result.".into();
    }
    "Couldn’t start this stream. Try another result.".into()
}

fn torrent_limits() -> LimitsConfig {
    LimitsConfig {
        upload_bps: NonZeroU32::new(UPLOAD_BPS),
        download_bps: None,
    }
}

fn videos_from_info<B: AsRef<[u8]>>(info: &TorrentMetaV1Info<B>) -> Vec<(usize, u64, String)> {
    let Ok(iter) = info.iter_file_details() else {
        return Vec::new();
    };
    iter.enumerate()
        .filter_map(|(i, details)| {
            let name = details.filename.to_string().ok()?;
            Some((i, details.len, name))
        })
        .collect()
}

fn videos_from_handle(handle: &Arc<ManagedTorrent>) -> Vec<(usize, u64, String)> {
    handle
        .with_metadata(|meta| {
            meta.file_infos
                .iter()
                .enumerate()
                .map(|(i, fi)| {
                    (
                        i,
                        fi.len,
                        fi.relative_filename.to_string_lossy().into_owned(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

fn file_ext(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn padded_name(name: &str) -> String {
    let mut out = String::from(" ");
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(' ');
        }
    }
    out.push(' ');
    out
}

fn is_junk_video(name: &str, len: u64) -> bool {
    let h = padded_name(name);
    const JUNK: &[&str] = &[
        "sample",
        "trailer",
        "extra",
        "extras",
        "featurette",
        "featurettes",
        "behindthescenes",
        "interview",
        "deleted",
        "gagreel",
        "promo",
        "proof",
        "screens",
        "bonus",
        "samplefix",
        "rarbgsample",
    ];
    if JUNK.iter().any(|t| h.contains(&format!(" {t} "))) {
        return true;
    }
    let lower = name.to_ascii_lowercase();
    if lower.contains("/sample/")
        || lower.contains("/samples/")
        || lower.contains("/extras/")
        || lower.contains("/extra/")
        || lower.contains("/featurettes/")
        || lower.contains("/featurette/")
        || lower.contains("/bonus/")
        || lower.contains("/proof/")
        || lower.contains("/screens/")
        || lower.contains("\\sample\\")
        || lower.contains("\\samples\\")
        || lower.contains("\\extras\\")
        || lower.contains("\\featurettes\\")
    {
        return true;
    }
    len > 0 && len < MIN_PLAYABLE_BYTES
}

fn episode_token(season: i32, episode: i32) -> String {
    format!("s{season:02}e{episode:02}")
}

fn matches_episode(name: &str, season: i32, episode: i32) -> bool {
    let h = padded_name(name).replace(' ', "");
    h.contains(&episode_token(season, episode))
        || h.contains(&format!("s{season}e{episode:02}"))
        || h.contains(&format!("s{season:02}e{episode}"))
        || h.contains(&format!("{season}x{episode:02}"))
        || h.contains(&format!("{season}x{episode}"))
}

fn resolution_score(name: &str, preferred: &str) -> i32 {
    let t = name.to_ascii_lowercase();
    if !preferred.is_empty() && t.contains(preferred) {
        return 3;
    }
    if t.contains("2160p") || t.contains("4k") {
        return 2;
    }
    if t.contains("1080p") {
        return 1;
    }
    0
}

fn pick_playable_video(
    files: &[(usize, u64, String)],
    preferred_resolution: &str,
    season: Option<i32>,
    episode: Option<i32>,
) -> Option<usize> {
    let preferred = preferred_resolution.trim().to_ascii_lowercase();
    let mut videos: Vec<&(usize, u64, String)> = files
        .iter()
        .filter(|(_, _, name)| VIDEO_EXT.contains(&file_ext(name).as_str()))
        .collect();
    if videos.is_empty() {
        return None;
    }
    let playable: Vec<&(usize, u64, String)> = videos
        .iter()
        .copied()
        .filter(|(_, len, name)| !is_junk_video(name, *len))
        .collect();
    if !playable.is_empty() {
        videos = playable;
    } else {
        videos.retain(|(_, _, name)| {
            let h = padded_name(name);
            !h.contains(" sample ") && !h.contains(" trailer ")
        });
        if videos.is_empty() {
            videos = files
                .iter()
                .filter(|(_, _, name)| VIDEO_EXT.contains(&file_ext(name).as_str()))
                .collect();
        }
    }
    if let (Some(season), Some(episode)) = (season, episode) {
        let hits: Vec<&(usize, u64, String)> = videos
            .iter()
            .copied()
            .filter(|(_, _, name)| matches_episode(name, season, episode))
            .collect();
        // Never play a random file from a pack when we asked for a specific episode.
        if hits.is_empty() {
            return None;
        }
        videos = hits;
    }
    videos.sort_by(|a, b| {
        resolution_score(&b.2, &preferred)
            .cmp(&resolution_score(&a.2, &preferred))
            .then(b.1.cmp(&a.1))
    });
    videos.first().map(|v| v.0)
}

/// Stream reader using large chunks so the HTTP layer never blocks on tiny reads.
fn chunked_stream<R>(reader: R) -> impl futures::Stream<Item = std::io::Result<Bytes>>
where
    R: tokio::io::AsyncRead + Send + 'static,
{
    ReaderStream::with_capacity(reader, STREAM_CHUNK)
}

pub async fn serve_stream(
    AxumPath(id): AxumPath<String>,
    headers: HeaderMap,
    method: Method,
    State(state): State<HttpState>,
) -> Result<Response, AppError> {
    let Some(live) = state.app.streams.live(&id).await else {
        return Err(AppError::NotFound("stream session not found".into()));
    };
    let g = live.lock().await;
    if g.status != "ready" {
        return Err(AppError::BadRequest(
            "This stream isn’t ready yet. Wait a moment and try again.".into(),
        ));
    }
    let handle = g
        .handle
        .clone()
        .ok_or_else(|| AppError::Internal("stream handle missing".into()))?;
    let file_id = g
        .file_id
        .ok_or_else(|| AppError::Internal("stream file missing".into()))?;
    let file_name = g.file_name.clone().unwrap_or_else(|| "video.mkv".into());
    drop(g);

    let mut stream = handle
        .stream(file_id)
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let len = stream.len();
    let mime = mime_guess::from_path(&file_name)
        .first_or_octet_stream()
        .to_string();

    if method == Method::HEAD {
        return Ok(Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, mime)
            .header(header::CONTENT_LENGTH, len)
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::empty())
            .map_err(|e| AppError::Internal(e.to_string()))?);
    }

    if let Some(range) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
        if let Some((start, end)) = crate::media::serve::parse_range(range, len) {
            stream
                .seek(SeekFrom::Start(start))
                .await
                .map_err(AppError::Io)?;
            let length = end - start + 1;
            let body = Body::from_stream(chunked_stream(stream.take(length)));
            return Ok(Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(header::CONTENT_TYPE, mime)
                .header(header::CONTENT_LENGTH, length)
                .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{len}"))
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CACHE_CONTROL, "no-store")
                .body(body)
                .map_err(|e| AppError::Internal(e.to_string()))?);
        }
        return Err(AppError::BadRequest("invalid range".into()));
    }

    let body = Body::from_stream(chunked_stream(stream));
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, mime)
        .header(header::CONTENT_LENGTH, len)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "no-store")
        .body(body)
        .map_err(|e| AppError::Internal(e.to_string()))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_samples_and_picks_the_feature() {
        let files = [
            (0, 12 * 1024 * 1024, "Movie.1080p.Sample.mkv".into()),
            (1, 8 * 1024 * 1024, "Trailers/official.mp4".into()),
            (2, 9_000 * 1024 * 1024, "Movie.2024.1080p.BluRay.mkv".into()),
            (3, 400 * 1024 * 1024, "Extras/featurette.mkv".into()),
        ];
        assert_eq!(pick_playable_video(&files, "1080p", None, None), Some(2));
    }

    #[test]
    fn picks_episode_from_a_season_pack() {
        let files = [
            (0, 2_000 * 1024 * 1024, "Show.S01E01.1080p.mkv".into()),
            (1, 2_100 * 1024 * 1024, "Show.S01E02.1080p.mkv".into()),
            (2, 20 * 1024 * 1024, "Show.S01E02.sample.mkv".into()),
        ];
        assert_eq!(pick_playable_video(&files, "1080p", Some(1), Some(2)), Some(1));
    }

    #[test]
    fn refuses_missing_episode_instead_of_wrong_file() {
        let files = [
            (0, 2_000 * 1024 * 1024, "Show.S01E01.1080p.mkv".into()),
            (1, 2_100 * 1024 * 1024, "Show.S01E03.1080p.mkv".into()),
        ];
        assert_eq!(pick_playable_video(&files, "1080p", Some(1), Some(2)), None);
    }

    #[test]
    fn prefers_requested_resolution() {
        let files = [
            (0, 12_000 * 1024 * 1024, "Movie.2160p.mkv".into()),
            (1, 8_000 * 1024 * 1024, "Movie.1080p.mkv".into()),
        ];
        assert_eq!(pick_playable_video(&files, "1080p", None, None), Some(1));
    }

    #[test]
    fn skips_sample_folder_and_screens() {
        let files = [
            (0, 90 * 1024 * 1024, "Sample/movie.sample.mkv".into()),
            (1, 200 * 1024 * 1024, "Proof/screens.mkv".into()),
            (2, 7_000 * 1024 * 1024, "Movie.2024.1080p.mkv".into()),
        ];
        assert_eq!(pick_playable_video(&files, "1080p", None, None), Some(2));
    }
}
