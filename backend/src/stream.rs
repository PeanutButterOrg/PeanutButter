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
const HEAD_BYTES: u64 = 2 * 1024 * 1024; // soft pre-buffer target once peers connect
const MIN_HEAD_BYTES: u64 = 256 * 1024; // declare ready after ~256 KB so playback can start sooner
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

#[derive(Debug, Clone)]
pub struct TorrentFileEntry {
    pub index: usize,
    pub name: String,
    pub size_bytes: u64,
}

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
    #[allow(dead_code)]
    seeders: i32,
    #[allow(dead_code)]
    peers: i32,
    resume_position: i64,
    status: String,
    error: Option<String>,
    handle: Option<Arc<ManagedTorrent>>,
    file_id: Option<usize>,
    /// When set, bootstrap uses this file instead of auto-picking.
    preferred_file_id: Option<usize>,
    file_name: Option<String>,
    season: Option<i32>,
    episode: Option<i32>,
    /// Retargets the sequential piece window when the player seeks.
    /// Dropping this sender stops the prefetch worker.
    prefetch_seek: Option<tokio::sync::mpsc::UnboundedSender<u64>>,
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
        preferred_file_id: Option<usize>,
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
            preferred_file_id,
            file_name: None,
            season,
            episode,
            prefetch_seek: None,
        }));
        self.inner.sessions.write().await.insert(id.clone(), live.clone());
        let boot = live.clone();
        let inner = self.inner.clone();
        tokio::spawn(async move {
            if let Err(e) = bootstrap_torrent(inner, boot.clone(), magnet, preferred_resolution).await {
                let mut g = boot.lock().await;
                g.status = "error".into();
                // bootstrap already returns user-facing messages.
                g.error = Some(e);
            }
        });
        let g = live.lock().await;
        Ok(self.to_graphql(&id, &g).await)
    }

    /// List playable video files inside a magnet (list-only — nothing is downloaded).
    pub async fn list_files(&self, magnet: &str) -> Result<Vec<TorrentFileEntry>, AppError> {
        let magnet = magnet.trim();
        if magnet.is_empty() {
            return Err(AppError::BadRequest(
                "That torrent link is missing. Try another result.".into(),
            ));
        }
        let session = self
            .inner
            .session
            .get_or_try_init(|| async {
                tokio::fs::create_dir_all(&self.inner.output_root)
                    .await
                    .map_err(|_| {
                        "Couldn’t prepare the stream folder on the server. Try again.".to_string()
                    })?;
                Session::new_with_opts(
                    self.inner.output_root.clone(),
                    SessionOptions {
                        disable_dht: false,
                        disable_dht_persistence: false,
                        enable_upnp_port_forwarding: true,
                        listen_port_range: Some(torrent_listen_range()),
                        defer_writes_up_to: Some(512),
                        concurrent_init_limit: Some(16),
                        peer_opts: Some(PeerConnectionOptions {
                            connect_timeout: Some(Duration::from_secs(2)),
                            read_write_timeout: Some(Duration::from_secs(8)),
                            keep_alive_interval: Some(Duration::from_secs(8)),
                        }),
                        ratelimits: torrent_limits(),
                        ..Default::default()
                    },
                )
                .await
                .map_err(|_| "Couldn’t start the stream engine. Try again.".to_string())
            })
            .await
            .map_err(|e| AppError::Message(e.to_string()))?
            .clone();

        let tmp = self.inner.output_root.join(format!("list-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&tmp)
            .await
            .map_err(AppError::Io)?;
        let add = resolve_torrent_source(magnet).await.map_err(AppError::Message)?;
        let mut listed = session
            .add_torrent(
                add.to_add(),
                Some(AddTorrentOptions {
                    list_only: true,
                    overwrite: true,
                    output_folder: Some(tmp.to_string_lossy().into_owned()),
                    force_tracker_interval: Some(Duration::from_secs(3)),
                    trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
                    ratelimits: torrent_limits(),
                    ..Default::default()
                }),
            )
            .await;
        if let Err(e) = &listed {
            tracing::warn!(error = %e, "torrent list_files failed");
        }
        // One retry helps when DHT/metadata is slow on the first attempt.
        if listed.is_err() {
            tokio::time::sleep(Duration::from_millis(400)).await;
            listed = session
                .add_torrent(
                    add.to_add(),
                    Some(AddTorrentOptions {
                        list_only: true,
                        overwrite: true,
                        output_folder: Some(tmp.to_string_lossy().into_owned()),
                        force_tracker_interval: Some(Duration::from_secs(3)),
                        trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
                        ratelimits: torrent_limits(),
                        ..Default::default()
                    }),
                )
                .await;
            if let Err(e) = &listed {
                tracing::warn!(error = %e, "torrent list_files retry failed");
            }
        }
        let listed = listed.map_err(|e| {
            AppError::Message(friendly_list_files_error(&e.to_string()))
        })?;
        let _ = tokio::fs::remove_dir_all(&tmp).await;

        let videos = match &listed {
            AddTorrentResponse::ListOnly(resp) => videos_from_info(&resp.info),
            AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => {
                videos_from_handle(handle)
            }
        };
        Ok(videos
            .into_iter()
            .filter(|(_, size, name)| {
                VIDEO_EXT.contains(&file_ext(name).as_str()) && !is_junk_video(name, *size)
            })
            .map(|(index, size, name)| TorrentFileEntry {
                index,
                name,
                size_bytes: size,
            })
            .collect())
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
        // Persist only — do NOT retarget piece priority here.
        // Progress saves fire every few seconds; retargeting from a bitrate guess
        // steals bandwidth from the live HTTP reader and freezes playback.
        // Seeks retarget via HTTP Range in serve_stream.
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
                let mut live = live_arc.lock().await;
                // Stop prefetch worker so its FileStream drops before the torrent handle.
                live.prefetch_seek = None;
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
            // Live swarm only — never Jackett listed counts (those looked "connected"
            // while the player was still waiting on the first bytes).
            (
                progress,
                live_peers,
                live_peers,
                download_mbps,
                buffer_progress,
            )
        } else {
            // Still bootstrapping metadata — show finding peers, not Jackett numbers.
            (0.0, 0, 0, 0.0, 0.0)
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
                        connect_timeout: Some(Duration::from_secs(2)),
                        read_write_timeout: Some(Duration::from_secs(8)),
                        keep_alive_interval: Some(Duration::from_secs(8)),
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

    let (preferred_resolution, season, episode, preferred_file_id) = {
        let g = live.lock().await;
        (
            preferred_resolution,
            g.season,
            g.episode,
            g.preferred_file_id,
        )
    };

    let resolved = resolve_torrent_source(&magnet).await?;

    // 1) Metadata-only pass so we can pick the right file (and set only_files).
    let listed = session
        .add_torrent(
            resolved.to_add(),
            Some(AddTorrentOptions {
                list_only: true,
                overwrite: true,
                output_folder: Some(folder.to_string_lossy().into_owned()),
                force_tracker_interval: Some(Duration::from_secs(3)),
                defer_writes: Some(true),
                peer_opts: Some(PeerConnectionOptions {
                    connect_timeout: Some(Duration::from_secs(2)),
                    read_write_timeout: Some(Duration::from_secs(8)),
                    keep_alive_interval: Some(Duration::from_secs(8)),
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
    let file_id = if let Some(idx) = preferred_file_id {
        if listed_videos.iter().any(|(i, _, _)| *i == idx) {
            idx
        } else {
            return Err(
                "That file isn’t in this torrent anymore. Pick another file.".into(),
            );
        }
    } else {
        pick_playable_video(&listed_videos, &preferred_resolution, season, episode).ok_or_else(
            || "This torrent doesn’t contain a playable video file. Try another result.".to_string(),
        )?
    };

    // 2) Real download — only the chosen file (critical for peer piece interest).
    let handle = match listed {
        AddTorrentResponse::Added(_, handle) | AddTorrentResponse::AlreadyManaged(_, handle) => {
            let _ = session
                .update_only_files(&handle, &HashSet::from([file_id]))
                .await;
            handle
        }
        AddTorrentResponse::ListOnly(_) => {
            let added = session
                .add_torrent(
                    resolved.to_add(),
                    Some(AddTorrentOptions {
                        overwrite: true,
                        only_files: Some(vec![file_id]),
                        output_folder: Some(folder.to_string_lossy().into_owned()),
                        force_tracker_interval: Some(Duration::from_secs(3)),
                        defer_writes: Some(true),
                        peer_opts: Some(PeerConnectionOptions {
                            connect_timeout: Some(Duration::from_secs(2)),
                            read_write_timeout: Some(Duration::from_secs(8)),
                            keep_alive_interval: Some(Duration::from_secs(8)),
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

    tokio::time::timeout(Duration::from_secs(45), handle.wait_until_initialized())
        .await
        .map_err(|_| "Couldn’t find enough peers to start this stream. Try another result.".to_string())?
        .map_err(|e| friendly_stream_error(&e.to_string()))?;
    let _ = session
        .update_only_files(&handle, &HashSet::from([file_id]))
        .await;

    // Expose the handle early so the UI can show live peer counts while we
    // warm the file header — but keep status != ready until bytes arrive.
    let resume_ms = {
        let mut g = live.lock().await;
        g.handle = Some(handle.clone());
        g.file_id = Some(file_id);
        g.status = "buffering".into();
        g.resume_position
    };

    let file_name = handle
        .with_metadata(|m| {
            m.file_infos
                .get(file_id)
                .map(|f| f.relative_filename.to_string_lossy().into_owned())
        })
        .ok()
        .flatten();

    // Wait for the container header before handing the URL to the player.
    // Marking ready with 0 bytes left clients stuck on "connected" forever.
    warm_file_head(&handle, file_id).await?;

    {
        let mut g = live.lock().await;
        g.file_name = file_name;
        g.status = "ready".into();
    }
    let prefetch_tx = spawn_prefetch_worker(handle, file_id, resume_ms).await;
    live.lock().await.prefetch_seek = prefetch_tx;
    Ok(())
}

/// Pull the first chunk of the chosen file so demuxers can open it.
async fn warm_file_head(handle: &Arc<ManagedTorrent>, file_id: usize) -> Result<(), String> {
    let Ok(mut stream) = handle.clone().stream(file_id) else {
        return Err("Couldn’t open this torrent’s video file. Try another result.".into());
    };
    let len = stream.len().max(1);
    let need = MIN_HEAD_BYTES.min(len);
    let soft = HEAD_BYTES.min(len);
    let mut buf = vec![0u8; 128 * 1024];
    let mut got = 0u64;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
    let _ = stream.seek(SeekFrom::Start(0)).await;

    while got < need && tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buf)).await {
            Ok(Ok(0)) => {
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
            Ok(Ok(n)) => {
                got = got.saturating_add(n as u64);
                // Keep going toward the soft target when peers are fast, but
                // don't block playback once the minimum header is present.
                if got >= need && got >= soft {
                    break;
                }
                if got >= need {
                    // One more short attempt for a fatter buffer, then start.
                    let soft_deadline = tokio::time::Instant::now() + Duration::from_secs(4);
                    while got < soft && tokio::time::Instant::now() < soft_deadline {
                        match tokio::time::timeout(Duration::from_secs(1), stream.read(&mut buf))
                            .await
                        {
                            Ok(Ok(0)) | Err(_) => break,
                            Ok(Ok(n2)) => got = got.saturating_add(n2 as u64),
                            Ok(Err(_)) => break,
                        }
                    }
                    break;
                }
            }
            Ok(Err(_)) => {
                tokio::time::sleep(Duration::from_millis(200)).await;
                let _ = stream.seek(SeekFrom::Start(got.min(len.saturating_sub(1)))).await;
            }
            Err(_) => {
                // Timed out waiting for pieces — stay on the head window.
                let _ = stream.seek(SeekFrom::Start(got.min(len.saturating_sub(1)))).await;
            }
        }
    }

    if got < need {
        return Err(
            "Connected to peers but couldn’t download enough video data to start. Try another result."
                .into(),
        );
    }
    Ok(())
}

/// Keep one FileStream alive so piece priority follows playback.
/// Seeking the stream updates rqbit's 32 MB sequential window; without this,
/// an old window at t=0 keeps stealing bandwidth after the player seeks.
async fn spawn_prefetch_worker(
    handle: Arc<ManagedTorrent>,
    file_id: usize,
    resume_ms: i64,
) -> Option<tokio::sync::mpsc::UnboundedSender<u64>> {
    let Ok(prefetch) = handle.clone().stream(file_id) else {
        return None;
    };
    let len = prefetch.len();
    // Prefer pieces around the resume timestamp so any magnet can start mid-title.
    // ~2.5 MB/s is a conservative 1080p estimate.
    let est = ((resume_ms.max(0) as u64).saturating_mul(2_500_000) / 1000).min(len.saturating_sub(1));
    let start = est.saturating_sub(HEAD_BYTES / 4);

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<u64>();
    tokio::spawn(async move {
        let mut stream = prefetch;
        let mut buf = vec![0u8; 128 * 1024];
        let _ = stream.seek(SeekFrom::Start(start)).await;
        let mut pos = start;
        // Keep reading forever — empty reads mean "peers not ready yet", not EOF.
        // Without this, Jackett/magnet swarms sit at 0 MB/s after metadata.
        loop {
            tokio::select! {
                cmd = rx.recv() => {
                    match cmd {
                        Some(new_pos) => {
                            pos = new_pos.min(len.saturating_sub(1));
                            if stream.seek(SeekFrom::Start(pos)).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                result = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut buf)) => {
                    match result {
                        Ok(Ok(0)) => {
                            // No bytes yet — pause briefly then keep interest in the swarm.
                            tokio::time::sleep(Duration::from_millis(250)).await;
                        }
                        Ok(Ok(n)) => {
                            pos = pos.saturating_add(n as u64).min(len.saturating_sub(1));
                        }
                        Ok(Err(_)) => {
                            tokio::time::sleep(Duration::from_millis(200)).await;
                            let _ = stream.seek(SeekFrom::Start(pos)).await;
                        }
                        Err(_) => {
                            // Read timed out waiting for pieces — stay on the window.
                            let _ = stream.seek(SeekFrom::Start(pos)).await;
                        }
                    }
                }
            }
        }
    });
    Some(tx)
}

fn retarget_prefetch_bytes(live: &LiveStream, byte_offset: u64) {
    if let Some(tx) = live.prefetch_seek.as_ref() {
        let _ = tx.send(byte_offset);
    }
}

fn friendly_list_files_error(raw: &str) -> String {
    let t = raw.to_ascii_lowercase();
    if t.contains("302") || t.contains("301") || t.contains("redirect") {
        return "Couldn’t open this Jackett download link. Try another result (prefer magnet links).".into();
    }
    if t.contains("timeout") || t.contains("timed out") {
        return "Couldn’t read this torrent’s file list (timeout). Try another result, or Play again.".into();
    }
    if t.contains("magnet") && (t.contains("invalid") || t.contains("parse") || t.contains("missing")) {
        return "That torrent link isn’t valid. Try another result.".into();
    }
    if t.contains("connection") || t.contains("unreachable") || t.contains("resolve") {
        return "Couldn’t reach peers to read this torrent. Try another result.".into();
    }
    tracing::debug!(raw, "unmapped list_files error");
    "Couldn’t read this torrent’s files. Try another result.".into()
}

fn friendly_stream_error(raw: &str) -> String {
    let t = raw.to_ascii_lowercase();
    // Already user-facing from resolve_torrent_source / earlier mapping.
    if t.contains("couldn’t") || t.contains("couldn't") || t.contains("try another") {
        return raw.to_string();
    }
    if t.contains("302") || t.contains("301") || t.contains("redirect") {
        return "Couldn’t open this Jackett download link. Try another result (prefer magnet links).".into();
    }
    if t.contains("timeout") || t.contains("timed out") || t.contains("peers") {
        return "Couldn’t find enough peers to start this stream. Try another result.".into();
    }
    if t.contains("metadata")
        || t.contains("dht")
        || t.contains("announce")
        || t.contains("unable to resolve")
        || t.contains("no response")
    {
        return "Couldn’t fetch this torrent’s metadata. Try another result with more seeders.".into();
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
    if t.contains("connection refused")
        || t.contains("unreachable")
        || t.contains("network")
        || t.contains("i/o")
        || t.contains("io error")
    {
        return "Couldn’t reach peers for this torrent. Try another result.".into();
    }
    tracing::warn!(raw, "unmapped stream error");
    "Couldn’t start this stream. Try another result with more seeders.".into()
}

/// Jackett often returns `/dl/...` HTTP links that 302 to a magnet or .torrent.
/// librqbit does not follow those redirects, so resolve them here first.
#[derive(Clone)]
enum ResolvedTorrent {
    Magnet(String),
    File(Bytes),
}

impl ResolvedTorrent {
    fn to_add(&self) -> AddTorrent<'static> {
        match self {
            Self::Magnet(u) => AddTorrent::from_url(u.clone()),
            Self::File(b) => AddTorrent::from_bytes(b.clone()),
        }
    }
}

async fn resolve_torrent_source(input: &str) -> Result<ResolvedTorrent, String> {
    let mut url = input.trim().to_string();
    if url.is_empty() {
        return Err("That torrent link is missing. Try another result.".into());
    }
    if url.to_ascii_lowercase().starts_with("magnet:") {
        return Ok(ResolvedTorrent::Magnet(url));
    }
    if !(url.to_ascii_lowercase().starts_with("http://")
        || url.to_ascii_lowercase().starts_with("https://"))
    {
        return Err("That torrent link isn’t valid. Try another result.".into());
    }

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .user_agent("PeanutButter/0.2")
        .build()
        .map_err(|_| "Couldn’t prepare torrent download. Try again.".to_string())?;

    for _ in 0..12 {
        let lower = url.to_ascii_lowercase();
        if lower.starts_with("magnet:") {
            return Ok(ResolvedTorrent::Magnet(url));
        }
        if !(lower.starts_with("http://") || lower.starts_with("https://")) {
            break;
        }

        let resp = client
            .get(&url)
            .send()
            .await
            .map_err(|e| {
                tracing::warn!(error = %e, "torrent link fetch failed");
                "Couldn’t download this torrent link. Try another result.".to_string()
            })?;
        let status = resp.status();
        if status.is_redirection() {
            let loc = resp
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            let Some(loc) = loc else {
                return Err(
                    "Couldn’t open this Jackett download link. Try another result.".into(),
                );
            };
            url = join_redirect_url(&url, &loc);
            continue;
        }
        if !status.is_success() {
            return Err(format!(
                "Couldn’t download this torrent (HTTP {}). Try another result.",
                status.as_u16()
            ));
        }

        let bytes = resp.bytes().await.map_err(|_| {
            "Couldn’t download this torrent file. Try another result.".to_string()
        })?;
        if let Ok(text) = std::str::from_utf8(&bytes) {
            let trimmed = text.trim();
            if trimmed.to_ascii_lowercase().starts_with("magnet:") {
                return Ok(ResolvedTorrent::Magnet(trimmed.to_string()));
            }
        }
        // Bencoded .torrent files start with 'd' (dictionary).
        if bytes.len() > 16 && bytes.starts_with(b"d") {
            return Ok(ResolvedTorrent::File(bytes));
        }
        return Err(
            "That download wasn’t a torrent or magnet. Try another result.".into(),
        );
    }

    Err("Couldn’t open this Jackett download link. Try another result.".into())
}

fn join_redirect_url(base: &str, location: &str) -> String {
    if location.to_ascii_lowercase().starts_with("magnet:")
        || location.to_ascii_lowercase().starts_with("http://")
        || location.to_ascii_lowercase().starts_with("https://")
    {
        return location.to_string();
    }
    match reqwest::Url::parse(base).and_then(|b| b.join(location)) {
        Ok(u) => u.to_string(),
        Err(_) => location.to_string(),
    }
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
            // Redirect sequential piece priority to the seek target immediately.
            {
                let g = live.lock().await;
                retarget_prefetch_bytes(&g, start);
            }
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
