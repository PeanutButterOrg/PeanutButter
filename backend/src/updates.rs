//! App updates: mirror signed GitHub Releases into the server's data volume and
//! offer them to apps on the LAN.
//!
//! CI publishes, for each vX.Y.Z tag, one installer per platform plus
//! `manifest.json` (sizes + SHA-256) and `manifest.json.sig` (Ed25519 over the
//! exact manifest bytes). This server only accepts a release whose signature
//! verifies against [`UPDATE_PUBLIC_KEY`] and whose files match the manifest;
//! apps verify the same signature again before installing.
//!
//! Layout under `UPDATES_DIR` (default `/data/updates`):
//!   releases/<tag>/{manifest.json, manifest.json.sig, <installers>}
//!   current   (text file: tag of the release being offered)

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use axum::body::Body;
use axum::extract::{Path as UrlPath, Query};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tracing::{info, warn};

use crate::error::AppError;

/// Raw Ed25519 public key (base64) matching packaging/update-signing-public.pem.
/// The private half lives only in the UPDATE_SIGNING_KEY CI secret.
pub const UPDATE_PUBLIC_KEY: &str = "ZZiyOouovg/54bH4BjyDRk3gldZtS+oHJjjkUGo6e7c=";

/// Platform keys apps ask for (must match scripts/release_manifest.py).
pub const PLATFORMS: &[&str] = &[
    "windows",
    "macos",
    "linux-appimage",
    "linux-deb",
    "android-tv",
    "android-tv-arm64-v8a",
    "android-tv-armeabi-v7a",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Asset {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub schema: u32,
    pub version: String,
    #[serde(default)]
    pub prerelease: bool,
    pub build: i64,
    pub tag: String,
    #[serde(default)]
    pub published_at: String,
    #[serde(default)]
    pub notes_url: String,
    pub assets: HashMap<String, Asset>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub enabled: bool,
    pub repo: String,
    pub current_tag: Option<String>,
    pub current_version: Option<String>,
    pub current_build: Option<i64>,
    pub last_check: Option<String>,
    pub last_error: Option<String>,
    pub busy: bool,
}

struct Service {
    dir: PathBuf,
    repo: String,
    enabled: bool,
    include_prerelease: bool,
    http: reqwest::Client,
    status: Mutex<UpdateStatus>,
    /// Serialises checks (background timer vs. console "Check now").
    run: tokio::sync::Mutex<()>,
}

fn env_flag(name: &str, default: bool) -> bool {
    match std::env::var(name) {
        Ok(v) => matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"),
        Err(_) => default,
    }
}

fn service() -> &'static Service {
    static SVC: OnceLock<Service> = OnceLock::new();
    SVC.get_or_init(|| {
        let repo = std::env::var("UPDATES_REPO")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "PeanutButterOrg/PeanutButter".into());
        let enabled = env_flag("UPDATES_ENABLED", true);
        let http = reqwest::Client::builder()
            .user_agent(concat!("PeanutButter-updates/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(30 * 60))
            .build()
            .unwrap_or_default();
        Service {
            dir: PathBuf::from(
                std::env::var("UPDATES_DIR").unwrap_or_else(|_| "/data/updates".into()),
            ),
            status: Mutex::new(UpdateStatus {
                enabled,
                repo: repo.clone(),
                ..Default::default()
            }),
            repo,
            enabled,
            include_prerelease: env_flag("UPDATES_INCLUDE_PRERELEASE", false),
            http,
            run: tokio::sync::Mutex::new(()),
        }
    })
}

pub fn verify_signature(manifest: &[u8], signature_b64: &str) -> bool {
    use base64_lite::decode;
    let (Some(key), Some(sig)) = (decode(UPDATE_PUBLIC_KEY), decode(signature_b64.trim())) else {
        return false;
    };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(manifest, &sig)
        .is_ok()
}

/// Tiny standard-alphabet base64 decoder (no extra crate for 2 call sites).
mod base64_lite {
    pub fn decode(s: &str) -> Option<Vec<u8>> {
        let mut out = Vec::with_capacity(s.len() * 3 / 4);
        let mut buf = 0u32;
        let mut bits = 0;
        for c in s.bytes() {
            let v = match c {
                b'A'..=b'Z' => c - b'A',
                b'a'..=b'z' => c - b'a' + 26,
                b'0'..=b'9' => c - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' => break,
                b'\n' | b'\r' | b' ' => continue,
                _ => return None,
            } as u32;
            buf = (buf << 6) | v;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((buf >> bits) as u8);
            }
        }
        Some(out)
    }
}

fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 128
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
        && !s.starts_with('.')
}

