use async_graphql::{Context, Object};
use uuid::Uuid;

use crate::db::models::{SyncStateRow, TitleRow};
use crate::error::AppError;
use crate::graphql::types::{
    HomeFeed, JackettCatalogStatus, SearchResult, ServerInfo, SortDir, SortField, StreamSession,
    StreamSource, SyncStatus, Title, TitleConnection, TitleFilter, TitleKind,
};
use crate::AppState;

const TITLE_COLUMNS: &str = r#"
    t.id, t.kind, t.title, t.original_title, t.synopsis, t.description, t.year,
    t.runtime_minutes, t.poster_path, t.backdrop_path, t.logo_path, t.thumb_path,
    t.content_rating,
    t.tmdb_id, t.imdb_id, t.anilist_id, t.mal_id, t.metadata, t.created_at,
    t.updated_at, t.last_synced_at
"#;

pub struct Query;

#[Object]
impl Query {
    async fn catalog(
        &self,
        ctx: &Context<'_>,
        filter: Option<TitleFilter>,
        sort: Option<SortField>,
        dir: Option<SortDir>,
        page: Option<i32>,
        per_page: Option<i32>,
    ) -> async_graphql::Result<TitleConnection> {
        let state = ctx.data::<AppState>()?;
        let filter = filter.unwrap_or_default();
        let sort = sort.unwrap_or(SortField::Trending);
        let dir = dir.unwrap_or(SortDir::Desc);
        let page = page.unwrap_or(1).max(1);
        let per_page = per_page.unwrap_or(24).clamp(1, 100);
        let offset = (page - 1) * per_page;

        // Lazy TMDB pagination: if the user scrolls past the initially synced
        // pages (5), fetch the next TMDB list page(s), cache them, then query.
        let mut remote_has_more = false;
        if let Some(shelf) = match sort {
            SortField::Trending => Some("trending"),
            SortField::Popularity => Some("popular"),
            SortField::DateAdded => Some("fresh"),
            _ => None,
        } {
            let kind = filter.kind.map(|k| match k {
                TitleKind::Movie => "movie",
                TitleKind::Series => "series",
                TitleKind::Anime => "anime",
            });
            let ingest = crate::ingest::IngestContext::from(state);
            match crate::ingest::tmdb::ensure_shelf_pages_for_catalog(
                &ingest,
                shelf,
                kind,
                page,
                per_page,
            )
            .await
            {
                Ok(more) => remote_has_more = more,
                Err(e) => {
                    tracing::warn!(error = %e, shelf, page, "lazy TMDB shelf fetch failed");
                }
            }
        }

        let continue_watching = sort == SortField::ContinueWatching;
        let favorites = sort == SortField::Favorites;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        let mut qb = sqlx::QueryBuilder::new("SELECT ");
        qb.push(TITLE_COLUMNS);
        qb.push(" FROM titles t LEFT JOIN ratings r ON r.title_id = t.id");
        if continue_watching || favorites {
            qb.push(" INNER JOIN user_progress p ON p.title_id = t.id AND p.token_id = ");
            qb.push_bind(auth.token_id);
        }
        qb.push(" WHERE 1=1");
        apply_filters(&mut qb, &filter);
        apply_language_filter(&mut qb, &state.config.live.preferred_language_codes());
        if continue_watching {
            qb.push(" AND p.watched = FALSE AND p.position_ms > 2000");
        }
        if favorites {
            qb.push(" AND p.favorite = TRUE");
        }

        qb.push(" ORDER BY ");
        qb.push(order_sql(filter.kind, sort, dir));
        qb.push(" LIMIT ");
        qb.push_bind(per_page as i64);
        qb.push(" OFFSET ");
        qb.push_bind(offset as i64);

        let rows: Vec<TitleRow> = qb.build_query_as().fetch_all(&state.pool).await?;

        let mut count_qb = sqlx::QueryBuilder::new(
            "SELECT COUNT(*) FROM titles t LEFT JOIN ratings r ON r.title_id = t.id",
        );
        if continue_watching || favorites {
            count_qb.push(" INNER JOIN user_progress p ON p.title_id = t.id AND p.token_id = ");
            count_qb.push_bind(auth.token_id);
        }
        count_qb.push(" WHERE 1=1");
        apply_filters(&mut count_qb, &filter);
        apply_language_filter(&mut count_qb, &state.config.live.preferred_language_codes());
        if continue_watching {
            count_qb.push(" AND p.watched = FALSE AND p.position_ms > 2000");
        }
        if favorites {
            count_qb.push(" AND p.favorite = TRUE");
        }
        let (total_count,): (i64,) = count_qb.build_query_as().fetch_one(&state.pool).await?;

        let db_has_next = (offset as i64) + (rows.len() as i64) < total_count;
        // Keep scrolling enabled while TMDB still has deeper shelf pages to cache.
        let has_next_page = db_has_next || remote_has_more;
        Ok(TitleConnection {
            items: rows.into_iter().map(Title::from_row).collect(),
            total_count,
            has_next_page,
            page,
            per_page,
        })
    }

