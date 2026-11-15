//! Torrent metadata on the server: list a magnet's video files (the source
//! picker's season-pack file list) and sample its swarm (seeder counts when an
//! index has none). Nothing is downloaded or streamed here: playback runs on
//! each device. Torrents are added "list only", so only metadata is fetched.

use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use librqbit::limits::LimitsConfig;
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent, PeerConnectionOptions,
    Session, SessionOptions, TorrentMetaV1Info,
};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::error::AppError;

const VIDEO_EXT: &[&str] = &["mkv", "mp4", "avi", "webm", "mov", "m4v"];
/// Smaller video files are samples, trailers or extras, not the feature.
const MIN_PLAYABLE_BYTES: u64 = 80 * 1024 * 1024;
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

/// Live swarm sample from DHT/trackers (Jackett Seeders are often missing/wrong).
#[derive(Debug, Clone, Copy)]
pub struct SwarmProbe {
    /// Connected peers right now (best live signal librqbit exposes).
    pub seeders: i32,
    /// Peers discovered via DHT/trackers during resolve.
    pub peers: i32,
}

#[derive(Clone)]
pub struct StreamService {
    inner: Arc<StreamInner>,
}

struct StreamInner {
    session: tokio::sync::OnceCell<Arc<Session>>,
    /// Scratch folders for list-only adds (librqbit wants an output folder).
    output_root: PathBuf,
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

fn peer_opts(read_write_secs: u64) -> PeerConnectionOptions {
    PeerConnectionOptions {
        connect_timeout: Some(Duration::from_secs(2)),
        read_write_timeout: Some(Duration::from_secs(read_write_secs)),
        keep_alive_interval: Some(Duration::from_secs(read_write_secs)),
    }
}

impl StreamService {
    pub fn new(media_path: PathBuf) -> Self {
        Self {
            inner: Arc::new(StreamInner {
                session: tokio::sync::OnceCell::new(),
                output_root: stream_output_root(media_path),
            }),
        }
    }

    /// The torrent engine, started on first use.
    async fn session(&self) -> Result<Arc<Session>, AppError> {
        self.inner
            .session
            .get_or_try_init(|| async {
                tokio::fs::create_dir_all(&self.inner.output_root)
                    .await
                    .map_err(|_| "Couldn’t prepare the torrent folder on the server. Try again.".to_string())?;
                Session::new_with_opts(
                    self.inner.output_root.clone(),
                    SessionOptions {
                        disable_dht: false,
                        disable_dht_persistence: false,
                        enable_upnp_port_forwarding: true,
                        listen_port_range: Some(torrent_listen_range()),
                        defer_writes_up_to: Some(512),
                        concurrent_init_limit: Some(16),
                        peer_opts: Some(peer_opts(8)),
                        ratelimits: torrent_limits(),
                        ..Default::default()
                    },
                )
                .await
                .map_err(|_| "Couldn’t start the torrent engine. Try again.".to_string())
            })
            .await
            .cloned()
            .map_err(AppError::Message)
    }

