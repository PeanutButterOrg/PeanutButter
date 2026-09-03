use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Form;
use serde::Deserialize;
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
    let mut response = Redirect::to("/").into_response();
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

pub async fn page(
    ConnectInfo(_addr): ConnectInfo<SocketAddr>,
    State(state): State<HttpState>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let authed = session_ok(&state, &headers).await;
    let notice = cookie_value(&headers, "pb_flash").map(|s| decode_flash(&s));
    let highlight = cookie_value(&headers, "pb_pin");
    let html = render(
        &state,
        authed,
        notice.as_deref().filter(|s| !s.is_empty()),
        highlight.as_deref().filter(|s| !s.is_empty()),
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
        let html = render(&state, false, Some("Sign in to continue."), None).await?;
        return Ok((StatusCode::UNAUTHORIZED, Html(html)).into_response());
    }

    let mut notice: Option<String> = None;
    let mut highlight: Option<String> = None;
    match form.action.as_str() {
        "create" => {
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
            if let Some(id) = form.id.as_deref().and_then(|s| Uuid::parse_str(s).ok()) {
                crate::db::revoke_device_token(&state.app.pool, id).await?;
                state.app.gql_cache.invalidate();
                notice = Some("Device removed. That pairing code no longer works.".into());
            }
        }
        "save_jackett" => {
            notice = Some(save_jackett(&state, &form).await?);
        }
        "test_jackett" => {
            notice = Some(test_jackett(&state, &form).await);
        }
        "set_password" => {
            let next = form.new_password.as_deref().unwrap_or("").trim();
            if next.len() < 8 {
                notice = Some("Choose a password of at least 8 characters.".into());
            } else {
                crate::db::set_admin_password(&state.app.pool, next).await?;
                let hash = crate::db::admin_password_hash(&state.app.pool)
                    .await?
                    .unwrap_or_default();
                let mut response = redirect_console(
                    Some("Password updated. Stay signed in on this browser."),
                    None,
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

    Ok(redirect_console(notice.as_deref(), highlight.as_deref()))
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
    )
    .await?;
    state.app.config.live.apply_streaming(
        Some(enabled),
        jackett_url.map(Some),
        key.map(|s| Some(s.to_string())),
        resolution.map(ToOwned::to_owned),
    );
    state.app.gql_cache.invalidate();
    if enabled && state.app.config.live.jackett_configured() {
        Ok("Jackett saved. Every TV and desktop will use this server.".into())
    } else if enabled {
        Ok("Jackett is on, but it still needs a URL and API key.".into())
    } else {
        Ok("Jackett turned off for all devices.".into())
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
        dashboard(state, &notice_html, highlight).await?
    };

    Ok(shell(if authed { "Console" } else { "Sign in" }, &body, authed))
}

async fn dashboard(
    state: &HttpState,
    notice_html: &str,
    highlight: Option<&str>,
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

        <section class="panel">
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
            <div class="actions">
              <button type="submit" name="action" value="save_jackett">Save Jackett</button>
              <button type="submit" class="ghost" name="action" value="test_jackett">Test connection</button>
            </div>
          </form>
        </section>

        <section class="panel">
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

        <section class="panel">
          <h2>Console password</h2>
          <form method="post" action="/" class="inline">
            <input type="hidden" name="action" value="set_password" />
            <label>New password
              <input name="new_password" type="password" minlength="8" autocomplete="new-password" required />
            </label>
            <button type="submit">Update password</button>
          </form>
        </section>

        <section class="panel">
          <h2>Danger zone</h2>
          <p class="lead">Wipe every movie, series, and anime from this server. Device pairing codes and Jackett settings stay. Metadata will rebuild on the next sync.</p>
          <form method="post" action="/" onsubmit="return confirm('Clear the entire catalog on this server?\n\nThis removes all titles, listings, and progress. Device codes and Jackett settings are kept.\n\nThis cannot be undone.');">
            <input type="hidden" name="action" value="clear_catalog" />
            <button class="ghost danger" type="submit">Clear catalog</button>
          </form>
        </section>
        "#,
        notice_html = notice_html,
        status = status,
        checked = if jackett_on { "checked" } else { "" },
        url = html_escape(&jackett_url),
        key_ph = if jackett_ok {
            "Configured — paste to replace"
        } else {
            "Jackett API key"
        },
        res_opts = res_opts,
        cards = cards,
    ))
}

fn shell(title: &str, body: &str, authed: bool) -> String {
    let width = if authed { "980px" } else { "440px" };
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
  .top {{ display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; margin-bottom: 1.4rem; }}
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
  button.ghost {{ background: transparent; color: var(--ink); border: 1px solid var(--line); }}
  button.ghost.danger {{ color: var(--danger); border-color: #ff8a8033; }}
  button.danger {{ color: var(--danger); border-color: #ff8a8033; }}
  .actions {{ display: flex; flex-wrap: wrap; gap: 0.55rem; }}
  .grid {{ display: grid; gap: 0.9rem; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); margin-top: 1rem; }}
  .card {{ display: grid; gap: 0.7rem; padding: 1rem 1.05rem; border-radius: 14px; border: 1px solid var(--line); background: #0e0e12; }}
  .card.hot {{ border-color: var(--accent); }}
  .pin {{ font: 700 1.7rem/1 "Fraunces", Georgia, serif; letter-spacing: 0.16em; }}
  @media (max-width: 640px) {{
    form.inline {{ grid-template-columns: 1fr; }}
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
