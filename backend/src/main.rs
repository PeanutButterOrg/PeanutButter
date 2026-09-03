mod admin;
mod auth;
mod cache;
mod config;
mod db;
mod error;
mod graphql;
mod ingest;
mod jackett;
mod media;
mod pin;
mod search;
mod stream;
mod subtitles;

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use async_graphql::http::GraphiQLSource;
use async_graphql_axum::GraphQLRequest;
use axum::extract::State;
use axum::http::{HeaderMap, Method};
use axum::middleware;
use axum::response::{Html, IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use serde::Serialize;
use tokio::net::TcpListener;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::cache::GqlCache;
use crate::config::Config;
use crate::error::Result;
use crate::graphql::{build_schema, AppSchema};
use crate::ingest::IngestContext;
use crate::search::SearchClient;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::PgPool,
    pub search: SearchClient,
    pub config: Config,
    pub syncing: Arc<AtomicBool>,
    pub http: reqwest::Client,
    pub gql_cache: GqlCache,
    pub streams: Arc<crate::stream::StreamService>,
    pub jackett_syncing: Arc<AtomicBool>,
}

impl From<&AppState> for IngestContext {
    fn from(state: &AppState) -> Self {
        IngestContext::new(
            state.pool.clone(),
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

    let pool = db::connect(&config.database_url).await?;
    let migrations_dir = std::env::var("MIGRATIONS_DIR")
        .ok()
        .map(std::path::PathBuf::from);
    db::run_migrations(&pool, migrations_dir.as_deref()).await?;
    db::overlay_saved_settings(&pool, &config).await?;
    db::ensure_app_token(&pool, &config).await?;
    db::ensure_admin_password(&pool).await?;
    info!("admin console at / — password required");

    let search = SearchClient::new(&config.meili_url, &config.meili_master_key).await?;
    let syncing = Arc::new(AtomicBool::new(false));
    let jackett_syncing = Arc::new(AtomicBool::new(false));
    let http = reqwest::Client::builder()
        .user_agent(format!("PeanutButter/{}", config.version))
        .timeout(Duration::from_secs(30))
        .build()?;

    let app_state = AppState {
        pool: pool.clone(),
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
                if total == 0 || movies < 400 || series < 200 =>
            {
                info!(total, movies, series, "catalog still thin; starting metadata sync");
                if let Err(e) = ingest::run_full_sync(&ingest_boot).await {
                    warn!(error = %e, "first-run sync failed");
                }
            }
            (Ok(n), _, _) => {
                info!(titles = n, "catalog ready");
                if let Err(e) = ingest::refresh_stale(&ingest_boot).await {
                    warn!(error = %e, "content-rating refresh failed");
                }
            }
            (Err(e), _, _) => warn!(error = %e, "could not count titles"),
        }
    });

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS, Method::HEAD])
        .allow_headers(Any);

    let router = Router::new()
        .route("/health", get(health))
        .route("/", get(crate::admin::page).post(crate::admin::action))
        .route("/tokens", get(crate::admin::page).post(crate::admin::action))
        .route("/graphql", get(graphiql).post(graphql_handler))
        .route("/files/{id}", get(media::serve_file).head(media::serve_file))
        .route("/stream/{id}", get(stream::serve_stream).head(stream::serve_stream))
        .with_state(http_state.clone())
        .layer(middleware::from_fn_with_state(http_state, auth::gate))
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    let addr: SocketAddr = config
        .bind_addr
        .parse()
        .map_err(|e| error::AppError::Config(format!("invalid BIND_ADDR: {e}")))?;
    let listener = TcpListener::bind(addr).await?;
    info!(
        addr = %addr,
        pairing = %crate::pin::format_code(&config.app_token()),
        "listening"
    );
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
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
    headers: HeaderMap,
    req: GraphQLRequest,
) -> Response {
    let mut request = req.into_inner();
    let Ok(session) = auth::resolve_session(&state, &headers).await else {
        return crate::error::AppError::Unauthorized("invalid API token".into()).into_response();
    };
    request = request.data(session.clone());
    let token_scope = session.token_id.to_string();
    let is_mutation = request
        .query
        .trim_start()
        .to_ascii_lowercase()
        .starts_with("mutation");
    let cache_key = format!("{}:{}:{:?}", token_scope, request.query, request.variables);
    let skip_cache = {
        let q = request.query.to_ascii_lowercase();
        q.contains("streamingsearch")
            || q.contains("streamstatus")
            || q.contains("startstream")
            || q.contains("stopstream")
            || q.contains("streamresume")
            || q.contains("testjackett")
            || q.contains("jackettcatalog")
            || q.contains("serverinfo")
            || q.contains("homefeed")
    };
    if !is_mutation && !skip_cache {
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
    if is_mutation {
        state.app.gql_cache.invalidate();
    } else if !skip_cache {
        state.app.gql_cache.insert(cache_key, json.clone()).await;
    }
    Json(json).into_response()
}

#[derive(Serialize)]
struct HealthBody {
    status: &'static str,
    postgres: bool,
    meilisearch: bool,
}

async fn health(State(state): State<HttpState>) -> impl IntoResponse {
    let postgres = sqlx::query("SELECT 1")
        .execute(&state.app.pool)
        .await
        .is_ok();
    let meilisearch = state.app.search.health().await;
    let ok = postgres && meilisearch;
    let body = HealthBody {
        status: if ok { "ok" } else { "degraded" },
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