    async fn title(
        &self,
        ctx: &Context<'_>,
        id: Option<Uuid>,
        imdb_id: Option<String>,
        tmdb_id: Option<i32>,
    ) -> async_graphql::Result<Option<Title>> {
        let state = ctx.data::<AppState>()?;
        if id.is_none() && imdb_id.is_none() && tmdb_id.is_none() {
            return Err(AppError::BadRequest("provide id, imdbId, or tmdbId".into()).into());
        }

        let mut qb = sqlx::QueryBuilder::new("SELECT ");
        qb.push(TITLE_COLUMNS);
        qb.push(" FROM titles t WHERE 1=1");
        if let Some(id) = id {
            qb.push(" AND t.id = ");
            qb.push_bind(id);
        }
        if let Some(imdb_id) = imdb_id {
            qb.push(" AND t.imdb_id = ");
            qb.push_bind(imdb_id);
        }
        if let Some(tmdb_id) = tmdb_id {
            qb.push(" AND t.tmdb_id = ");
            qb.push_bind(tmdb_id);
        }
        qb.push(" LIMIT 1");

        let row: Option<TitleRow> = qb.build_query_as().fetch_optional(&state.pool).await?;
        let Some(row) = row else {
            return Ok(None);
        };

        // Legacy catalog rows often lack seasons/trailers — pull from TMDB on open.
        // During a full sync, do this in the background so GraphQL stays responsive.
        let ingest = crate::ingest::IngestContext::from(state);
        let syncing = state.syncing.load(std::sync::atomic::Ordering::Relaxed);
        if syncing {
            let title_id = row.id;
            tokio::spawn(async move {
                if let Err(e) = crate::ingest::tmdb::ensure_title_enriched(&ingest, title_id).await {
                    tracing::warn!(title_id = %title_id, error = %e, "background TMDB enrich failed");
                }
            });
            return Ok(Some(Title::from_row(row)));
        }

        match crate::ingest::tmdb::ensure_title_enriched(&ingest, row.id).await {
            Ok(true) => {
                let refreshed: Option<TitleRow> = sqlx::query_as(&format!(
                    "SELECT {TITLE_COLUMNS} FROM titles t WHERE t.id = $1"
                ))
                .bind(row.id)
                .fetch_optional(&state.pool)
                .await?;
                return Ok(refreshed.map(Title::from_row));
            }
            Ok(false) => {}
            Err(e) => tracing::warn!(title_id = %row.id, error = %e, "on-demand TMDB enrich failed"),
        }

        Ok(Some(Title::from_row(row)))
    }

