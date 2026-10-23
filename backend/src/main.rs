mod admin;
mod auth;
mod cache;
mod config;
mod content_filter;
mod db;
mod error;
mod graphql;
mod ingest;
mod introdb;
mod jackett;
mod media;
mod pin;
mod ratelimit;
mod search;
mod stream;
mod subtitles;
mod providers;
mod server_update;
mod updates;

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use async_graphql::http::GraphiQLSource;
use async_graphql_axum::GraphQLRequest;
use axum::extract::State;
use axum::http::{HeaderValue, Method};
use axum::middleware;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::{Extension, Json, Router};
use serde::Serialize;
use tokio::net::TcpListener;
use tower_http::cors::{AllowOrigin, Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::cache::{GqlCache, RequestKind};
use crate::config::Config;
use crate::error::Result;
use crate::graphql::{build_schema, AppSchema};
use crate::ingest::IngestContext;
use crate::search::SearchClient;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::PgPool,
    /// Separate connections for catalog sync so TMDB ingest cannot exhaust the API pool.
    pub ingest_pool: sqlx::PgPool,
    pub search: SearchClient,
    pub config: Config,
    pub syncing: Arc<AtomicBool>,
    pub http: reqwest::Client,
    pub gql_cache: GqlCache,
    pub streams: Arc<crate::stream::StreamService>,
    pub jackett_syncing: Arc<AtomicBool>,
    pub introdb: crate::introdb::IntroDb,
}

impl From<&AppState> for IngestContext {
    fn from(state: &AppState) -> Self {
        IngestContext::new(
            state.ingest_pool.clone(),
            state.search.clone(),
            state.config.clone(),
            state.syncing.clone(),
            state.jackett_syncing.clone(),
            state.http.clone(),
        )
    }
}