impl Service {
    fn releases_dir(&self) -> PathBuf {
        self.dir.join("releases")
    }

    async fn current_tag(&self) -> Option<String> {
        let tag = tokio::fs::read_to_string(self.dir.join("current")).await.ok()?;
        let tag = tag.trim().to_string();
        safe_name(&tag).then_some(tag)
    }

    /// Manifest bytes + signature for `tag`, re-verified on every read so a
    /// tampered file on disk is never served.
    async fn load(&self, tag: &str) -> Option<(Manifest, Vec<u8>, String)> {
        let dir = self.releases_dir().join(tag);
        let raw = tokio::fs::read(dir.join("manifest.json")).await.ok()?;
        let sig = tokio::fs::read_to_string(dir.join("manifest.json.sig")).await.ok()?;
        if !verify_signature(&raw, &sig) {
            warn!(tag, "stored update manifest failed signature check; ignoring");
            return None;
        }
        let manifest: Manifest = serde_json::from_slice(&raw).ok()?;
        Some((manifest, raw, sig.trim().to_string()))
    }

    fn set_status(&self, f: impl FnOnce(&mut UpdateStatus)) {
        f(&mut self.status.lock().unwrap_or_else(|e| e.into_inner()));
    }

    async fn refresh_current_status(&self) {
        let current = match self.current_tag().await {
            Some(tag) => self.load(&tag).await,
            None => None,
        };
        self.set_status(|s| {
            s.current_tag = current.as_ref().map(|(m, _, _)| m.tag.clone());
            s.current_version = current.as_ref().map(|(m, _, _)| m.version.clone());
            s.current_build = current.as_ref().map(|(m, _, _)| m.build);
        });
    }

    async fn latest_release(&self) -> Result<GhRelease, AppError> {
        let base = format!("https://api.github.com/repos/{}/releases", self.repo);
        let res = if self.include_prerelease {
            let list: Vec<GhRelease> = self
                .http
                .get(format!("{base}?per_page=5"))
                .header(header::ACCEPT, "application/vnd.github+json")
                .send()
                .await?
                .error_for_status()?
                .json()
                .await?;
            list.into_iter()
                .find(|r| !r.draft)
                .ok_or_else(|| AppError::NotFound("no releases published yet".into()))?
        } else {
            let res = self
                .http
                .get(format!("{base}/latest"))
                .header(header::ACCEPT, "application/vnd.github+json")
                .send()
                .await?;
            if res.status() == StatusCode::NOT_FOUND {
                return Err(AppError::NotFound("no releases published yet".into()));
            }
            res.error_for_status()?.json().await?
        };
        Ok(res)
    }

    async fn download_text(&self, url: &str) -> Result<Vec<u8>, AppError> {
        let res = self.http.get(url).send().await?.error_for_status()?;
        let bytes = res.bytes().await?;
        if bytes.len() > 1 << 20 {
            return Err(AppError::BadRequest("manifest is unexpectedly large".into()));
        }
        Ok(bytes.to_vec())
    }

    /// Stream `url` into `dest`, enforcing the manifest's size and SHA-256.
    async fn download_asset(&self, url: &str, dest: &Path, asset: &Asset) -> Result<(), AppError> {
        let res = self.http.get(url).send().await?.error_for_status()?;
        let mut file = tokio::fs::File::create(dest).await?;
        let mut hasher = Sha256::new();
        let mut size = 0u64;
        let mut stream = res.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            size += chunk.len() as u64;
            if size > asset.size {
                return Err(AppError::BadRequest(format!("{} is larger than its manifest says", asset.name)));
            }
            hasher.update(&chunk);
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        let digest = hex::encode(hasher.finalize());
        if size != asset.size || !digest.eq_ignore_ascii_case(&asset.sha256) {
            return Err(AppError::BadRequest(format!("{} does not match the signed manifest", asset.name)));
        }
        Ok(())
    }