    async fn search(
        &self,
        ctx: &Context<'_>,
        query: String,
        kind: Option<TitleKind>,
        page: Option<i32>,
        per_page: Option<i32>,
    ) -> async_graphql::Result<SearchResult> {
        let state = ctx.data::<AppState>()?;
        let page = page.unwrap_or(1).max(1) as usize;
        let per_page = per_page.unwrap_or(24).clamp(1, 100) as usize;
        let q = query.trim();
        if q.is_empty() {
            return Ok(SearchResult {
                items: vec![],
                total_count: 0,
                has_next_page: false,
                page: page as i32,
            });
        }

        let kind_db = kind.map(|k| k.as_db().to_string());
        let results = state
            .search
            .search(q, kind_db.as_deref(), page, per_page)
            .await?;

        let mut ids: Vec<Uuid> = results.hits.iter().map(|h| h.id).collect();
        let mut estimated_total = results.estimated_total;

        // Always consult TMDB on page 1 so unsynced titles can be found and saved.
        // Pull a full results page and ingest hits in parallel.
        if page == 1 && !state.config.tmdb_key().is_empty() {
            let ingest = crate::ingest::IngestContext::from(state);
            match crate::ingest::tmdb::search_and_ingest(
                &ingest,
                q,
                kind_db.as_deref(),
                page,
                per_page.min(20),
            )
            .await
            {
                Ok(remote_ids) => {
                    for id in remote_ids {
                        if !ids.contains(&id) {
                            ids.push(id);
                        }
                    }
                    estimated_total = estimated_total.max(ids.len());
                }
                Err(e) => {
                    tracing::warn!(error = %e, "TMDB search ingest failed");
                }
            }
        } else if ids.is_empty() && state.config.tmdb_key().is_empty() {
            return Ok(SearchResult {
                items: vec![],
                total_count: 0,
                has_next_page: false,
                page: page as i32,
            });
        }

        if ids.is_empty() {
            return Ok(SearchResult {
                items: vec![],
                total_count: estimated_total as i64,
                has_next_page: false,
                page: page as i32,
            });
        }

        // Keep result order; trim to page size for the response.
        ids.truncate(per_page);

        let rows: Vec<TitleRow> = sqlx::query_as(&format!(
            "SELECT {TITLE_COLUMNS} FROM titles t WHERE t.id = ANY($1)"
        ))
        .bind(&ids)
        .fetch_all(&state.pool)
        .await?;

        let mut by_id: std::collections::HashMap<Uuid, TitleRow> =
            rows.into_iter().map(|r| (r.id, r)).collect();
        let items: Vec<Title> = ids
            .into_iter()
            .filter_map(|id| by_id.remove(&id).map(Title::from_row))
            .collect();

        let loaded = items.len();
        Ok(SearchResult {
            items,
            total_count: estimated_total as i64,
            has_next_page: ((page - 1) * per_page + loaded) < estimated_total,
            page: page as i32,
        })
    }