#[derive(Clone)]
pub struct HttpState {
    pub app: AppState,
    pub schema: AppSchema,
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "peanutbutter=info,tower_http=info".into()),
        )
        .init();

    let config = Config::from_env()?;
    info!(version = config.version, "starting PeanutButter API");

    let pool = db::connect_api(&config.database_url).await?;
    let ingest_pool = db::connect_ingest(&config.database_url).await?;
    let migrations_dir = std::env::var("MIGRATIONS_DIR")
        .ok()
        .map(std::path::PathBuf::from);
    db::run_migrations(&pool, migrations_dir.as_deref()).await?;
    db::overlay_saved_settings(&pool, &config).await?;
    if let Err(e) = providers::load(&pool).await {
        tracing::warn!(error = %e, "could not load fallback torrent sources");
    }
    if let Err(e) = server_update::load(&pool).await {
        tracing::warn!(error = %e, "could not load the server auto-update setting");
    }
    server_update::ensure_token();
    db::ensure_app_token(&pool, &config).await?;
    db::ensure_admin_password(&pool).await?;
    info!("admin console at / — password required");

    let search = SearchClient::new(&config.meili_url, &config.meili_master_key).await?;
    let syncing = Arc::new(AtomicBool::new(false));
    let jackett_syncing = Arc::new(AtomicBool::new(false));
    let http = reqwest::Client::builder()
        .user_agent(format!("PeanutButter/{}", config.version))
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()?;

    let app_state = AppState {
        pool: pool.clone(),
        ingest_pool: ingest_pool.clone(),
        search: search.clone(),
        config: config.clone(),
        syncing: syncing.clone(),
        http: http.clone(),
        gql_cache: GqlCache::new(),
        streams: Arc::new(crate::stream::StreamService::new(
            config.media_path(),
            config.public_url.clone(),
        )),
        jackett_syncing: jackett_syncing.clone(),
        introdb: crate::introdb::IntroDb::new(http.clone()),
    };
    // Wipe any leftover stream download folders from a previous run.
    app_state.streams.cleanup_stale().await;
    let schema = build_schema(app_state.clone());
    let http_state = HttpState {
        app: app_state.clone(),
        schema,
    };

    let ingest = IngestContext::from(&app_state);
    let _scheduler = ingest::scheduler::start(ingest.clone()).await?;
    let _watcher = media::scanner::start_watcher(pool.clone(), config.clone(), search.clone())?;

    let ingest_boot = ingest.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        // Clear orphaned sync flag from a previous crash/restart so the console
        // does not look permanently stuck at an old percent.
        let _ = sqlx::query(
            r#"
            UPDATE sync_state SET
                syncing = FALSE,
                workers_active = 0,
                last_error = CASE
                    WHEN syncing THEN 'Previous sync was interrupted (server restarted). Tap Force sync.'
                    ELSE last_error
                END
            WHERE id = 1 AND syncing = TRUE
            "#,
        )
        .execute(&ingest_boot.pool)
        .await;
        if let Err(e) = media::scanner::scan_library(
            &ingest_boot.pool,
            &ingest_boot.config,
            &ingest_boot.search,
        )
        .await
        {
            warn!(error = %e, "initial library scan failed");
        }
        match (
            db::title_count(&ingest_boot.pool).await,
            db::title_count_for_kind(&ingest_boot.pool, "movie").await,
            db::title_count_for_kind(&ingest_boot.pool, "series").await,
        ) {
            (Ok(total), Ok(movies), Ok(series))
                if !ingest_boot.config.tmdb_key().is_empty()
                    && (total == 0 || movies < 200 || series < 100) =>
            {
                info!(total, movies, series, "catalog thin; starting TMDB sync");
                ingest::spawn_full_sync(ingest_boot);
            }
            (Ok(n), _, _) => {
                info!(titles = n, "catalog ready");
                if ingest_boot.config.tmdb_key().is_empty() {
                    info!("no TMDB key — catalog sync skipped until one is added in Settings");
                } else if let Err(e) = ingest::refresh_stale(&ingest_boot).await {
                    warn!(error = %e, "stale refresh failed");
                }
            }
            (Err(e), _, _) => warn!(error = %e, "could not count titles"),
        }
    });

    let cors = cors_layer(&config.public_url);

    let router = Router::new()
        .route("/health", get(health))
        .route("/pair", axum::routing::post(auth::pair))
        .route("/", get(crate::admin::page).post(crate::admin::action))
        .route("/tokens", get(crate::admin::page).post(crate::admin::action))
        .route("/sync/status", get(crate::admin::sync_status))
        .route("/sync/logs", get(crate::admin::sync_logs))
        .route("/sync/start", axum::routing::post(crate::admin::sync_start))
        .route("/sync/flush", axum::routing::post(crate::admin::sync_flush))
        .route("/graphql", get(graphiql).post(graphql_handler))
        .route("/files/{id}", get(media::serve_file).head(media::serve_file))
        .route("/stream/{id}", get(stream::serve_stream).head(stream::serve_stream))
        .route("/art/tmdb/{size}/{*path}", get(media::proxy_tmdb).head(media::proxy_tmdb))
        .route("/art/youtube/{key}", get(media::proxy_youtube).head(media::proxy_youtube))
        .route("/updates/latest", get(updates::latest))
        .route("/updates/files/{tag}/{name}", get(updates::file).head(updates::file))
        .with_state(http_state.clone())
        .layer(middleware::from_fn_with_state(http_state, auth::gate))
        .layer(cors)
        // Log method + path only: media URLs can carry ?key= for external players.
        .layer(TraceLayer::new_for_http().make_span_with(|req: &axum::http::Request<_>| {
            tracing::info_span!("request", method = %req.method(), path = %req.uri().path())
        }));

    let addr: SocketAddr = config
        .bind_addr
        .parse()
        .map_err(|e| error::AppError::Config(format!("invalid BIND_ADDR: {e}")))?;
    // Mirror signed app releases from GitHub for LAN updates.
    updates::spawn_background();
    server_update::spawn_auto(app_state.http.clone(), app_state.streams.clone());
    let listener = TcpListener::bind(addr).await?;
    info!(addr = %addr, "listening");
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

