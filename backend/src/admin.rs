use axum::extract::{ConnectInfo, Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Json;
use axum::Form;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use uuid::Uuid;

use crate::error::AppError;
use crate::HttpState;

#[derive(Deserialize, Default)]
pub struct AdminForm {
    #[serde(default)]
    pub action: String,
    pub password: Option<String>,
    pub name: Option<String>,
    pub id: Option<String>,
    pub jackett_enabled: Option<String>,
    pub jackett_url: Option<String>,
    pub jackett_api_key: Option<String>,
    pub streaming_resolution: Option<String>,
    pub new_password: Option<String>,
    pub tmdb_api_key: Option<String>,
    pub omdb_api_key: Option<String>,
    /// Language checkboxes use unique names (`lang_en`, `lang_hi`, …) so
    /// `serde_urlencoded` does not reject repeated `preferred_languages` keys.
    #[serde(flatten, default)]
    pub extras: HashMap<String, String>,
}

impl AdminForm {
    fn preferred_language_codes(&self) -> Vec<String> {
        let mut codes: Vec<String> = self
            .extras
            .iter()
            .filter_map(|(key, value)| {
                let code = key.strip_prefix("lang_")?;
                if code.is_empty() {
                    return None;
                }
                let value = value.trim();
                if value.is_empty() {
                    None
                } else if value.eq_ignore_ascii_case("on") {
                    Some(code.to_ascii_lowercase())
                } else {
                    Some(value.to_ascii_lowercase())
                }
            })
            .collect();
        codes.sort();
        codes.dedup();
        codes
    }

    /// Catalog multi-select: checkboxes named `sel_<uuid>`.
    fn selected_title_ids(&self) -> Vec<Uuid> {
        let mut ids: Vec<Uuid> = self
            .extras
            .iter()
            .filter_map(|(key, value)| {
                let raw = key.strip_prefix("sel_")?;
                let value = value.trim();
                if value.is_empty() {
                    return None;
                }
                Uuid::parse_str(raw).ok()
            })
            .collect();
        if let Some(id) = self.id.as_deref().and_then(|s| Uuid::parse_str(s.trim()).ok()) {
            ids.push(id);
        }
        ids.sort();
        ids.dedup();
        ids
    }
}

#[derive(Deserialize, Default)]
pub struct TabQuery {
    #[serde(default)]
    pub tab: String,
    #[serde(default)]
    pub q: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub page: Option<i64>,
}

fn cookie_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers.get(header::COOKIE).and_then(|v| v.to_str().ok()).and_then(|cookie| {
        cookie.split(';').find_map(|part| {
            let part = part.trim();
            part.strip_prefix(&format!("{name}="))
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
        })
    })
}

pub async fn has_session(state: &HttpState, headers: &HeaderMap) -> bool {
    session_ok(state, headers).await
}

async fn session_ok(state: &HttpState, headers: &HeaderMap) -> bool {
    let Some(cookie) = cookie_value(headers, "pb_sess") else {
        return false;
    };
    let Ok(Some(hash)) = crate::db::admin_password_hash(&state.app.pool).await else {
        return false;
    };
    crate::auth::token_matches(&cookie, &crate::db::admin_session_token(&hash))
}

fn session_cookie(token: &str) -> String {
    format!("pb_sess={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000")
}

fn clear_session_cookie() -> String {
    "pb_sess=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0".into()
}

fn cookie_set(name: &str, value: &str, max_age: i32) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{name}={value}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}"
    ))
    .unwrap_or_else(|_| HeaderValue::from_static("pb_flash=; Path=/; Max-Age=0"))
}