    async fn genres(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<String>> {
        let state = ctx.data::<AppState>()?;
        Ok(crate::db::all_genre_names(&state.pool).await?)
    }

    async fn server_info(&self, ctx: &Context<'_>) -> async_graphql::Result<ServerInfo> {
        let state = ctx.data::<AppState>()?;
        let row: Option<SyncStateRow> = sqlx::query_as(
            r#"
            SELECT id, last_sync_at, syncing, total_titles, last_error,
                   phase, progress_done, progress_total, workers_active
            FROM sync_state WHERE id = 1
            "#,
        )
        .fetch_optional(&state.pool)
        .await?;
        let syncing = state.syncing.load(std::sync::atomic::Ordering::Relaxed)
            || row.as_ref().is_some_and(|r| r.syncing);
        let (last_sync_at, total_titles, phase, progress_done, progress_total, workers_active) =
            match row {
                Some(r) => (
                    r.last_sync_at,
                    r.total_titles,
                    r.phase,
                    r.progress_done,
                    r.progress_total,
                    r.workers_active,
                ),
                None => (None, 0, None, 0, 0, 0),
            };
        Ok(ServerInfo {
            version: state.config.version.to_string(),
            library_path: state.config.media_path().display().to_string(),
            tmdb_configured: !state.config.tmdb_key().is_empty(),
            omdb_configured: !state.config.omdb_key().is_empty(),
            anilist_configured: true,
            jackett_enabled: state.config.live.jackett_enabled(),
            jackett_configured: state.config.live.jackett_configured(),
            jackett_url: state.config.live.jackett_url(),
            streaming_resolution: state.config.live.streaming_resolution(),
            preferred_languages: state.config.live.preferred_language_codes(),
            jackett_catalog: jackett_catalog_status(state).await?,
            opensubtitles_enabled: state.config.live.opensubtitles_enabled(),
            opensubtitles_configured: state.config.live.opensubtitles_configured(),
            sync_status: SyncStatus {
                last_sync_at,
                total_titles,
                syncing,
                phase,
                progress_done,
                progress_total,
                workers_active,
            },
        })
    }

    async fn jackett_catalog(&self, ctx: &Context<'_>) -> async_graphql::Result<JackettCatalogStatus> {
        let state = ctx.data::<AppState>()?;
        Ok(jackett_catalog_status(state).await?)
    }

    async fn streaming_search(
        &self,
        ctx: &Context<'_>,
        query: String,
        kind: TitleKind,
        season: Option<i32>,
        episode: Option<i32>,
        language: Option<String>,
        title_id: Option<Uuid>,
        live: Option<bool>,
    ) -> async_graphql::Result<Vec<StreamSource>> {
        let state = ctx.data::<AppState>()?;
        if !state.config.live.jackett_enabled() {
            return Err(AppError::BadRequest(
                "Jackett streaming is turned off. Enable it in Settings.".into(),
            )
            .into());
        }
        let _ = live;
        // Server console languages are the source of truth for Jackett Play.
        let server_langs = state.config.live.preferred_languages();
        let preferred = if !server_langs.trim().is_empty() {
            server_langs
        } else {
            language.unwrap_or_default()
        };
        if !state.config.live.jackett_configured() {
            return Ok(vec![]);
        }
        let client = crate::jackett::JackettClient::from_live(&state.http, &state.config.live)?;
        let imdb_id = if let Some(id) = title_id {
            crate::db::title_imdb_id(&state.pool, id).await.unwrap_or(None)
        } else {
            None
        };
        let found = client
            .search(
                &query,
                kind.as_db(),
                season,
                episode,
                &state.config.live.streaming_resolution(),
                &preferred,
                imdb_id.as_deref(),
            )
            .await?;
        let found = if let (Some(s), Some(e)) = (season, episode) {
            found
                .into_iter()
                .filter(|src| crate::jackett::torrent_usable_for_episode(&src.title, s, e))
                .collect()
        } else {
            found
        };
        Ok(found)
    }

    async fn stream_status(
        &self,
        ctx: &Context<'_>,
        session_id: String,
    ) -> async_graphql::Result<Option<StreamSession>> {
        let state = ctx.data::<AppState>()?;
        Ok(state.streams.status(&session_id).await)
    }

    /// Butter-style home rows: trending, popular, and last added, with no repeated titles.
    async fn home_feed(
        &self,
        ctx: &Context<'_>,
        kind: TitleKind,
    ) -> async_graphql::Result<HomeFeed> {
        let state = ctx.data::<AppState>()?;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        let langs = state.config.live.preferred_language_codes();
        let trending =
            fetch_home_row(&state.pool, kind, SortField::Trending, &[], 18, &langs).await?;
        let exclude: Vec<Uuid> = trending.iter().map(|t| t.id).collect();
        let popular =
            fetch_home_row(&state.pool, kind, SortField::Popularity, &exclude, 18, &langs).await?;
        let mut exclude_recent = exclude;
        exclude_recent.extend(popular.iter().map(|t| t.id));
        let recent =
            fetch_home_row(&state.pool, kind, SortField::DateAdded, &exclude_recent, 18, &langs)
                .await?;
        let continue_watching =
            fetch_continue_watching(&state.pool, 24, auth.token_id, &langs).await?;
        Ok(HomeFeed {
            trending,
            popular,
            recent,
            continue_watching,
        })
    }

    async fn next_playback(
        &self,
        ctx: &Context<'_>,
        file_id: Uuid,
    ) -> async_graphql::Result<Option<crate::graphql::types::FileReference>> {
        let state = ctx.data::<AppState>()?;
        let current: Option<(Uuid, Option<Uuid>)> = sqlx::query_as(
            "SELECT title_id, episode_id FROM file_references WHERE id = $1",
        )
        .bind(file_id)
        .fetch_optional(&state.pool)
        .await?;
        let Some((title_id, episode_id)) = current else {
            return Ok(None);
        };
        let Some(episode_id) = episode_id else {
            return Ok(None);
        };
        let row: Option<crate::db::models::FileReferenceRow> = sqlx::query_as(
            r#"
            SELECT fr.id, fr.title_id, fr.season_id, fr.episode_id, fr.kind, fr.quality, fr.container,
                   fr.codec, fr.audio_codec, fr.size_bytes, fr.file_path, fr.http_url, fr.content_hash,
                   fr.available_peers, fr.last_check, fr.created_at
            FROM file_references fr
            JOIN episodes e ON e.id = fr.episode_id
            JOIN seasons s ON s.id = e.season_id
            JOIN episodes cur ON cur.id = $2
            JOIN seasons cs ON cs.id = cur.season_id
            WHERE fr.title_id = $1
              AND (s.season_number > cs.season_number
                   OR (s.season_number = cs.season_number AND e.episode_number > cur.episode_number))
            ORDER BY s.season_number, e.episode_number
            LIMIT 1
            "#,
        )
        .bind(title_id)
        .bind(episode_id)
        .fetch_optional(&state.pool)
        .await?;
        Ok(row.map(|r| crate::graphql::types::FileReference::from_row(r, &state.config.public_url)))
    }
}

async fn jackett_catalog_status(_state: &AppState) -> crate::error::Result<JackettCatalogStatus> {
    Ok(JackettCatalogStatus {
        ready: true,
        syncing: false,
        done: 0,
        total: 0,
        last_error: None,
    })
}

async fn fetch_home_row(
    pool: &sqlx::PgPool,
    kind: TitleKind,
    sort: SortField,
    exclude: &[Uuid],
    limit: i64,
    langs: &[String],
) -> sqlx::Result<Vec<Title>> {
    let mut qb = sqlx::QueryBuilder::new("SELECT ");
    qb.push(TITLE_COLUMNS);
    qb.push(" FROM titles t LEFT JOIN ratings r ON r.title_id = t.id WHERE t.kind = ");
    qb.push_bind(kind.as_db());
    if !exclude.is_empty() {
        qb.push(" AND NOT (t.id = ANY(");
        qb.push_bind(exclude.to_vec());
        qb.push("))");
    }
    apply_adult_block(&mut qb);
    apply_released_only(&mut qb);
    apply_language_filter(&mut qb, langs);
    qb.push(" ORDER BY ");
    qb.push(order_sql(Some(kind), sort, SortDir::Desc));
    qb.push(" LIMIT ");
    qb.push_bind(limit);
    let rows: Vec<TitleRow> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows.into_iter().map(Title::from_row).collect())
}