    /// List playable video files inside a magnet (list-only — nothing is downloaded).
    pub async fn list_files(&self, magnet: &str) -> Result<Vec<TorrentFileEntry>, AppError> {
        let magnet = require_magnet(magnet)?;
        let session = self.session().await?;
        let tmp = self.inner.output_root.join(format!("list-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&tmp).await.map_err(AppError::Io)?;
        let options = || AddTorrentOptions {
            list_only: true,
            overwrite: true,
            output_folder: Some(tmp.to_string_lossy().into_owned()),
            force_tracker_interval: Some(Duration::from_secs(3)),
            trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
            ratelimits: torrent_limits(),
            ..Default::default()
        };
        let mut listed = session
            .add_torrent(AddTorrent::from_url(magnet.to_string()), Some(options()))
            .await;
        // One retry helps when DHT/metadata is slow on the first attempt.
        if let Err(e) = &listed {
            tracing::warn!(error = %e, "torrent list_files failed; retrying");
            tokio::time::sleep(Duration::from_millis(400)).await;
            listed = session
                .add_torrent(AddTorrent::from_url(magnet.to_string()), Some(options()))
                .await;
        }
        // Remove the scratch folder whether or not listing worked.
        let _ = tokio::fs::remove_dir_all(&tmp).await;
        let listed = listed.map_err(|e| {
            tracing::warn!(error = %e, "torrent list_files retry failed");
            AppError::Message(friendly_list_files_error(&e.to_string()))
        })?;

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

    /// Briefly resolve a magnet and sample DHT/tracker peers.
    /// Used to replace Jackett's often-missing Seeders with a live signal.
    pub async fn probe_swarm(&self, magnet: &str) -> Result<SwarmProbe, AppError> {
        let magnet = require_magnet(magnet)?;
        let session = self.session().await?;
        let tmp = self.inner.output_root.join(format!("probe-{}", Uuid::new_v4()));
        tokio::fs::create_dir_all(&tmp).await.map_err(AppError::Io)?;

        // list_only resolves metadata via DHT/trackers and returns seen_peers —
        // that's the live swarm signal Jackett usually lacks.
        let listed = session
            .add_torrent(
                AddTorrent::from_url(magnet.to_string()),
                Some(AddTorrentOptions {
                    list_only: true,
                    overwrite: true,
                    output_folder: Some(tmp.to_string_lossy().into_owned()),
                    force_tracker_interval: Some(Duration::from_secs(2)),
                    trackers: Some(EXTRA_TRACKERS.iter().map(|s| (*s).to_string()).collect()),
                    ratelimits: torrent_limits(),
                    peer_opts: Some(peer_opts(6)),
                    ..Default::default()
                }),
            )
            .await;
        let _ = tokio::fs::remove_dir_all(&tmp).await;

        match listed {
            Ok(AddTorrentResponse::ListOnly(resp)) => {
                let peers = resp.seen_peers.len() as i32;
                Ok(SwarmProbe { seeders: peers, peers })
            }
            Ok(AddTorrentResponse::AlreadyManaged(_, handle)) => {
                // Another probe holds this torrent right now: read it, don't delete it.
                let live = handle.stats().live.as_ref().map(|l| l.snapshot.peer_stats.live as i32).unwrap_or(0);
                Ok(SwarmProbe { seeders: live, peers: live })
            }
            Ok(AddTorrentResponse::Added(id, handle)) => {
                // Rare for list_only — sample briefly then delete.
                let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
                let mut best_live = 0i32;
                let mut best_seen = 0i32;
                while tokio::time::Instant::now() < deadline {
                    if let Some(live) = handle.stats().live.as_ref() {
                        let snap = &live.snapshot.peer_stats;
                        best_live = best_live.max(snap.live as i32);
                        best_seen = best_seen.max(snap.seen as i32);
                        if best_live >= 2 {
                            break;
                        }
                    }
                    tokio::time::sleep(Duration::from_millis(300)).await;
                }
                let _ = session.delete(id.into(), true).await;
                let peers = best_seen.max(best_live);
                Ok(SwarmProbe {
                    seeders: best_live.max(peers),
                    peers,
                })
            }
            Err(e) => Err(AppError::Message(friendly_list_files_error(&e.to_string()))),
        }
    }

    /// Probe Jackett hits that lack seeder stats and rewrite seeders/peers/health.
    pub async fn enrich_sources_with_swarm(
        &self,
        mut sources: Vec<crate::graphql::types::StreamSource>,
    ) -> Vec<crate::graphql::types::StreamSource> {
        // Keep this cheap — probing magnets is for ranking ties, not blocking the picker.
        const MAX_PROBES: usize = 2;
        let known_good = sources.iter().filter(|s| s.seeders >= 2).count();
        if known_good >= 3 {
            return sources;
        }
        let mut idxs: Vec<usize> = sources
            .iter()
            .enumerate()
            .filter(|(_, s)| {
                s.magnet.to_ascii_lowercase().starts_with("magnet:")
                    && (s.health == "unknown" || s.health == "dead" || s.seeders < 2)
            })
            .map(|(i, _)| i)
            .take(MAX_PROBES)
            .collect();
        // If everything already has seeders, still spot-check the top magnet.
        if idxs.is_empty() && known_good < 2 {
            if let Some((i, _)) = sources
                .iter()
                .enumerate()
                .find(|(_, s)| s.magnet.to_ascii_lowercase().starts_with("magnet:"))
            {
                idxs.push(i);
            }
        }
        if idxs.is_empty() {
            return sources;
        }

        let probes = futures::future::join_all(idxs.iter().copied().map(|i| {
            let magnet = sources[i].magnet.clone();
            let this = self.clone();
            async move {
                let result = tokio::time::timeout(Duration::from_secs(3), this.probe_swarm(&magnet)).await;
                (i, result)
            }
        }))
        .await;

        for (i, result) in probes {
            let Ok(Ok(probe)) = result else {
                continue;
            };
            if probe.seeders <= 0 && probe.peers <= 0 {
                continue;
            }
            let Some(src) = sources.get_mut(i) else {
                continue;
            };
            let seeders = probe.seeders.max(if probe.peers > 0 { 1 } else { 0 });
            src.seeders = seeders.max(src.seeders);
            src.peers = probe.peers.max(src.peers);
            src.health = crate::jackett::health_for(src.seeders).into();
            src.rating = crate::jackett::calculate_rating(src.seeders);
        }

        sources.sort_by(|a, b| {
            b.seeders
                .cmp(&a.seeders)
                .then(b.peers.cmp(&a.peers))
                .then(a.title.to_ascii_lowercase().cmp(&b.title.to_ascii_lowercase()))
        });
        sources
    }

    /// Wipe scratch folders left over from a previous run (and from the old
    /// server-side streaming, which kept whole downloads here).
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

    /// Stable key for a magnet (resume positions are stored per torrent).
    pub fn magnet_key(magnet: &str) -> String {
        hex::encode(Sha256::digest(magnet.trim().as_bytes()))
    }
}

fn friendly_list_files_error(raw: &str) -> String {
    let t = raw.to_ascii_lowercase();
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

/// Apps only ever get magnets (Jackett links are turned into magnets before
/// results leave the server). Fetching a client-supplied http(s) link let any
/// paired device make the server request internal addresses.
fn require_magnet(input: &str) -> Result<&str, AppError> {
    let magnet = input.trim();
    if magnet.is_empty() {
        return Err(AppError::BadRequest(
            "That torrent link is missing. Try another result.".into(),
        ));
    }
    if !magnet.get(..7).is_some_and(|p| p.eq_ignore_ascii_case("magnet:")) {
        return Err(AppError::BadRequest(
            "That torrent link isn’t a magnet. Search again for fresh results.".into(),
        ));
    }
    Ok(magnet)
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
                .map(|(i, fi)| (i, fi.len, fi.relative_filename.to_string_lossy().into_owned()))
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

/// Samples, trailers, extras and tiny files: not the feature or episode.
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
    let lower = name.to_ascii_lowercase().replace('\\', "/");
    const JUNK_DIRS: &[&str] = &[
        "/sample/",
        "/samples/",
        "/extras/",
        "/extra/",
        "/featurettes/",
        "/featurette/",
        "/bonus/",
        "/proof/",
        "/screens/",
    ];
    if JUNK_DIRS.iter().any(|d| lower.contains(d)) {
        return true;
    }
    len > 0 && len < MIN_PLAYABLE_BYTES
}

pub(crate) fn matches_episode(name: &str, season: i32, episode: i32) -> bool {
    // Bounded: E1 must not match E10, nor 1x07 match 11x07.
    crate::jackett::torrent_matches_episode(name, season, episode)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MB: u64 = 1024 * 1024;

    #[test]
    fn only_magnets_are_accepted_from_clients() {
        assert!(require_magnet("  magnet:?xt=urn:btih:abc ").is_ok());
        assert!(require_magnet("MAGNET:?xt=urn:btih:abc").is_ok());
        assert!(require_magnet("http://169.254.169.254/latest/meta-data").is_err());
        assert!(require_magnet("https://jackett:9117/dl/x?jackett_apikey=k").is_err());
        assert!(require_magnet("").is_err());
        assert!(require_magnet("magn").is_err());
    }

    #[test]
    fn samples_trailers_and_extras_are_junk() {
        assert!(is_junk_video("Movie.1080p.Sample.mkv", 12 * MB));
        assert!(is_junk_video("Trailers/official.mp4", 8 * MB));
        assert!(is_junk_video("Extras/featurette.mkv", 400 * MB));
        assert!(is_junk_video("Show.S01E02.sample.mkv", 20 * MB));
    }

    #[test]
    fn sample_and_proof_folders_are_junk_on_any_os() {
        assert!(is_junk_video("Pack/Sample/movie.mkv", 900 * MB));
        assert!(is_junk_video("Pack\\Samples\\movie.mkv", 900 * MB));
        assert!(is_junk_video("Proof/screens.mkv", 200 * MB));
    }

    #[test]
    fn features_and_episodes_are_kept() {
        assert!(!is_junk_video("Movie.2024.1080p.BluRay.mkv", 9_000 * MB));
        assert!(!is_junk_video("Show.S01E01.1080p.mkv", 2_000 * MB));
        assert!(!is_junk_video("Season 1/05 - Title.mkv", 700 * MB));
    }

    #[test]
    fn episodes_match_exactly() {
        assert!(matches_episode("Show.S01E02.1080p.mkv", 1, 2));
        assert!(!matches_episode("Show.S01E12.1080p.mkv", 1, 2));
    }
}