fn encode_flash(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b' ' => {
                if b == b' ' {
                    "+".into()
                } else {
                    (b as char).to_string()
                }
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn decode_flash(s: &str) -> String {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
                if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    out.push(v);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn redirect_console(notice: Option<&str>, highlight: Option<&str>) -> Response {
    redirect_console_tab(notice, highlight, None)
}

fn redirect_console_tab(notice: Option<&str>, highlight: Option<&str>, tab: Option<&str>) -> Response {
    let path = match tab {
        Some("sync") => "/?tab=sync",
        Some("devices") => "/?tab=devices",
        Some("settings") => "/?tab=settings",
        Some("catalog") => "/?tab=catalog",
        _ => "/",
    };
    let mut response = Redirect::to(path).into_response();
    let headers = response.headers_mut();
    if let Some(n) = notice.filter(|s| !s.is_empty()) {
        headers.append(header::SET_COOKIE, cookie_set("pb_flash", &encode_flash(n), 20));
    } else {
        headers.append(header::SET_COOKIE, cookie_set("pb_flash", "", 0));
    }
    if let Some(pin) = highlight.filter(|s| !s.is_empty()) {
        headers.append(
            header::SET_COOKIE,
            cookie_set("pb_pin", &crate::pin::normalize_code(pin), 20),
        );
    } else {
        headers.append(header::SET_COOKIE, cookie_set("pb_pin", "", 0));
    }
    response
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn urlencoding_minimal(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' => (b as char).to_string(),
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

pub async fn page(
    ConnectInfo(_addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    headers: HeaderMap,
    Query(q): Query<TabQuery>,
) -> Result<Response, AppError> {
    let authed = session_ok(&state, &headers).await;
    let notice = cookie_value(&headers, "pb_flash").map(|s| decode_flash(&s));
    let highlight = cookie_value(&headers, "pb_pin");
    let tab = match q.tab.as_str() {
        "sync" | "devices" | "settings" | "catalog" => q.tab.as_str(),
        _ => "streaming",
    };
    let html = render(
        &state,
        authed,
        notice.as_deref().filter(|s| !s.is_empty()),
        highlight.as_deref().filter(|s| !s.is_empty()),
        tab,
        &q,
    )
    .await?;
    let mut response = Html(html).into_response();
    response
        .headers_mut()
        .append(header::SET_COOKIE, cookie_set("pb_flash", "", 0));
    response
        .headers_mut()
        .append(header::SET_COOKIE, cookie_set("pb_pin", "", 0));
    Ok(response)
}

#[derive(Serialize)]
pub struct SyncStatusJson {
    pub syncing: bool,
    pub phase: Option<String>,
    pub progress_done: i32,
    pub progress_total: i32,
    pub percent: i32,
    pub workers_active: i32,
    pub total_titles: i32,
    pub last_sync_at: Option<String>,
    pub last_error: Option<String>,
    pub movies: i64,
    pub series: i64,
    pub anime: i64,
}

pub async fn sync_status(
    State(state): State<HttpState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if !session_ok(&state, &headers).await {
        return Ok(StatusCode::UNAUTHORIZED.into_response());
    }
    Ok(Json(build_sync_status_json(&state).await?).into_response())
}

#[derive(Serialize)]
pub struct SyncLogJson {
    pub at: String,
    pub level: String,
    pub phase: Option<String>,
    pub message: String,
}

/// GET /sync/logs — recent sync event lines for the console Sync tab.
pub async fn sync_logs(
    State(state): State<HttpState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if !session_ok(&state, &headers).await {
        return Ok(StatusCode::UNAUTHORIZED.into_response());
    }
    let rows = crate::db::list_sync_logs(&state.app.pool, 120).await?;
    let logs: Vec<SyncLogJson> = rows
        .into_iter()
        .map(|(at, level, phase, message)| SyncLogJson {
            at: at.to_rfc3339(),
            level,
            phase,
            message,
        })
        .collect();
    Ok(Json(serde_json::json!({ "logs": logs })).into_response())
}

#[derive(Deserialize, Default)]
pub struct SyncStartBody {
    /// When true, clear a stuck sync flag and start again.
    #[serde(default)]
    pub force: bool,
}

#[derive(Serialize)]
pub struct SyncActionJson {
    pub ok: bool,
    pub started: bool,
    pub message: String,
    pub status: SyncStatusJson,
}

async fn build_sync_status_json(state: &HttpState) -> Result<SyncStatusJson, AppError> {
    let mut row = crate::db::sync_state(&state.app.pool).await?;
    let atomic = state
        .app
        .syncing
        .load(std::sync::atomic::Ordering::Relaxed);
    // Heal orphaned DB flag left behind when the process restarted mid-sync.
    if row.syncing && !atomic {
        let _ = sqlx::query(
            r#"
            UPDATE sync_state SET
                syncing = FALSE,
                workers_active = 0,
                phase = COALESCE(phase, 'Interrupted'),
                last_error = COALESCE(last_error, 'Previous sync was interrupted (server restarted). Tap Force sync.')
            WHERE id = 1 AND syncing = TRUE
            "#,
        )
        .execute(&state.app.pool)
        .await;
        row.syncing = false;
        row.workers_active = 0;
    }
    let syncing = atomic || row.syncing;
    let percent = if row.progress_total > 0 {
        ((row.progress_done as f64 / row.progress_total as f64) * 100.0).round() as i32
    } else if syncing {
        0
    } else if row.phase.as_deref() == Some("Done") {
        100
    } else {
        0
    };
    let movies = crate::db::title_count_for_kind(&state.app.pool, "movie")
        .await
        .unwrap_or(0);
    let series = crate::db::title_count_for_kind(&state.app.pool, "series")
        .await
        .unwrap_or(0);
    let anime = crate::db::title_count_for_kind(&state.app.pool, "anime")
        .await
        .unwrap_or(0);
    Ok(SyncStatusJson {
        syncing,
        phase: row.phase,
        progress_done: row.progress_done,
        progress_total: row.progress_total,
        percent: percent.clamp(0, 100),
        workers_active: if syncing { row.workers_active } else { 0 },
        total_titles: row.total_titles,
        last_sync_at: row.last_sync_at.map(|t| t.to_rfc3339()),
        last_error: row.last_error,
        movies,
        series,
        anime,
    })
}

fn spawn_catalog_sync(state: &HttpState) {
    let ingest = crate::ingest::IngestContext::from(&state.app);
    crate::ingest::spawn_full_sync(ingest);
}

/// POST /sync/start — start catalog sync (JSON). Use force=true to unstick a hung sync.
pub async fn sync_start(
    State(state): State<HttpState>,
    headers: HeaderMap,
    body: Result<Json<SyncStartBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, AppError> {
    if !session_ok(&state, &headers).await {
        return Ok(StatusCode::UNAUTHORIZED.into_response());
    }
    let force = body.ok().map(|Json(b)| b.force).unwrap_or(false);
    let already = state
        .app
        .syncing
        .load(std::sync::atomic::Ordering::Relaxed);
    if already && !force {
        let status = build_sync_status_json(&state).await?;
        return Ok(Json(SyncActionJson {
            ok: true,
            started: false,
            message: "Catalog sync is already running.".into(),
            status,
        })
        .into_response());
    }
    if force {
        // Always clear both the in-memory lock and any orphaned DB flag.
        state
            .app
            .syncing
            .store(false, std::sync::atomic::Ordering::SeqCst);
        let _ = sqlx::query(
            r#"
            UPDATE sync_state SET
                syncing = FALSE,
                phase = 'Restarting',
                progress_done = 0,
                progress_total = 100,
                workers_active = 0,
                last_error = NULL
            WHERE id = 1
            "#,
        )
        .execute(&state.app.pool)
        .await;
        let _ = crate::db::append_sync_log(
            &state.app.pool,
            "warn",
            Some("Restarting".into()),
            "Unstick requested — starting a fresh sync",
        )
        .await;
    }
    if state.app.config.tmdb_key().is_empty() {
        let status = build_sync_status_json(&state).await?;
        return Ok(Json(SyncActionJson {
            ok: false,
            started: false,
            message: "Add a TMDB API key in Settings before syncing.".into(),
            status,
        })
        .into_response());
    }
    let _ = crate::db::set_sync_progress(&state.app.pool, "Starting", 0, 100).await;
    spawn_catalog_sync(&state);
    // Give the worker a tick to flip the atomic + DB flag.
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
    let status = build_sync_status_json(&state).await?;
    Ok(Json(SyncActionJson {
        ok: true,
        started: true,
        message: "Catalog sync started. Watch progress and logs on this tab.".into(),
        status,
    })
    .into_response())
}

/// POST /sync/flush — wipe catalog titles and start a fresh sync (non-blocking).
pub async fn sync_flush(
    State(state): State<HttpState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if !session_ok(&state, &headers).await {
        return Ok(StatusCode::UNAUTHORIZED.into_response());
    }
    state
        .app
        .syncing
        .store(false, std::sync::atomic::Ordering::SeqCst);
    state
        .app
        .jackett_syncing
        .store(false, std::sync::atomic::Ordering::SeqCst);
    let removed = crate::db::clear_catalog(&state.app.pool).await?;
    if let Err(e) = state.app.search.clear_all().await {
        tracing::warn!(error = %e, "could not clear search index after catalog flush");
    }
    state.app.gql_cache.invalidate();
    if state.app.config.tmdb_key().is_empty() {
        let status = build_sync_status_json(&state).await?;
        return Ok(Json(SyncActionJson {
            ok: true,
            started: false,
            message: format!(
                "Flushed {removed} titles. Add a TMDB API key in Settings, then Force sync."
            ),
            status,
        })
        .into_response());
    }
    let _ = crate::db::set_sync_progress(&state.app.pool, "Flush complete · starting", 0, 100).await;
    spawn_catalog_sync(&state);
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
    let status = build_sync_status_json(&state).await?;
    Ok(Json(SyncActionJson {
        ok: true,
        started: true,
        message: format!(
            "Flushed {removed} titles. Fresh sync started — devices stay paired."
        ),
        status,
    })
    .into_response())
}

pub async fn action(
    ConnectInfo(_addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    headers: HeaderMap,
    Form(form): Form<AdminForm>,
) -> Result<Response, AppError> {
    match form.action.as_str() {
        "login" => return login(&state, &form).await,
        "logout" => return logout(&state).await,
        _ => {}
    }

    if !session_ok(&state, &headers).await {
        let html = render(
            &state,
            false,
            Some("Sign in to continue."),
            None,
            "streaming",
            &TabQuery::default(),
        )
        .await?;
        return Ok((StatusCode::UNAUTHORIZED, Html(html)).into_response());
    }

    let mut notice: Option<String> = None;
    let mut highlight: Option<String> = None;
    let mut tab: Option<&str> = None;
    match form.action.as_str() {
        "create" => {
            tab = Some("devices");
            let name = form
                .name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("Device");
            let row = crate::db::create_device_token(&state.app.pool, name).await?;
            highlight = Some(row.token.clone());
            notice = Some(format!(
                "{} is ready. Type {} in the app under Settings.",
                row.name,
                crate::pin::format_code(&row.token)
            ));
        }
        "revoke" => {
            tab = Some("devices");
            if let Some(id) = form.id.as_deref().and_then(|s| Uuid::parse_str(s).ok()) {
                crate::db::revoke_device_token(&state.app.pool, id).await?;
                state.app.gql_cache.invalidate();
                notice = Some("Device removed. That pairing code no longer works.".into());
            }
        }
        "delete_title" => {
            tab = Some("catalog");
            if let Some(id) = form.id.as_deref().and_then(|s| Uuid::parse_str(s).ok()) {
                let removed = crate::db::delete_title_by_id(&state.app.pool, id).await?;
                if removed {
                    let _ = state.app.search.delete_title(id).await;
                    state.app.gql_cache.invalidate();
                    notice = Some("Title removed from the catalog.".into());
                } else {
                    notice = Some("That title was already gone.".into());
                }
            }
        }
        "delete_titles" => {
            tab = Some("catalog");
            let ids = form.selected_title_ids();
            if ids.is_empty() {
                notice = Some("Select at least one title to remove.".into());
            } else {
                let mut removed = 0usize;
                for id in &ids {
                    if crate::db::delete_title_by_id(&state.app.pool, *id).await? {
                        let _ = state.app.search.delete_title(*id).await;
                        removed += 1;
                    }
                }
                if removed > 0 {
                    state.app.gql_cache.invalidate();
                }
                notice = Some(if removed == 1 {
                    "1 title removed from the catalog.".into()
                } else {
                    format!("{removed} titles removed from the catalog.")
                });
            }
        }
        "save_jackett" => {
            notice = Some(save_jackett(&state, &form).await?);
        }
        "test_jackett" => {
            notice = Some(test_jackett(&state, &form).await);
        }
        "force_sync" => {
            tab = Some("sync");
            if state
                .app
                .syncing
                .load(std::sync::atomic::Ordering::Relaxed)
            {
                notice = Some("Catalog sync is already running.".into());
            } else {
                let ingest = crate::ingest::IngestContext::from(&state.app);
                crate::ingest::spawn_full_sync(ingest);
                notice = Some("Catalog sync started. Watch progress and logs on this tab.".into());
            }
        }
        "save_metadata_keys" => {
            tab = Some("settings");
            let tmdb = form
                .tmdb_api_key
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let omdb = form
                .omdb_api_key
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            if tmdb.is_none() && omdb.is_none() {
                notice = Some("Paste a TMDB and/or OMDb key to save.".into());
            } else {
                crate::db::save_settings(
                    &state.app.pool,
                    tmdb,
                    omdb,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                )
                .await?;
                state.app.config.live.apply(
                    tmdb.map(|s| s.to_string()),
                    omdb.map(|s| s.to_string()),
                    None,
                    None,
                );
                // Kick cast/trailer enrich right away when TMDB is set.
                if tmdb.is_some() || !state.app.config.tmdb_key().is_empty() {
                    let ingest = crate::ingest::IngestContext::from(&state.app);
                    tokio::spawn(async move {
                        if let Err(e) = crate::ingest::tmdb::enrich_missing_from_imdb(&ingest).await {
                            tracing::warn!(error = %e, "TMDB enrich after key save failed");
                        }
                    });
                }
                notice = Some(
                    "Metadata keys saved. Cast & trailers will fill in as TMDB enrichment runs."
                        .into(),
                );
            }
        }
        "set_password" => {
            tab = Some("settings");
            let next = form.new_password.as_deref().unwrap_or("").trim();
            if next.len() < 8 {
                notice = Some("Choose a password of at least 8 characters.".into());
            } else {
                crate::db::set_admin_password(&state.app.pool, next).await?;
                let hash = crate::db::admin_password_hash(&state.app.pool)
                    .await?
                    .unwrap_or_default();
                let mut response = redirect_console_tab(
                    Some("Password updated. Stay signed in on this browser."),
                    None,
                    Some("settings"),
                );
                response.headers_mut().append(
                    header::SET_COOKIE,
                    session_cookie(&crate::db::admin_session_token(&hash))
                        .parse()
                        .unwrap(),
                );
                return Ok(response);
            }
        }
        "clear_catalog" => {
            tab = Some("settings");
            state
                .app
                .syncing
                .store(false, std::sync::atomic::Ordering::Relaxed);
            state
                .app
                .jackett_syncing
                .store(false, std::sync::atomic::Ordering::Relaxed);
            let removed = crate::db::clear_catalog(&state.app.pool).await?;
            if let Err(e) = state.app.search.clear_all().await {
                tracing::warn!(error = %e, "could not clear search index after catalog wipe");
            }
            state.app.gql_cache.invalidate();
            notice = Some(format!(
                "Catalog cleared ({removed} titles removed). Jackett settings and device codes were kept."
            ));
        }
        _ => {}
    }

    Ok(redirect_console_tab(notice.as_deref(), highlight.as_deref(), tab))
}

async fn login(state: &HttpState, form: &AdminForm) -> Result<Response, AppError> {
    let password = form.password.as_deref().unwrap_or("").trim();
    let stored = crate::db::admin_password_hash(&state.app.pool).await?;
    let ok = stored
        .as_deref()
        .is_some_and(|hash| crate::db::admin_password_matches(password, hash));
    if !ok {
        let html = render(
            state,
            false,
            Some("That password is not correct."),
            None,
            "streaming",
            &TabQuery::default(),
        )
        .await?;
        return Ok((StatusCode::UNAUTHORIZED, Html(html)).into_response());
    }
    let token = crate::db::admin_session_token(stored.as_deref().unwrap());
    let mut response = redirect_console(Some("Signed in."), None);
    response
        .headers_mut()
        .append(header::SET_COOKIE, session_cookie(&token).parse().unwrap());
    Ok(response)
}

async fn logout(_state: &HttpState) -> Result<Response, AppError> {
    let mut response = redirect_console(Some("Signed out."), None);
    response
        .headers_mut()
        .append(header::SET_COOKIE, clear_session_cookie().parse().unwrap());
    Ok(response)
}

async fn save_jackett(state: &HttpState, form: &AdminForm) -> Result<String, AppError> {
    let enabled = form.jackett_enabled.as_deref() == Some("on")
        || form.jackett_enabled.as_deref() == Some("true");
    let typed_url = form
        .jackett_url
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let jackett_url = match typed_url {
        Some(raw) => Some(crate::jackett::normalize_jackett_url(raw)?),
        None => None,
    };
    let key = form
        .jackett_api_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let resolution = form
        .streaming_resolution
        .as_deref()
        .filter(|s| matches!(*s, "2160p" | "1080p" | "720p" | "480p"));
    let langs = crate::config::normalize_language_list(&form.preferred_language_codes().join(","));
    crate::db::save_settings(
        &state.app.pool,
        None,
        None,
        None,
        None,
        Some(enabled),
        jackett_url.as_deref(),
        key,
        resolution,
        None,
        None,
        Some(langs.as_str()),
    )
    .await?;
    state.app.config.live.apply_streaming(
        Some(enabled),
        jackett_url.map(Some),
        key.map(|s| Some(s.to_string())),
        resolution.map(ToOwned::to_owned),
        Some(langs),
    );
    state.app.gql_cache.invalidate();
    if enabled && state.app.config.live.jackett_configured() {
        Ok("Jackett and content languages saved for all devices.".into())
    } else if enabled {
        Ok("Saved. Jackett still needs a URL and API key.".into())
    } else {
        Ok("Saved content languages. Jackett is off for all devices.".into())
    }
}

async fn test_jackett(state: &HttpState, form: &AdminForm) -> String {
    let url = form
        .jackett_url
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| state.app.config.live.jackett_url());
    let key = form
        .jackett_api_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| state.app.config.live.jackett_api_key());
    let (Some(url), Some(key)) = (url, key) else {
        return "Add a Jackett URL and API key first.".into();
    };
    let url = match crate::jackett::normalize_jackett_url(&url) {
        Ok(u) => u,
        Err(e) => return e.to_string(),
    };
    let client = crate::jackett::JackettClient::new(state.app.http.clone(), url, key);
    match client.test_connection().await {
        Ok(true) => "Connected to Jackett.".into(),
        Ok(false) => "Jackett did not respond. Check the URL.".into(),
        Err(e) => e.to_string(),
    }
}

async fn render(
    state: &HttpState,
    authed: bool,
    notice: Option<&str>,
    highlight: Option<&str>,
    tab: &str,
    query: &TabQuery,
) -> Result<String, AppError> {
    let notice_html = notice
        .map(|n| format!(r#"<p class="banner">{}</p>"#, html_escape(n)))
        .unwrap_or_default();

    let body = if !authed {
        format!(
            r#"
            {notice_html}
            <section class="panel login">
              <p class="brand">PeanutButter</p>
              <h1>Server console</h1>
              <p class="lead">Sign in to manage Jackett and pairing codes. Apps on TVs and desktops use a 6-digit code, not this password.</p>
              <form method="post" action="/" class="stack">
                <input type="hidden" name="action" value="login" />
                <label>Password
                  <input name="password" type="password" autocomplete="current-password" required autofocus />
                </label>
                <button type="submit">Continue</button>
              </form>
            </section>
            "#
        )
    } else {
        dashboard(state, &notice_html, highlight, tab, query).await?
    };

    Ok(shell(
        if authed { "Console" } else { "Sign in" },
        &body,
        authed,
        tab == "catalog",
    ))
}

async fn dashboard(
    state: &HttpState,
    notice_html: &str,
    highlight: Option<&str>,
    tab: &str,
    query: &TabQuery,
) -> Result<String, AppError> {
    let tokens = crate::db::list_device_tokens(&state.app.pool).await?;
    let live = &state.app.config.live;
    let jackett_on = live.jackett_enabled();
    let jackett_ok = live.jackett_configured();
    let jackett_url = live.jackett_url().unwrap_or_default();
    let resolution = live.streaming_resolution();
    let status = if jackett_ok {
        "<span class=\"pill ok\">Ready</span>"
    } else if jackett_on {
        "<span class=\"pill warn\">Needs key</span>"
    } else {
        "<span class=\"pill\">Off</span>"
    };

    let mut cards = String::new();
    for t in &tokens {
        let pin = crate::pin::format_code(&t.token);
        let created = t.created_at.format("%Y-%m-%d").to_string();
        let hot = highlight.is_some_and(|h| crate::pin::codes_equal(h, &t.token));
        cards.push_str(&format!(
            r#"<article class="card{hot}">
              <div>
                <h3>{}</h3>
                <p class="muted">Added {created}</p>
              </div>
              <div class="pin">{}</div>
              <form method="post" action="/" onsubmit="return confirm('Remove this device?');">
                <input type="hidden" name="action" value="revoke" />
                <input type="hidden" name="id" value="{}" />
                <button type="submit" class="ghost danger">Remove</button>
              </form>
            </article>"#,
            html_escape(&t.name),
            html_escape(&pin),
            t.id,
            hot = if hot { " hot" } else { "" },
            created = created,
        ));
    }

    let res_opts = ["2160p", "1080p", "720p", "480p"]
        .into_iter()
        .map(|r| {
            let sel = if r == resolution { " selected" } else { "" };
            let label = if r == "2160p" { "4K" } else { r };
            format!(r#"<option value="{r}"{sel}>{label}</option>"#)
        })
        .collect::<String>();
    let selected_langs = live.preferred_language_codes();
    let lang_opts = [
        ("en", "English"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("hi", "Hindi"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ar", "Arabic"),
        ("tr", "Turkish"),
        ("ru", "Russian"),
        ("th", "Thai"),
        ("id", "Indonesian"),
    ]
    .into_iter()
    .map(|(code, label)| {
        let checked = if selected_langs.iter().any(|c| c == code) {
            " checked"
        } else {
            ""
        };
        format!(
            r#"<label class="check{on}"><input type="checkbox" name="lang_{code}" value="{code}"{checked} /> {label}</label>"#,
            on = if selected_langs.iter().any(|c| c == code) {
                " on"
            } else {
                ""
            },
        )
    })
    .collect::<String>();
    let langs_hint = if selected_langs.is_empty() {
        "All languages (none selected)".to_string()
    } else {
        selected_langs
            .iter()
            .map(|code| match code.as_str() {
                "en" => "English",
                "ja" => "Japanese",
                "ko" => "Korean",
                "zh" => "Chinese",
                "hi" => "Hindi",
                "es" => "Spanish",
                "fr" => "French",
                "de" => "German",
                "it" => "Italian",
                "pt" => "Portuguese",
                "ar" => "Arabic",
                "tr" => "Turkish",
                "ru" => "Russian",
                "th" => "Thai",
                "id" => "Indonesian",
                other => other,
            })
            .collect::<Vec<_>>()
            .join(", ")
    };

    fn tab_class(active: &str, name: &str) -> &'static str {
        if active == name {
            "tab on"
        } else {
            "tab"
        }
    }
    let sync_on = tab == "sync";
    let panel_streaming = if tab == "streaming" { "" } else { " hidden" };
    let panel_devices = if tab == "devices" { "" } else { " hidden" };
    let panel_catalog = if tab == "catalog" { "" } else { " hidden" };
    let panel_sync = if sync_on { "" } else { " hidden" };
    let panel_settings = if tab == "settings" { "" } else { " hidden" };

    let catalog_q = query.q.trim();
    let catalog_kind = query.kind.trim().to_ascii_uppercase();
    let catalog_kind = match catalog_kind.as_str() {
        "MOVIE" | "SERIES" | "ANIME" => catalog_kind,
        _ => String::new(),
    };
    let per_page: i64 = 50;
    let catalog_page = query.page.unwrap_or(1).max(1);
    let catalog_offset = (catalog_page - 1) * per_page;
    let (catalog_rows, catalog_total) = if tab == "catalog" {
        crate::db::list_catalog_titles(
            &state.app.pool,
            catalog_q,
            &catalog_kind,
            per_page,
            catalog_offset,
        )
        .await?
    } else {
        (Vec::new(), 0)
    };
    let catalog_pages = ((catalog_total + per_page - 1) / per_page).max(1);
    let mut catalog_table = String::new();
    if catalog_rows.is_empty() {
        catalog_table.push_str(
            r#"<p class="muted" style="margin:1rem 0 0">No titles match this filter.</p>"#,
        );
    } else {
        catalog_table.push_str(
            r#"<form method="post" action="/" id="catalog-bulk" onsubmit="var n=document.querySelectorAll('#catalog-bulk input[name^=sel_]:checked').length; if(!n){alert('Select at least one title.');return false;} return confirm('Remove '+n+' selected title(s) from the catalog?\n\nThis deletes them from the database. Pairing and Jackett stay.');">
            <input type="hidden" name="action" value="delete_titles" />
            <div class="catalog-bulk-bar">
              <label class="check"><input type="checkbox" id="catalog-select-all" /> Select page</label>
              <button type="submit" class="ghost danger" onclick="this.form.querySelector('input[name=action]').value='delete_titles';">Remove selected</button>
            </div>
            <table class="catalog"><thead><tr><th class="check-cell"></th><th>Title</th><th>Kind</th><th>Year</th><th></th></tr></thead><tbody>"#,
        );
        for row in &catalog_rows {
            let year = row
                .year
                .map(|y| y.to_string())
                .unwrap_or_else(|| "—".into());
            let kind_label = match row.kind.as_str() {
                "MOVIE" => "Movie",
                "SERIES" => "Series",
                "ANIME" => "Anime",
                other => other,
            };
            catalog_table.push_str(&format!(
                r#"<tr>
                  <td class="check-cell"><input type="checkbox" class="catalog-sel" name="sel_{}" value="on" /></td>
                  <td><strong>{}</strong></td>
                  <td><span class="pill">{}</span></td>
                  <td class="muted">{}</td>
                  <td class="actions-cell">
                    <button type="submit" class="ghost danger" name="id" value="{}" onclick="this.form.querySelector('input[name=action]').value='delete_title'; return confirm('Remove this title from the catalog?\n\nThis deletes it from the database. Pairing and Jackett stay.');">Remove</button>
                  </td>
                </tr>"#,
                row.id,
                html_escape(&row.title),
                html_escape(kind_label),
                html_escape(&year),
                row.id,
            ));
        }
        catalog_table.push_str(
            r#"</tbody></table></form>
            <script>
            (function(){
              var all=document.getElementById('catalog-select-all');
              if(!all) return;
              all.addEventListener('change', function(){
                document.querySelectorAll('#catalog-bulk .catalog-sel').forEach(function(cb){ cb.checked=all.checked; });
              });
            })();
            </script>"#,
        );
    }
    let kind_all = if catalog_kind.is_empty() {
        " selected"
    } else {
        ""
    };
    let kind_movie = if catalog_kind == "MOVIE" {
        " selected"
    } else {
        ""
    };
    let kind_series = if catalog_kind == "SERIES" {
        " selected"
    } else {
        ""
    };
    let kind_anime = if catalog_kind == "ANIME" {
        " selected"
    } else {
        ""
    };
    let prev_page = if catalog_page > 1 {
        format!(
            r#"<a class="tab" href="/?tab=catalog&q={}&kind={}&page={}">← Prev</a>"#,
            urlencoding_minimal(catalog_q),
            urlencoding_minimal(&catalog_kind),
            catalog_page - 1
        )
    } else {
        String::new()
    };
    let next_page = if catalog_page < catalog_pages {
        format!(
            r#"<a class="tab" href="/?tab=catalog&q={}&kind={}&page={}">Next →</a>"#,
            urlencoding_minimal(catalog_q),
            urlencoding_minimal(&catalog_kind),
            catalog_page + 1
        )
    } else {
        String::new()
    };
    let catalog_pager = format!(
        r#"<div class="catalog-pager"><span class="muted">Page {catalog_page} of {catalog_pages} · {catalog_total} titles</span><div class="actions">{prev_page}{next_page}</div></div>"#
    );

    Ok(format!(
        r#"
        {notice_html}
        <header class="top">
          <div>
            <p class="brand">PeanutButter</p>
            <h1>Server console</h1>
          </div>
          <form method="post" action="/"><input type="hidden" name="action" value="logout" /><button class="ghost" type="submit">Sign out</button></form>
        </header>

        <div class="sync-strip" id="sync-strip" hidden>
          <div class="sync-strip-meta">
            <span class="pill warn" id="strip-pill">Syncing</span>
            <strong id="strip-pct">0%</strong>
            <span id="strip-phase">…</span>
          </div>
          <div class="sync-bar strip-bar"><span id="strip-fill" style="width:0%"></span></div>
          <a class="tab" href="/?tab=sync">Open Sync</a>
        </div>

        <nav class="tabs">
          <a class="{tab_streaming}" href="/?tab=streaming">Streaming</a>
          <a class="{tab_devices}" href="/?tab=devices">Devices</a>
          <a class="{tab_catalog}" href="/?tab=catalog">Catalog</a>
          <a class="{tab_sync}" href="/?tab=sync">Sync</a>
          <a class="{tab_settings}" href="/?tab=settings">Settings</a>
        </nav>

        <section class="panel{panel_streaming}" id="panel-streaming">
          <div class="row-head">
            <h2>Streaming</h2>
            {status}
          </div>
          <p class="lead">Jackett lives on this server. Every paired device uses the same indexers — nothing to configure on the TV.</p>
          <form method="post" action="/" class="grid-form">
            <label class="check">
              <input type="checkbox" name="jackett_enabled" value="on" {checked} />
              Enable Jackett for all devices
            </label>
            <label>Jackett URL
              <input name="jackett_url" type="url" placeholder="http://127.0.0.1:9117" value="{url}" />
            </label>
            <label>API key
              <input name="jackett_api_key" type="password" autocomplete="off" placeholder="{key_ph}" />
            </label>
            <label>Preferred resolution
              <select name="streaming_resolution">{res_opts}</select>
            </label>
            <fieldset class="langs">
              <legend>Content languages</legend>
              <p class="muted">Applies to <strong>TMDB catalog</strong> (movies/series + trailers) and <strong>Jackett Play</strong>. Leave all unchecked for every language.</p>
              <p class="langs-active"><strong>Currently selected:</strong> {langs_hint}</p>
              <div class="lang-grid">{lang_opts}</div>
            </fieldset>
            <div class="actions">
              <button type="submit" name="action" value="save_jackett">Save streaming</button>
              <button type="submit" class="ghost" name="action" value="test_jackett">Test connection</button>
            </div>
          </form>
        </section>

        <section class="panel{panel_devices}" id="panel-devices">
          <h2>Devices</h2>
          <p class="lead">Each TV, phone, or desktop gets its own 6-digit code. Play history and likes stay on that device. Catalog and Jackett are shared.</p>
          <form method="post" action="/" class="inline" autocomplete="off">
            <input type="hidden" name="action" value="create" />
            <label>Device name
              <input name="name" placeholder="Living room TV" required />
            </label>
            <button type="submit">New code</button>
          </form>
          <div class="grid">{cards}</div>
        </section>

        <section class="panel{panel_catalog}" id="panel-catalog">
          <div class="row-head">
            <h2>Catalog</h2>
            <span class="pill">{catalog_total} titles</span>
          </div>
          <p class="lead">Browse every movie and series in the database. Remove bad or unwanted titles on demand — Sync can re-add popular ones later.</p>
          <form method="get" action="/" class="inline catalog-filter">
            <input type="hidden" name="tab" value="catalog" />
            <label>Search
              <input name="q" type="search" value="{catalog_q}" placeholder="Title…" />
            </label>
            <label>Kind
              <select name="kind">
                <option value=""{kind_all}>All</option>
                <option value="MOVIE"{kind_movie}>Movies</option>
                <option value="SERIES"{kind_series}>Series</option>
                <option value="ANIME"{kind_anime}>Anime</option>
              </select>
            </label>
            <button type="submit">Filter</button>
          </form>
          {catalog_table}
          {catalog_pager}
        </section>

        <section class="panel{panel_sync}" id="panel-sync">
          <div class="row-head">
            <h2>Catalog sync</h2>
            <span class="pill" id="sync-pill">…</span>
          </div>
          <p class="lead">Catalog sync is <strong>TMDB-only</strong> (≤30 requests/sec). Add a free TMDB key in Settings first. Search also pulls unsynced titles from TMDB and saves them.</p>
          <div class="sync-meter">
            <div class="sync-bar"><span id="sync-fill" style="width:0%"></span></div>
            <div class="sync-meta">
              <strong id="sync-pct">0%</strong>
              <span id="sync-phase">Idle</span>
            </div>
          </div>
          <div class="sync-stats" id="sync-stats">
            <div><span class="muted">Titles</span><strong id="stat-total">—</strong></div>
            <div><span class="muted">Movies</span><strong id="stat-movies">—</strong></div>
            <div><span class="muted">Series</span><strong id="stat-series">—</strong></div>
            <div><span class="muted">Anime</span><strong id="stat-anime">—</strong></div>
            <div><span class="muted">Workers</span><strong id="stat-workers">0</strong></div>
            <div><span class="muted">Last sync</span><strong id="stat-last">—</strong></div>
          </div>
          <p class="muted" id="sync-error" hidden></p>
          <div class="actions" style="margin-top:1rem">
            <button type="button" id="sync-btn">Force sync now</button>
            <button type="button" class="ghost" id="sync-force-btn">Unstick &amp; restart sync</button>
            <button type="button" class="ghost danger" id="sync-flush-btn">Flush DB &amp; re-sync</button>
          </div>
          <p class="muted" style="margin-top:0.6rem">Flush removes all titles then starts a clean sync. Pairing codes and Jackett stay.</p>
          <h3 style="margin:1.2rem 0 0.45rem;font-size:0.95rem">Sync log</h3>
          <pre class="sync-log" id="sync-log">Waiting for sync activity…</pre>
        </section>

        <section class="panel{panel_settings}" id="panel-settings">
          <h2>Metadata keys</h2>
          <p class="lead"><strong>TMDB is required</strong> for catalog sync, cast/crew, trailers, posters, and search. Get a free key at themoviedb.org. OMDb is optional for IMDb / Rotten Tomatoes scores.</p>
          <form method="post" action="/" class="grid-form">
            <input type="hidden" name="action" value="save_metadata_keys" />
            <label>TMDB API key
              <input name="tmdb_api_key" type="password" autocomplete="off" placeholder="{tmdb_ph}" />
            </label>
            <label>OMDb API key
              <input name="omdb_api_key" type="password" autocomplete="off" placeholder="{omdb_ph}" />
            </label>
            <div class="actions">
              <button type="submit">Save keys</button>
            </div>
          </form>
          <h2 style="margin-top:1.6rem">Console password</h2>
          <form method="post" action="/" class="inline">
            <input type="hidden" name="action" value="set_password" />
            <label>New password
              <input name="new_password" type="password" minlength="8" autocomplete="new-password" required />
            </label>
            <button type="submit">Update password</button>
          </form>
          <h2 style="margin-top:1.6rem">Danger zone</h2>
          <p class="lead">Wipe every movie, series, and anime from this server. Device pairing codes and Jackett settings stay. Metadata will rebuild on the next sync.</p>
          <form method="post" action="/" onsubmit="return confirm('Clear the entire catalog on this server?\n\nThis removes all titles, listings, and progress. Device codes and Jackett settings are kept.\n\nThis cannot be undone.');">
            <input type="hidden" name="action" value="clear_catalog" />
            <button class="ghost danger" type="submit">Clear catalog</button>
          </form>
        </section>

        <script>
        (function () {{
          const fill = document.getElementById('sync-fill');
          const pct = document.getElementById('sync-pct');
          const phase = document.getElementById('sync-phase');
          const pill = document.getElementById('sync-pill');
          const btn = document.getElementById('sync-btn');
          const forceBtn = document.getElementById('sync-force-btn');
          const flushBtn = document.getElementById('sync-flush-btn');
          const err = document.getElementById('sync-error');
          const strip = document.getElementById('sync-strip');
          const stripFill = document.getElementById('strip-fill');
          const stripPct = document.getElementById('strip-pct');
          const stripPhase = document.getElementById('strip-phase');
          const syncLog = document.getElementById('sync-log');
          function fmtWhen(iso) {{
            if (!iso) return 'Never';
            try {{
              const d = new Date(iso);
              return d.toLocaleString();
            }} catch (_) {{ return iso; }}
          }}
          function fmtLogTime(iso) {{
            try {{
              const d = new Date(iso);
              return d.toLocaleTimeString();
            }} catch (_) {{ return iso || ''; }}
          }}
          function setText(el, text) {{ if (el) el.textContent = text; }}
          async function tickLogs() {{
            if (!syncLog) return;
            try {{
              const r = await fetch('/sync/logs', {{ credentials: 'same-origin' }});
              if (!r.ok) return;
              const data = await r.json();
              const lines = (data.logs || []).slice().reverse().map((l) => {{
                const ph = l.phase ? ('[' + l.phase + '] ') : '';
                return fmtLogTime(l.at) + '  ' + (l.level || 'info').toUpperCase().padEnd(5) + '  ' + ph + l.message;
              }});
              syncLog.textContent = lines.length ? lines.join('\\n') : 'Waiting for sync activity…';
              syncLog.scrollTop = syncLog.scrollHeight;
            }} catch (_) {{}}
          }}
          function applyStatus(s) {{
            if (!s) return;
            const p = Math.max(0, Math.min(100, s.percent || 0));
            const phaseText = s.syncing
              ? ((s.phase || 'Syncing') + (s.progress_total ? (' · ' + s.progress_done + '/' + s.progress_total) : ''))
              : (s.phase === 'Done' ? 'Done' : 'Idle');
            if (fill) fill.style.width = p + '%';
            setText(pct, p + '%');
            setText(phase, phaseText);
            if (pill) {{
              pill.textContent = s.syncing ? 'Syncing' : (s.phase === 'Done' ? 'Done' : 'Idle');
              pill.className = 'pill' + (s.syncing ? ' warn' : ' ok');
            }}
            const stat = (id, v) => {{ const el = document.getElementById(id); if (el) el.textContent = v; }};
            stat('stat-total', s.total_titles);
            stat('stat-movies', s.movies);
            stat('stat-series', s.series);
            stat('stat-anime', s.anime);
            stat('stat-workers', s.workers_active || 0);
            stat('stat-last', fmtWhen(s.last_sync_at));
            if (err) {{
              if (s.last_error) {{ err.hidden = false; err.textContent = s.last_error; }}
              else {{ err.hidden = true; err.textContent = ''; }}
            }}
            if (btn) btn.disabled = false;
            if (forceBtn) forceBtn.disabled = false;
            if (flushBtn) flushBtn.disabled = false;
            if (strip) {{
              strip.hidden = !s.syncing;
              if (s.syncing) {{
                if (stripFill) stripFill.style.width = p + '%';
                setText(stripPct, p + '%');
                setText(stripPhase, phaseText);
              }}
            }}
          }}
          async function tick() {{
            try {{
              const r = await fetch('/sync/status', {{ credentials: 'same-origin' }});
              if (!r.ok) {{
                if (err) {{ err.hidden = false; err.textContent = 'Sync status unavailable (' + r.status + '). Sign in again.'; }}
                return;
              }}
              applyStatus(await r.json());
              await tickLogs();
            }} catch (e) {{
              if (err) {{ err.hidden = false; err.textContent = 'Could not reach sync status.'; }}
            }}
          }}
          async function postSync(url, payload, confirmMsg) {{
            if (confirmMsg && !confirm(confirmMsg)) return;
            if (btn) btn.disabled = true;
            if (forceBtn) forceBtn.disabled = true;
            if (flushBtn) flushBtn.disabled = true;
            try {{
              const r = await fetch(url, {{
                method: 'POST',
                credentials: 'same-origin',
                headers: {{ 'Content-Type': 'application/json' }},
                body: JSON.stringify(payload || {{}}),
              }});
              const data = await r.json().catch(() => null);
              if (!r.ok) {{
                if (err) {{ err.hidden = false; err.textContent = 'Request failed (' + r.status + ').'; }}
                return;
              }}
              if (data && data.message && err) {{
                err.hidden = false;
                err.textContent = data.message;
              }}
              if (data && data.status) applyStatus(data.status);
              else await tick();
            }} catch (_) {{
              if (err) {{ err.hidden = false; err.textContent = 'Request failed.'; }}
            }} finally {{
              await tick();
            }}
          }}
          if (btn) btn.addEventListener('click', () => postSync('/sync/start', {{ force: true }}));
          if (forceBtn) forceBtn.addEventListener('click', () => postSync('/sync/start', {{ force: true }},
            'Restart sync even if one looks stuck?'));
          if (flushBtn) flushBtn.addEventListener('click', () => postSync('/sync/flush', {{}},
            'Flush the entire catalog and start a clean sync?\\n\\nAll titles will be removed. Pairing codes and Jackett stay.\\n\\nThis cannot be undone.'));
          tick();
          tickLogs();
          setInterval(tick, 1000);
        }})();
        </script>
        "#,
        notice_html = notice_html,
        tab_streaming = tab_class(tab, "streaming"),
        tab_devices = tab_class(tab, "devices"),
        tab_catalog = tab_class(tab, "catalog"),
        tab_sync = tab_class(tab, "sync"),
        tab_settings = tab_class(tab, "settings"),
        panel_streaming = panel_streaming,
        panel_devices = panel_devices,
        panel_catalog = panel_catalog,
        panel_sync = panel_sync,
        panel_settings = panel_settings,
        status = status,
        checked = if jackett_on { "checked" } else { "" },
        catalog_q = html_escape(catalog_q),
        catalog_total = catalog_total,
        catalog_table = catalog_table,
        catalog_pager = catalog_pager,
        kind_all = kind_all,
        kind_movie = kind_movie,
        kind_series = kind_series,
        kind_anime = kind_anime,
        url = html_escape(&jackett_url),
        key_ph = if jackett_ok {
            "Configured — paste to replace"
        } else {
            "Jackett API key"
        },
        tmdb_ph = if live.tmdb_key().trim().is_empty() {
            "Get a free key at themoviedb.org/settings/api"
        } else {
            "Configured — paste to replace"
        },
        omdb_ph = if live.omdb_key().trim().is_empty() {
            "Get a free key at omdbapi.com/apikey.aspx"
        } else {
            "Configured — paste to replace"
        },
        res_opts = res_opts,
        lang_opts = lang_opts,
        langs_hint = html_escape(&langs_hint),
        cards = cards,
    ))
}


fn shell(title: &str, body: &str, authed: bool, wide: bool) -> String {
    let width = if !authed {
        "440px"
    } else if wide {
        "1100px"
    } else {
        "980px"
    };
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>PeanutButter · {title}</title>
<style>
  :root {{
    --bg: #0e0e12;
    --card: #121218;
    --line: #ffffff18;
    --ink: #f4f6fb;
    --muted: #9aa3b5;
    --accent: #5b9fff;
    --ok: #7dd3a0;
    --warn: #e8c07a;
    --danger: #ff8a80;
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; min-height: 100%; }}
  body {{
    font: 15px/1.5 "Nunito Sans", "Segoe UI", sans-serif;
    background:
      radial-gradient(1100px 520px at 8% -8%, #5b9fff22, transparent 55%),
      radial-gradient(800px 420px at 108% 0%, #3d6fb822, transparent 50%),
      var(--bg);
    color: var(--ink);
  }}
  main {{ max-width: {width}; margin: 0 auto; padding: 2.4rem 1.25rem 4rem; }}
  .brand {{ margin: 0; font: 700 0.78rem/1 "Fraunces", Georgia, serif; letter-spacing: 0.16em; text-transform: uppercase; color: var(--accent); }}
  h1 {{ font: 600 2rem/1.15 "Fraunces", Georgia, serif; margin: 0.2rem 0 0; }}
  h2 {{ font: 600 1.15rem/1.2 "Fraunces", Georgia, serif; margin: 0; }}
  h3 {{ margin: 0; font-size: 1rem; }}
  .lead, .muted {{ color: var(--muted); }}
  .lead {{ margin: 0.45rem 0 1.1rem; max-width: 40rem; }}
  .top {{ display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; margin-bottom: 1rem; }}
  .tabs {{
    display: flex; flex-wrap: wrap; gap: 0.4rem; margin: 0 0 1.1rem;
  }}
  .tab {{
    display: inline-block; padding: 0.55rem 0.9rem; border-radius: 999px;
    border: 1px solid var(--line); color: var(--muted); text-decoration: none; font-weight: 700; font-size: 0.85rem;
  }}
  .tab.on {{ color: #081018; background: var(--accent); border-color: transparent; }}
  .hidden {{ display: none !important; }}
  .sync-strip {{
    display: grid; gap: 0.55rem; margin: 0 0 1rem; padding: 0.8rem 1rem;
    background: #e8c07a14; border: 1px solid #e8c07a44; border-radius: 14px;
  }}
  .sync-strip[hidden] {{ display: none !important; }}
  .sync-strip-meta {{ display: flex; flex-wrap: wrap; align-items: center; gap: 0.55rem; }}
  .sync-strip .strip-bar {{ height: 8px; }}
  .sync-meter {{ margin: 0.4rem 0 1rem; }}
  .sync-bar {{
    height: 12px; border-radius: 999px; background: #ffffff12; overflow: hidden; border: 1px solid var(--line);
  }}
  .sync-bar > span {{
    display: block; height: 100%; width: 0; background: linear-gradient(90deg, #3d6fb8, var(--accent));
    transition: width 0.35s ease;
  }}
  .sync-meta {{ display: flex; justify-content: space-between; gap: 1rem; margin-top: 0.55rem; color: var(--muted); }}
  .sync-meta strong {{ color: var(--ink); font-size: 1.15rem; }}
  .sync-stats {{
    display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 0.75rem;
    margin-top: 0.4rem;
  }}
  .sync-stats > div {{
    background: #0e0e12; border: 1px solid var(--line); border-radius: 12px; padding: 0.7rem 0.8rem;
    display: grid; gap: 0.2rem;
  }}
  .sync-stats strong {{ font-size: 1.05rem; }}
  .sync-log {{
    margin: 0; max-height: 280px; overflow: auto; padding: 0.85rem 1rem;
    background: #08080c; border: 1px solid var(--line); border-radius: 12px;
    color: #c8d0dc; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    white-space: pre-wrap; word-break: break-word;
  }}
  .panel {{
    background: var(--card); border: 1px solid var(--line); border-radius: 18px;
    padding: 1.25rem 1.3rem 1.35rem; margin-bottom: 1.1rem;
  }}
  .panel.login {{ margin-top: 12vh; }}
  .row-head {{ display: flex; align-items: center; gap: 0.7rem; }}
  .banner {{
    background: #5b9fff18; border: 1px solid #5b9fff33; color: var(--ink);
    padding: 0.75rem 1rem; border-radius: 12px; margin: 0 0 1rem;
  }}
  .pill {{ font-size: 0.72rem; letter-spacing: 0.04em; text-transform: uppercase; border: 1px solid var(--line); border-radius: 999px; padding: 0.2rem 0.55rem; color: var(--muted); }}
  .pill.ok {{ color: var(--ok); border-color: #7dd3a044; }}
  .pill.warn {{ color: var(--warn); border-color: #e8c07a44; }}
  form.stack, form.grid-form, form.inline {{ display: grid; gap: 0.85rem; }}
  form.inline {{ grid-template-columns: 1fr auto; align-items: end; }}
  form.grid-form {{ margin-top: 0.4rem; }}
  label {{ display: flex; flex-direction: column; gap: 0.35rem; font-size: 0.8rem; color: var(--muted); }}
  label.check {{ flex-direction: row; align-items: center; gap: 0.55rem; color: var(--ink); font-size: 0.95rem; }}
  label.check.on {{
    background: color-mix(in srgb, var(--accent) 16%, transparent);
    border: 1px solid color-mix(in srgb, var(--accent) 45%, var(--line));
    border-radius: 10px; padding: 0.35rem 0.55rem;
  }}
  fieldset.langs {{
    border: 1px solid var(--line); border-radius: 12px; padding: 0.85rem 1rem 1rem; margin: 0;
  }}
  fieldset.langs legend {{ padding: 0 0.35rem; color: var(--ink); font-size: 0.85rem; }}
  .lang-grid {{
    display: grid; gap: 0.45rem 0.75rem;
    grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
    margin-top: 0.55rem;
  }}
  .langs-active {{
    margin: 0.35rem 0 0; padding: 0.45rem 0.65rem; border-radius: 10px;
    background: #14141a; border: 1px solid var(--line); color: var(--ink); font-size: 0.9rem;
  }}
  input, select {{
    width: 100%; padding: 0.78rem 0.9rem; border: 1px solid var(--line);
    border-radius: 12px; background: #0e0e12; color: var(--ink); font: inherit;
  }}
  input[type="checkbox"] {{ width: auto; }}
  input:focus, select:focus {{ outline: 2px solid var(--accent); border-color: transparent; }}
  button {{
    padding: 0.78rem 1.05rem; border: 0; border-radius: 12px; background: var(--accent);
    color: #081018; font-weight: 700; cursor: pointer;
  }}
  button:disabled {{ opacity: 0.55; cursor: not-allowed; }}
  button.ghost {{ background: transparent; color: var(--ink); border: 1px solid var(--line); }}
  button.ghost.danger {{ color: var(--danger); border-color: #ff8a8033; }}
  button.danger {{ color: var(--danger); border-color: #ff8a8033; }}
  .actions {{ display: flex; flex-wrap: wrap; gap: 0.55rem; }}
  .grid {{ display: grid; gap: 0.9rem; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); margin-top: 1rem; }}
  .card {{ display: grid; gap: 0.7rem; padding: 1rem 1.05rem; border-radius: 14px; border: 1px solid var(--line); background: #0e0e12; }}
  .card.hot {{ border-color: var(--accent); }}
  .pin {{ font: 700 1.7rem/1 "Fraunces", Georgia, serif; letter-spacing: 0.16em; }}
  form.catalog-filter {{ margin-top: 0.2rem; grid-template-columns: 1.4fr 0.7fr auto; }}
  .catalog-bulk-bar {{
    display: flex; align-items: center; justify-content: space-between;
    gap: 0.75rem; margin: 0.85rem 0 0.35rem; flex-wrap: wrap;
  }}
  table.catalog {{
    width: 100%; border-collapse: collapse; margin-top: 0.5rem;
    font-size: 0.92rem;
  }}
  table.catalog th, table.catalog td {{
    text-align: left; padding: 0.65rem 0.55rem; border-bottom: 1px solid var(--line);
    vertical-align: middle;
  }}
  table.catalog th {{ color: var(--muted); font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.04em; }}
  table.catalog .actions-cell {{ width: 1%; white-space: nowrap; }}
  table.catalog .actions-cell form {{ margin: 0; }}
  table.catalog .check-cell {{ width: 2.1rem; text-align: center; }}
  table.catalog .check-cell input {{ width: 1rem; height: 1rem; accent-color: var(--accent); }}
  .catalog-pager {{
    display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center;
    gap: 0.75rem; margin-top: 1rem;
  }}
  @media (max-width: 640px) {{
    form.inline {{ grid-template-columns: 1fr; }}
    form.catalog-filter {{ grid-template-columns: 1fr; }}
  }}
</style>
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600;9..144,700&family=Nunito+Sans:wght@400;700&display=swap" />
</head>
<body>
<main>
{body}
</main>
</body>
</html>"#
    )
}