async fn fetch_continue_watching(
    pool: &sqlx::PgPool,
    limit: i64,
    token_id: Uuid,
    langs: &[String],
) -> sqlx::Result<Vec<Title>> {
    // Mixed movies / series / anime — same row on every home tab.
    let mut qb = sqlx::QueryBuilder::new("SELECT ");
    qb.push(TITLE_COLUMNS);
    qb.push(
        " FROM titles t JOIN user_progress p ON p.title_id = t.id AND p.token_id = ",
    );
    qb.push_bind(token_id);
    qb.push(" WHERE p.watched = FALSE AND p.position_ms > 2000");
    apply_adult_block(&mut qb);
    apply_released_only(&mut qb);
    apply_language_filter(&mut qb, langs);
    qb.push(" ORDER BY p.updated_at DESC LIMIT ");
    qb.push_bind(limit);
    let rows: Vec<TitleRow> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows.into_iter().map(Title::from_row).collect())
}

fn apply_adult_block<'a>(qb: &mut sqlx::QueryBuilder<'a, sqlx::Postgres>) {
    qb.push(
        " AND NOT EXISTS (\
            SELECT 1 FROM title_genres tg \
            JOIN genres g ON g.id = tg.genre_id \
            WHERE tg.title_id = t.id AND (\
                lower(g.name) IN (",
    );
    qb.push(crate::content_filter::BLOCKED_GENRE_SQL_LIST);
    qb.push(
        ") OR lower(g.name) LIKE '%hentai%' OR lower(g.name) LIKE '%porn%'\
            )\
        )",
    );
    qb.push(
        " AND NOT (\
            upper(trim(COALESCE(t.content_rating, ''))) IN ('XXX','AO') \
            OR upper(COALESCE(t.content_rating, '')) LIKE '%XXX%'\
        )",
    );
}