/// Browsers may only call the API from the server's own origin, plus any
/// listed in CORS_ORIGINS (comma-separated; "*" allows every origin). Native
/// apps send no Origin header and are unaffected.
fn cors_layer(public_url: &str) -> CorsLayer {
    let base = CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS, Method::HEAD])
        .allow_headers([
            axum::http::header::CONTENT_TYPE,
            axum::http::header::AUTHORIZATION,
            axum::http::HeaderName::from_static("x-api-key"),
        ]);
    let extra = std::env::var("CORS_ORIGINS").unwrap_or_default();
    if extra.split(',').any(|o| o.trim() == "*") {
        return base.allow_origin(Any).allow_headers(Any);
    }
    let origins: Vec<HeaderValue> = std::iter::once(public_url)
        .chain(extra.split(','))
        .filter_map(origin_of)
        .filter_map(|o| HeaderValue::from_str(&o).ok())
        .collect();
    base.allow_origin(AllowOrigin::list(origins))
}

/// "http://10.0.0.5:3001/x" → "http://10.0.0.5:3001".
fn origin_of(url: &str) -> Option<String> {
    let url = reqwest::Url::parse(url.trim()).ok()?;
    let host = url.host_str()?;
    Some(match url.port() {
        Some(p) => format!("{}://{host}:{p}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

async fn graphiql() -> impl IntoResponse {
    Html(
        GraphiQLSource::build()
            .endpoint("/graphql")
            .title("PeanutButter GraphQL")
            .finish(),
    )
}

async fn graphql_handler(
    State(state): State<HttpState>,
    Extension(session): Extension<auth::AuthSession>,
    req: GraphQLRequest,
) -> Response {
    let mut request = req.into_inner();
    request = request
        .data(session.clone())
        .data(crate::graphql::loaders::new_loader(state.app.pool.clone()));
    let token_scope = session.token_id.to_string();
    let kind = crate::cache::classify(&request.query);
    let cache_key = GqlCache::key(&token_scope, &request.query, &request.variables);
    let skip_cache = {
        let q = request.query.to_ascii_lowercase();
        q.contains("streamingsearch")
            || q.contains("streamstatus")
            || q.contains("testjackett")
            || q.contains("jackettcatalog")
            || q.contains("serverinfo")
    };
    let cacheable = kind == RequestKind::Query && !skip_cache;
    if cacheable {
        if let Some(cached) = state.app.gql_cache.get(&cache_key).await {
            return Json(cached).into_response();
        }
    }
    let response = state.schema.execute(request).await;
    let json = serde_json::to_value(&response).unwrap_or_else(|_| {
        serde_json::json!({
            "errors": [{ "message": "failed to serialize GraphQL response" }]
        })
    });
    match kind {
        RequestKind::GlobalMutation => state.app.gql_cache.invalidate(),
        RequestKind::PersonalMutation => state.app.gql_cache.invalidate_scope(&token_scope),
        RequestKind::Query if cacheable && response.errors.is_empty() => {
            state.app.gql_cache.insert(cache_key, json.clone()).await;
        }
        RequestKind::Query => {}
    }
    Json(json).into_response()
}

#[derive(Serialize)]
struct HealthBody {
    status: &'static str,
    /// Running server version; the console watches it change after an update.
    version: &'static str,
    postgres: bool,
    meilisearch: bool,
}

/// LAN discovery probes /health on every candidate host, and apps poll it;
/// reuse a result for a few seconds instead of hitting Postgres + Meili each time.
async fn health(State(state): State<HttpState>) -> impl IntoResponse {
    static LAST: std::sync::Mutex<Option<(std::time::Instant, bool, bool)>> =
        std::sync::Mutex::new(None);
    let cached = LAST
        .lock()
        .ok()
        .and_then(|g| *g)
        .filter(|(at, _, _)| at.elapsed() < Duration::from_secs(3));
    let (postgres, meilisearch) = match cached {
        Some((_, pg, ms)) => (pg, ms),
        None => {
            let pg = sqlx::query("SELECT 1").execute(&state.app.pool).await.is_ok();
            let ms = state.app.search.health().await;
            if let Ok(mut g) = LAST.lock() {
                *g = Some((std::time::Instant::now(), pg, ms));
            }
            (pg, ms)
        }
    };
    let ok = postgres && meilisearch;
    let body = HealthBody {
        status: if ok { "ok" } else { "degraded" },
        version: crate::config::build_version(),
        postgres,
        meilisearch,
    };
    let status = if ok {
        axum::http::StatusCode::OK
    } else {
        axum::http::StatusCode::SERVICE_UNAVAILABLE
    };
    (status, Json(body))
}
