//! Server (and console) self-update through Watchtower.
//!
//! CI publishes `ghcr.io/<owner>/peanutbutter-api:stable` for every vX.Y.Z
//! tag. When the stack runs with docker-compose.autoupdate.yml, a Watchtower
//! container watches only the api container and exposes a token-protected
//! HTTP API instead of polling on its own. This module:
//!
//! - compares the running version (baked in by CI) with the newest release
//!   that `updates` saw on GitHub,
//! - backs up Postgres, then asks Watchtower to pull and restart the api
//!   ("Update now" in the console),
//! - does the same by itself when Auto-update is on and no server-side
//!   stream is open.
//!
//! The shared Watchtower token is created here, in a volume both containers
//! mount (`PB_CONTROL_DIR`), so nothing has to be configured by hand.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;
use sqlx::PgPool;
use tracing::{info, warn};

use crate::error::{AppError, Result};

const KEEP_BACKUPS: usize = 5;
/// Don't retry an automatic update for the same version more often than this.
const AUTO_RETRY: Duration = Duration::from_secs(6 * 3600);

#[derive(Debug, Clone, Default, Serialize)]
pub struct ServerUpdateStatus {
    pub running: String,
    pub latest: Option<String>,
    pub update_available: bool,
    /// Watchtower is wired up (docker-compose.autoupdate.yml).
    pub managed: bool,
    pub auto: bool,
    pub busy: bool,
    pub message: Option<String>,
    pub last_backup: Option<String>,
}

struct State {
    busy: AtomicBool,
    auto: AtomicBool,
    message: Mutex<Option<String>>,
    last_backup: Mutex<Option<String>>,
    last_auto: Mutex<Option<(String, Instant)>>,
}

fn state() -> &'static State {
    static S: OnceLock<State> = OnceLock::new();
    S.get_or_init(|| State {
        busy: AtomicBool::new(false),
        auto: AtomicBool::new(false),
        message: Mutex::new(None),
        last_backup: Mutex::new(None),
        last_auto: Mutex::new(None),
    })
}

fn set_message(msg: impl Into<String>) {
    *state().message.lock().unwrap_or_else(|e| e.into_inner()) = Some(msg.into());
}

fn watchtower_url() -> Option<String> {
    std::env::var("PB_WATCHTOWER_URL")
        .ok()
        .map(|v| v.trim().trim_end_matches('/').to_string())
        .filter(|v| !v.is_empty())
}

fn control_dir() -> PathBuf {
    std::env::var("PB_CONTROL_DIR")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/data/control"))
}

fn backup_dir() -> PathBuf {
    std::env::var("PB_BACKUP_DIR")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/data/backups"))
}

fn token_path() -> PathBuf {
    control_dir().join("watchtower-token")
}

/// Create the shared Watchtower token on first start (Watchtower reads the
/// same file). Runs before the api reports healthy, which Watchtower waits for.
pub fn ensure_token() {
    if watchtower_url().is_none() {
        return;
    }
    let path = token_path();
    if path.exists() {
        return;
    }
    let mut bytes = [0u8; 24];
    if ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).is_err() {
        warn!("could not generate the Watchtower token");
        return;
    }
    let token = hex::encode(bytes);
    let result = (|| -> std::io::Result<()> {
        std::fs::create_dir_all(control_dir())?;
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &token)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(&tmp, &path)
    })();
    match result {
        Ok(()) => info!("created Watchtower token for server updates"),
        Err(e) => warn!(error = %e, "could not write the Watchtower token"),
    }
}

/// Load the Auto-update switch at start-up.
pub async fn load(pool: &PgPool) -> Result<()> {
    let row: Option<(bool,)> =
        sqlx::query_as("SELECT server_auto_update FROM app_settings WHERE id = 1")
            .fetch_optional(pool)
            .await?;
    state()
        .auto
        .store(row.map(|(v,)| v).unwrap_or(false), Ordering::Relaxed);
    Ok(())
}