    async fn check(&self) -> Result<String, AppError> {
        if !self.enabled {
            return Ok("Updates are disabled (UPDATES_ENABLED=false).".into());
        }
        let _run = self.run.lock().await;
        let release = self.latest_release().await?;
        let asset_url = |name: &str| {
            release
                .assets
                .iter()
                .find(|a| a.name == name)
                .map(|a| a.browser_download_url.clone())
        };
        let (Some(manifest_url), Some(sig_url)) =
            (asset_url("manifest.json"), asset_url("manifest.json.sig"))
        else {
            return Err(AppError::BadRequest(format!(
                "release {} has no signed manifest",
                release.tag_name
            )));
        };
        let raw = self.download_text(&manifest_url).await?;
        let sig = String::from_utf8_lossy(&self.download_text(&sig_url).await?).trim().to_string();
        if !verify_signature(&raw, &sig) {
            return Err(AppError::BadRequest(format!(
                "release {} has an invalid signature — not mirrored",
                release.tag_name
            )));
        }
        let manifest: Manifest = serde_json::from_slice(&raw)
            .map_err(|e| AppError::BadRequest(format!("unreadable manifest: {e}")))?;
        if !safe_name(&manifest.tag) || manifest.tag != release.tag_name {
            return Err(AppError::BadRequest("manifest tag does not match the release".into()));
        }
        if let Some(cur) = self.current_tag().await {
            if let Some((cm, _, _)) = self.load(&cur).await {
                if cm.build >= manifest.build {
                    return Ok(format!("Up to date ({} build {}).", cm.version, cm.build));
                }
            }
        }

        info!(tag = %manifest.tag, "mirroring app update");
        self.set_status(|s| s.busy = true);
        let staging = self.dir.join(format!(".staging-{}", manifest.tag));
        let _ = tokio::fs::remove_dir_all(&staging).await;
        tokio::fs::create_dir_all(&staging).await?;
        let result: Result<(), AppError> = async {
            for (platform, asset) in &manifest.assets {
                if !PLATFORMS.contains(&platform.as_str()) || !safe_name(&asset.name) {
                    continue;
                }
                let url = asset_url(&asset.name).ok_or_else(|| {
                    AppError::BadRequest(format!("{} is missing from the release", asset.name))
                })?;
                self.download_asset(&url, &staging.join(&asset.name), asset).await?;
            }
            tokio::fs::write(staging.join("manifest.json"), &raw).await?;
            tokio::fs::write(staging.join("manifest.json.sig"), &sig).await?;
            let final_dir = self.releases_dir().join(&manifest.tag);
            tokio::fs::create_dir_all(self.releases_dir()).await?;
            let _ = tokio::fs::remove_dir_all(&final_dir).await;
            tokio::fs::rename(&staging, &final_dir).await?;
            let tmp = self.dir.join(".current.tmp");
            tokio::fs::write(&tmp, &manifest.tag).await?;
            tokio::fs::rename(&tmp, self.dir.join("current")).await?;
            Ok(())
        }
        .await;
        self.set_status(|s| s.busy = false);
        if let Err(e) = result {
            let _ = tokio::fs::remove_dir_all(&staging).await;
            return Err(e);
        }
        self.prune(&manifest.tag).await;
        Ok(format!("Downloaded {} (build {}).", manifest.version, manifest.build))
    }

    /// Keep the offered release plus the newest older one (for rollback).
    async fn prune(&self, keep: &str) {
        let Ok(mut rd) = tokio::fs::read_dir(self.releases_dir()).await else {
            return;
        };
        let mut others: Vec<(i64, PathBuf)> = Vec::new();
        while let Ok(Some(e)) = rd.next_entry().await {
            let name = e.file_name().to_string_lossy().to_string();
            if name == keep {
                continue;
            }
            let build = self.load(&name).await.map(|(m, _, _)| m.build).unwrap_or(-1);
            others.push((build, e.path()));
        }
        others.sort_by(|a, b| b.0.cmp(&a.0));
        for (_, path) in others.into_iter().skip(1) {
            let _ = tokio::fs::remove_dir_all(path).await;
        }
    }
}

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<GhAsset>,
}

#[derive(Debug, Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
}

/// Check GitHub now; returns a short human-readable result for the console.
pub async fn check_now() -> String {
    let svc = service();
    let msg = match svc.check().await {
        Ok(msg) => {
            svc.set_status(|s| s.last_error = None);
            msg
        }
        Err(e) => {
            let msg = match &e {
                AppError::NotFound(m) | AppError::BadRequest(m) => m.clone(),
                other => other.to_string(),
            };
            warn!(error = %msg, "app update check failed");
            svc.set_status(|s| s.last_error = Some(msg.clone()));
            format!("Update check failed: {msg}")
        }
    };
    svc.set_status(|s| {
        s.last_check = Some(chrono::Utc::now().format("%Y-%m-%d %H:%M UTC").to_string())
    });
    svc.refresh_current_status().await;
    msg
}

pub async fn status() -> UpdateStatus {
    let svc = service();
    svc.refresh_current_status().await;
    svc.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Background mirror: shortly after boot, then every UPDATE_CHECK_HOURS (6).
pub fn spawn_background() {
    let svc = service();
    if !svc.enabled {
        info!("app updates disabled (UPDATES_ENABLED=false)");
        return;
    }
    let hours: u64 = std::env::var("UPDATE_CHECK_HOURS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|h| *h > 0)
        .unwrap_or(6);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(120)).await;
        loop {
            let msg = check_now().await;
            info!(result = %msg, "app update check");
            tokio::time::sleep(Duration::from_secs(hours * 3600)).await;
        }
    });
}