/// Hide titles that are not out yet (future release / first-air date or future year).
fn apply_released_only<'a>(qb: &mut sqlx::QueryBuilder<'a, sqlx::Postgres>) {
    qb.push(
        " AND (t.released_at IS NULL OR t.released_at <= CURRENT_DATE) \
          AND (t.year IS NULL OR t.year <= EXTRACT(YEAR FROM CURRENT_DATE)::int)",
    );
}

fn apply_filters<'a>(qb: &mut sqlx::QueryBuilder<'a, sqlx::Postgres>, filter: &TitleFilter) {
    if let Some(kind) = filter.kind {
        qb.push(" AND t.kind = ");
        qb.push_bind(kind.as_db());
    }
    // Never surface adult / Sex-tagged titles in catalog or home.
    apply_adult_block(qb);
    apply_released_only(qb);
    if let Some(genre) = filter.genre.clone() {
        if !genre.is_empty() && !genre.eq_ignore_ascii_case("all") {
            if crate::content_filter::is_blocked_genre(&genre) {
                // Requested blocked genre → empty result set.
                qb.push(" AND FALSE");
            } else {
                qb.push(
                    " AND EXISTS (SELECT 1 FROM title_genres tg JOIN genres g ON g.id = tg.genre_id WHERE tg.title_id = t.id AND lower(g.name) = lower(",
                );
                qb.push_bind(genre);
                qb.push("))");
            }
        }
    }
    if let Some(year_min) = filter.year_min {
        qb.push(" AND t.year >= ");
        qb.push_bind(year_min);
    }
    if let Some(year_max) = filter.year_max {
        qb.push(" AND t.year <= ");
        qb.push_bind(year_max);
    }
    if let Some(rating_min) = filter.rating_min {
        qb.push(" AND ");
        qb.push(score_expr(filter.kind));
        qb.push(" >= ");
        qb.push_bind(rating_min);
    }
}

fn apply_language_filter<'a>(qb: &mut sqlx::QueryBuilder<'a, sqlx::Postgres>, langs: &[String]) {
    if langs.is_empty() {
        return;
    }
    // Keep unknown (NULL) rows until a sync stamps original_language.
    qb.push(" AND (t.original_language IS NULL OR t.original_language = ANY(");
    qb.push_bind(langs.to_vec());
    qb.push("))");
}

/// 0–10 content score by kind: movies prefer IMDb, series TMDB/TVMaze, anime AniList.
fn score_expr(kind: Option<TitleKind>) -> &'static str {
    match kind {
        Some(TitleKind::Anime) => {
            "COALESCE(NULLIF(r.anilist_score, 0) / 10.0, NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), 0)"
        }
        Some(TitleKind::Series) => {
            "COALESCE(NULLIF(r.tmdb_vote_average, 0), NULLIF(r.imdb_rating, 0), NULLIF(r.anilist_score, 0) / 10.0, 0)"
        }
        Some(TitleKind::Movie) | None => {
            "COALESCE(NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), NULLIF(r.rt_score, 0)::double precision / 10.0, NULLIF(r.anilist_score, 0) / 10.0, 0)"
        }
    }
}

fn vote_support_expr(kind: Option<TitleKind>) -> &'static str {
    match kind {
        Some(TitleKind::Anime) => "GREATEST(COALESCE(r.anilist_popularity, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.tmdb_vote_count, 0))",
        Some(TitleKind::Series) => {
            "GREATEST(COALESCE(r.tmdb_vote_count, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.anilist_popularity, 0))"
        }
        Some(TitleKind::Movie) | None => {
            "GREATEST(COALESCE(r.imdb_votes, 0), COALESCE(r.tmdb_vote_count, 0))"
        }
    }
}