pub async fn set_auto(pool: &PgPool, on: bool) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO app_settings (id, server_auto_update, updated_at)
        VALUES (1, $1, NOW())
        ON CONFLICT (id) DO UPDATE
        SET server_auto_update = EXCLUDED.server_auto_update, updated_at = NOW()
        "#,
    )
    .bind(on)
    .execute(pool)
    .await?;
    state().auto.store(on, Ordering::Relaxed);
    Ok(())
}

/// (major, minor, patch, is_prerelease) from "v1.2.3" / "1.2.3-rc1".
fn parse_version(raw: &str) -> Option<(u64, u64, u64, bool)> {
    let v = raw.trim().trim_start_matches('v');
    let (core, pre) = match v.split_once('-') {
        Some((c, _)) => (c, true),
        None => (v, false),
    };
    let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().flatten().unwrap_or(0);
    let patch = parts.next().flatten().unwrap_or(0);
    Some((major, minor, patch, pre))
}

/// `latest` is a newer release than `running`.
pub fn is_newer(latest: &str, running: &str) -> bool {
    match (parse_version(latest), parse_version(running)) {
        (Some((a1, b1, c1, p1)), Some((a2, b2, c2, p2))) => {
            // A release beats a pre-release of the same number.
            (a1, b1, c1, !p1) > (a2, b2, c2, !p2)
        }
        _ => false,
    }
}

pub async fn status() -> ServerUpdateStatus {
    let running = crate::config::build_version().to_string();
    let latest = crate::updates::status().await.latest_tag;
    let update_available = latest.as_deref().is_some_and(|l| is_newer(l, &running));
    let s = state();
    ServerUpdateStatus {
        running,
        latest,
        update_available,
        managed: watchtower_url().is_some() && token_path().exists(),
        auto: s.auto.load(Ordering::Relaxed),
        busy: s.busy.load(Ordering::Relaxed),
        message: s.message.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        last_backup: s.last_backup.lock().unwrap_or_else(|e| e.into_inner()).clone(),
    }
}

/// Back up Postgres, then ask Watchtower to update the api container.
/// Returns at once; the container restarts (and this process ends) when
/// Watchtower has pulled the new image.
pub async fn update_now(http: &reqwest::Client) -> Result<String> {
    let Some(url) = watchtower_url() else {
        return Err(AppError::BadRequest(
            "Server updates aren't set up on this server yet. See docs/SERVER.md, \"Automatic server updates\".".into(),
        ));
    };
    let token = tokio::fs::read_to_string(token_path())
        .await
        .map(|t| t.trim().to_string())
        .map_err(|_| AppError::BadRequest("The Watchtower token is missing; restart the stack once.".into()))?;
    let s = state();
    if s.busy.swap(true, Ordering::SeqCst) {
        return Err(AppError::BadRequest("An update is already running.".into()));
    }

    match backup().await {
        Ok(path) => {
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            *s.last_backup.lock().unwrap_or_else(|e| e.into_inner()) = Some(name);
        }
        Err(e) => {
            s.busy.store(false, Ordering::SeqCst);
            set_message(format!("Update cancelled: the database backup failed ({e})."));
            return Err(AppError::BadRequest(format!(
                "Update cancelled: the database backup failed ({e})."
            )));
        }
    }

    let latest = status().await.latest.unwrap_or_else(|| "the latest release".into());
    set_message(format!("Updating to {latest}… the console will be back in about a minute."));
    let http = http.clone();
    tokio::spawn(async move {
        // Watchtower answers when it has finished; if the image changed this
        // process is stopped long before that.
        let res = http
            .post(format!("{url}/v1/update"))
            .bearer_auth(token)
            .timeout(Duration::from_secs(15 * 60))
            .send()
            .await;
        let msg = match res {
            Ok(r) if r.status().is_success() => {
                "No newer server image was found yet. CI may still be publishing it; try again in a few minutes.".to_string()
            }
            Ok(r) if r.status() == reqwest::StatusCode::UNAUTHORIZED => {
                "Watchtower rejected the update token. Restart the stack so both containers read the same token.".to_string()
            }
            Ok(r) => format!("Watchtower returned {}.", r.status()),
            Err(e) => format!("Couldn't reach Watchtower: {e}"),
        };
        warn!(result = %msg, "server update did not restart the api");
        set_message(msg);
        state().busy.store(false, Ordering::SeqCst);
    });
    Ok(format!(
        "Backed up the database and started the update to {latest}. The console reloads when the new version is up."
    ))
}