#[derive(Deserialize)]
pub struct LatestQuery {
    platform: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LatestResponse {
    version: String,
    build: i64,
    prerelease: bool,
    published_at: String,
    notes_url: String,
    asset: Asset,
    /// Server-relative download path (send the device key, as for /files).
    url: String,
    /// The exact signed bytes and signature, so the app verifies them itself.
    manifest: String,
    signature: String,
}

/// GET /updates/latest?platform=windows — 204 when nothing is mirrored.
pub async fn latest(Query(q): Query<LatestQuery>) -> Result<Response, AppError> {
    if !PLATFORMS.contains(&q.platform.as_str()) {
        return Err(AppError::BadRequest(format!("unknown platform {}", q.platform)));
    }
    let svc = service();
    let Some(tag) = svc.current_tag().await else {
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    let Some((manifest, raw, sig)) = svc.load(&tag).await else {
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    let Some(asset) = manifest.assets.get(&q.platform).cloned() else {
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    Ok(Json(LatestResponse {
        url: format!("/updates/files/{}/{}", manifest.tag, asset.name),
        version: manifest.version,
        build: manifest.build,
        prerelease: manifest.prerelease,
        published_at: manifest.published_at,
        notes_url: manifest.notes_url,
        asset,
        manifest: String::from_utf8_lossy(&raw).into_owned(),
        signature: sig,
    })
    .into_response())
}

/// GET /updates/files/{tag}/{name} — a mirrored installer (Range supported).
pub async fn file(
    UrlPath((tag, name)): UrlPath<(String, String)>,
    req_headers: HeaderMap,
) -> Result<Response, AppError> {
    if !safe_name(&tag) || !safe_name(&name) || name.starts_with("manifest") {
        return Err(AppError::NotFound("no such update file".into()));
    }
    let path = service().releases_dir().join(&tag).join(&name);
    if !path.is_file() {
        return Err(AppError::NotFound("no such update file".into()));
    }
    let mut req = axum::http::Request::new(Body::empty());
    *req.headers_mut() = req_headers;
    let mut serve = tower_http::services::ServeFile::new(&path);
    let res = serve
        .try_call(req)
        .await
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let mut res = res.map(Body::new);
    res.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        header::HeaderValue::from_str(&format!("attachment; filename=\"{name}\""))
            .unwrap_or_else(|_| header::HeaderValue::from_static("attachment")),
    );
    Ok(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_key_matches_committed_pem() {
        let pem = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../packaging/update-signing-public.pem"),
        )
        .expect("packaging/update-signing-public.pem");
        let b64: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
        let der = base64_lite::decode(&b64).unwrap();
        // Ed25519 SubjectPublicKeyInfo = 12-byte prefix + 32-byte key.
        assert_eq!(&der[der.len() - 32..], &base64_lite::decode(UPDATE_PUBLIC_KEY).unwrap()[..]);
    }

    /// Signed by CI's exact command (openssl pkeyutl -sign -rawin) with the
    /// real update key, so Rust and OpenSSL agree on the format.
    const FIXTURE: &[u8] = b"{\"schema\":1,\"version\":\"0.0.1\",\"build\":1,\"tag\":\"v0.0.1\",\"assets\":{}}\n";
    const FIXTURE_SIG: &str = "Lz4t5lcX/1zacups8J6ny8y15a8z0HAYCjHMt+hzWQqvFE+qzNELo5yte55nORmoqConwMNxZE/9NLGEdnxVAQ==";

    #[test]
    fn accepts_openssl_signature_and_rejects_tampering() {
        assert!(verify_signature(FIXTURE, FIXTURE_SIG));
        let mut tampered = FIXTURE.to_vec();
        tampered[20] ^= 1;
        assert!(!verify_signature(&tampered, FIXTURE_SIG));
    }

    #[test]
    fn rejects_bad_signatures() {
        assert!(!verify_signature(b"{}", "AAAA"));
        assert!(!verify_signature(b"{}", "not base64!"));
        let zero_sig = "A".repeat(86) + "==";
        assert!(!verify_signature(b"{\"schema\":1}", &zero_sig));
    }

    #[test]
    fn names_are_safe() {
        assert!(safe_name("v0.3.0"));
        assert!(safe_name("PeanutButter-windows-x64-setup.exe"));
        assert!(!safe_name("../etc/passwd"));
        assert!(!safe_name(".staging-v1"));
        assert!(!safe_name("a/b"));
    }
}