fn year_boost_expr() -> &'static str {
    "CASE WHEN t.year >= date_part('year', CURRENT_DATE)::int - 1 THEN 3.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 3 THEN 2.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 7 THEN 1.35 ELSE 1.0 END"
}

fn order_sql(kind: Option<TitleKind>, sort: SortField, dir: SortDir) -> String {
    let score = score_expr(kind);
    let votes = vote_support_expr(kind);
    let year_boost = year_boost_expr();
    let asc = matches!(dir, SortDir::Asc);
    // Popcorn Time classic sorts (popcorn-api movies controller):
    //   trending  → rating.watching  (we store TMDB popularity ≈ Trakt watching)
    //   rating    → rating.percentage + votes
    //   last added→ released (theatrical / first-air date)
    // Popular in the app maps to PT's rating sort.
    let watching = "COALESCE(r.tmdb_popularity, NULLIF(r.anilist_popularity, 0)::double precision, 0)";
    let percentage = format!("({score})");
    let released = "COALESCE(t.released_at, make_date(COALESCE(NULLIF(t.year, 0), 1900), 1, 1))";
    match sort {
        SortField::Rating => {
            if asc {
                format!("{percentage} ASC NULLS LAST, {votes} ASC NULLS LAST, t.title ASC")
            } else {
                format!("{percentage} DESC NULLS LAST, {votes} DESC NULLS LAST, t.title ASC")
            }
        }
        // Popular = PT `sort=rating` (score %, then votes).
        SortField::Popularity => {
            if asc {
                format!("{percentage} ASC NULLS LAST, {votes} ASC NULLS LAST, t.title ASC")
            } else {
                format!("{percentage} DESC NULLS LAST, {votes} DESC NULLS LAST, t.title ASC")
            }
        }
        SortField::Year => {
            if asc {
                "t.year ASC NULLS LAST, t.title ASC".into()
            } else {
                "t.year DESC NULLS LAST, t.title ASC".into()
            }
        }
        SortField::Title => {
            if asc {
                "lower(t.title) ASC".into()
            } else {
                "lower(t.title) DESC".into()
            }
        }
        // Last added = PT `sort=last added` → released date (not ingest time).
        SortField::DateAdded => {
            if asc {
                format!("{released} ASC NULLS LAST, t.title ASC")
            } else {
                format!("{released} DESC NULLS LAST, t.title ASC")
            }
        }
        // Trending = PT `sort=trending` → watching / buzz.
        SortField::Trending => {
            if asc {
                format!(
                    "{watching} ASC NULLS LAST, {votes} ASC NULLS LAST, ({score}) * ({year_boost}) ASC NULLS LAST, t.title ASC"
                )
            } else {
                format!(
                    "{watching} DESC NULLS LAST, {votes} DESC NULLS LAST, ({score}) * ({year_boost}) DESC NULLS LAST, t.title ASC"
                )
            }
        }
        SortField::RottenTomatoes => {
            if asc {
                "r.rt_score ASC NULLS LAST, t.title ASC".into()
            } else {
                "r.rt_score DESC NULLS LAST, t.title ASC".into()
            }
        }
        SortField::Availability => {
            if asc {
                "(SELECT COALESCE(MAX(fr.available_peers), 0) FROM file_references fr WHERE fr.title_id = t.id) ASC, t.title ASC".into()
            } else {
                "(SELECT COALESCE(MAX(fr.available_peers), 0) FROM file_references fr WHERE fr.title_id = t.id) DESC, t.title ASC".into()
            }
        }
        SortField::ContinueWatching => {
            if asc {
                "p.updated_at ASC, t.title ASC".into()
            } else {
                "p.updated_at DESC, t.title ASC".into()
            }
        }
        SortField::Favorites => {
            if asc {
                "p.updated_at ASC, t.title ASC".into()
            } else {
                "p.updated_at DESC, t.title ASC".into()
            }
        }
    }
}