/// `pg_dump` of the whole database to PB_BACKUP_DIR, newest five kept.
async fn backup() -> std::result::Result<PathBuf, String> {
    let url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is not set".to_string())?;
    let dir = backup_dir();
    tokio::fs::create_dir_all(&dir).await.map_err(|e| e.to_string())?;
    let name = format!(
        "pre-update-{}-{}.sql.gz",
        crate::config::build_version(),
        chrono::Utc::now().format("%Y%m%d-%H%M%S")
    );
    let out = dir.join(&name);
    let status = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(r#"set -o pipefail; pg_dump --no-owner --no-privileges -d "$PB_DB_URL" | gzip -1 > "$PB_OUT""#)
        // Credentials stay in the environment, not on the command line.
        .env("PB_DB_URL", url)
        .env("PB_OUT", &out)
        .status()
        .await
        .map_err(|e| format!("couldn't run pg_dump: {e}"))?;
    let size = tokio::fs::metadata(&out).await.map(|m| m.len()).unwrap_or(0);
    if !status.success() || size < 1024 {
        let _ = tokio::fs::remove_file(&out).await;
        return Err(format!("pg_dump exited with {status}"));
    }
    prune_backups(&dir).await;
    info!(file = %name, bytes = size, "database backed up before server update");
    Ok(out)
}

async fn prune_backups(dir: &Path) {
    let Ok(mut rd) = tokio::fs::read_dir(dir).await else {
        return;
    };
    let mut files = Vec::new();
    while let Ok(Some(e)) = rd.next_entry().await {
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with("pre-update-") && name.ends_with(".sql.gz") {
            let modified = e.metadata().await.and_then(|m| m.modified()).ok();
            files.push((modified, e.path()));
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, path) in files.into_iter().skip(KEEP_BACKUPS) {
        let _ = tokio::fs::remove_file(path).await;
    }
}

/// With Auto-update on, apply a newer release once no server-side stream is
/// open (checked every 30 minutes; GitHub itself is checked by `updates`).
pub fn spawn_auto(http: reqwest::Client, streams: std::sync::Arc<crate::stream::StreamService>) {
    if watchtower_url().is_none() {
        return;
    }
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5 * 60)).await;
        loop {
            let st = status().await;
            if st.auto && st.managed && st.update_available && !st.busy {
                let latest = st.latest.clone().unwrap_or_default();
                let recently = state()
                    .last_auto
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .as_ref()
                    .is_some_and(|(v, at)| *v == latest && at.elapsed() < AUTO_RETRY);
                if !recently && streams.active_sessions().await == 0 {
                    *state().last_auto.lock().unwrap_or_else(|e| e.into_inner()) =
                        Some((latest.clone(), Instant::now()));
                    info!(%latest, "auto-update: updating the server");
                    if let Err(e) = update_now(&http).await {
                        warn!(error = %e, "auto-update failed");
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(30 * 60)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::is_newer;

    #[test]
    fn compares_versions() {
        assert!(is_newer("v0.3.0", "0.2.0"));
        assert!(is_newer("v0.2.1", "0.2.0"));
        assert!(is_newer("v1.0.0", "0.9.9"));
        assert!(!is_newer("v0.2.0", "0.2.0"));
        assert!(!is_newer("v0.1.9", "0.2.0"));
        assert!(is_newer("v0.3.0", "0.3.0-rc1"));
        assert!(!is_newer("v0.3.0-rc1", "0.3.0"));
        assert!(!is_newer("garbage", "0.2.0"));
    }
}
