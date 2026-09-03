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

        let continue_watching = sort == SortField::ContinueWatching;
        let auth = ctx.data::<crate::auth::AuthSession>()?;
        let mut qb = sqlx::QueryBuilder::new("SELECT ");
        qb.push(TITLE_COLUMNS);
        qb.push(" FROM titles t LEFT JOIN ratings r ON r.title_id = t.id");
        if continue_watching {
            qb.push(" INNER JOIN user_progress p ON p.title_id = t.id AND p.token_id = ");
            qb.push_bind(auth.token_id);
        }
        qb.push(" WHERE 1=1");
        apply_filters(&mut qb, &filter);
        if continue_watching {
            qb.push(" AND p.watched = FALSE AND p.position_ms > 2000");
        }

        qb.push(" ORDER BY ");
        qb.push(order_sql(sort, dir));
        qb.push(" LIMIT ");
        qb.push_bind(per_page as i64);
        qb.push(" OFFSET ");
        qb.push_bind(offset as i64);

        let rows: Vec<TitleRow> = qb.build_query_as().fetch_all(&state.pool).await?;

        let mut count_qb = sqlx::QueryBuilder::new(
            "SELECT COUNT(*) FROM titles t LEFT JOIN ratings r ON r.title_id = t.id",
        );
        if continue_watching {
            count_qb.push(" INNER JOIN user_progress p ON p.title_id = t.id AND p.token_id = ");
            count_qb.push_bind(auth.token_id);
        }
        count_qb.push(" WHERE 1=1");
        apply_filters(&mut count_qb, &filter);
        if continue_watching {
            count_qb.push(" AND p.watched = FALSE AND p.position_ms > 2000");
        }
        let (total_count,): (i64,) = count_qb.build_query_as().fetch_one(&state.pool).await?;

        let has_next_page = (offset as i64) + (rows.len() as i64) < total_count;
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
        Ok(row.map(Title::from_row))
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

        let ids: Vec<Uuid> = results.hits.iter().map(|h| h.id).collect();
        if ids.is_empty() {
            return Ok(SearchResult {
                items: vec![],
                total_count: results.estimated_total as i64,
                has_next_page: false,
                page: page as i32,
            });
        }

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
            total_count: results.estimated_total as i64,
            has_next_page: ((page - 1) * per_page + loaded) < results.estimated_total,
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
            "SELECT id, last_sync_at, syncing, total_titles, last_error FROM sync_state WHERE id = 1",
        )
        .fetch_optional(&state.pool)
        .await?;
        let syncing = state.syncing.load(std::sync::atomic::Ordering::Relaxed);
        let (last_sync_at, total_titles) = match row {
            Some(r) => (r.last_sync_at, r.total_titles),
            None => (None, 0),
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
            jackett_catalog: jackett_catalog_status(state).await?,
            opensubtitles_enabled: state.config.live.opensubtitles_enabled(),
            opensubtitles_configured: state.config.live.opensubtitles_configured(),
            sync_status: SyncStatus {
                last_sync_at,
                total_titles,
                syncing,
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
        let preferred = language.as_deref().unwrap_or("");
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
                preferred,
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
        let trending =
            fetch_home_row(&state.pool, kind, SortField::Trending, &[], 18).await?;
        let exclude: Vec<Uuid> = trending.iter().map(|t| t.id).collect();
        let popular =
            fetch_home_row(&state.pool, kind, SortField::Popularity, &exclude, 18).await?;
        let mut exclude_recent = exclude;
        exclude_recent.extend(popular.iter().map(|t| t.id));
        let recent =
            fetch_home_row(&state.pool, kind, SortField::DateAdded, &exclude_recent, 18).await?;
        let continue_watching =
            fetch_continue_watching(&state.pool, 24, auth.token_id).await?;
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
    qb.push(" ORDER BY ");
    qb.push(order_sql(sort, SortDir::Desc));
    qb.push(" LIMIT ");
    qb.push_bind(limit);
    let rows: Vec<TitleRow> = qb.build_query_as().fetch_all(pool).await?;
    Ok(rows.into_iter().map(Title::from_row).collect())
}

async fn fetch_continue_watching(
    pool: &sqlx::PgPool,
    limit: i64,
    token_id: Uuid,
) -> sqlx::Result<Vec<Title>> {
    // Mixed movies / series / anime — same row on every home tab.
    let rows: Vec<TitleRow> = sqlx::query_as(&format!(
        r#"
        SELECT {TITLE_COLUMNS}
        FROM titles t
        JOIN user_progress p ON p.title_id = t.id AND p.token_id = $2
        WHERE p.watched = FALSE
          AND p.position_ms > 2000
        ORDER BY p.updated_at DESC
        LIMIT $1
        "#
    ))
    .bind(limit)
    .bind(token_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Title::from_row).collect())
}

fn apply_filters<'a>(qb: &mut sqlx::QueryBuilder<'a, sqlx::Postgres>, filter: &TitleFilter) {
    if let Some(kind) = filter.kind {
        qb.push(" AND t.kind = ");
        qb.push_bind(kind.as_db());
    }
    if let Some(genre) = filter.genre.clone() {
        if !genre.is_empty() && !genre.eq_ignore_ascii_case("all") {
            qb.push(
                " AND EXISTS (SELECT 1 FROM title_genres tg JOIN genres g ON g.id = tg.genre_id WHERE tg.title_id = t.id AND lower(g.name) = lower(",
            );
            qb.push_bind(genre);
            qb.push("))");
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
        qb.push(" AND COALESCE(r.tmdb_vote_average, r.imdb_rating, r.anilist_score / 10.0, 0) >= ");
        qb.push_bind(rating_min);
    }
}

fn order_sql(sort: SortField, dir: SortDir) -> &'static str {
    match (sort, dir) {
        (SortField::Rating, SortDir::Asc) => {
            "COALESCE(r.tmdb_vote_average, r.imdb_rating, r.anilist_score / 10.0, 0) ASC NULLS LAST, t.title ASC"
        }
        (SortField::Rating, SortDir::Desc) => {
            "COALESCE(r.tmdb_vote_average, r.imdb_rating, r.anilist_score / 10.0, 0) DESC NULLS LAST, t.title ASC"
        }
        (SortField::Popularity, SortDir::Asc) => {
            "GREATEST(COALESCE(r.tmdb_vote_count, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.anilist_popularity, 0)) ASC NULLS LAST, COALESCE(NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), COALESCE(r.anilist_score, 0) / 10.0, 0) ASC NULLS LAST"
        }
        (SortField::Popularity, SortDir::Desc) => {
            "GREATEST(COALESCE(r.tmdb_vote_count, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.anilist_popularity, 0)) DESC NULLS LAST, COALESCE(NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), COALESCE(r.anilist_score, 0) / 10.0, 0) DESC NULLS LAST"
        }
        (SortField::Year, SortDir::Asc) => "t.year ASC NULLS LAST, t.title ASC",
        (SortField::Year, SortDir::Desc) => "t.year DESC NULLS LAST, t.title ASC",
        (SortField::Title, SortDir::Asc) => "lower(t.title) ASC",
        (SortField::Title, SortDir::Desc) => "lower(t.title) DESC",
        (SortField::DateAdded, SortDir::Asc) => "t.created_at ASC",
        (SortField::DateAdded, SortDir::Desc) => "t.created_at DESC",
        (SortField::Trending, SortDir::Asc) => {
            "LN(2 + GREATEST(COALESCE(r.tmdb_vote_count, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.anilist_popularity, 0), 1)::double precision) * COALESCE(NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), COALESCE(r.anilist_score, 0) / 10.0, COALESCE(r.rt_score, 0)::double precision / 10.0, 0) * CASE WHEN t.year >= date_part('year', CURRENT_DATE)::int - 1 THEN 3.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 3 THEN 2.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 7 THEN 1.35 ELSE 1.0 END ASC NULLS LAST, t.title ASC"
        }
        (SortField::Trending, SortDir::Desc) => {
            "LN(2 + GREATEST(COALESCE(r.tmdb_vote_count, 0), COALESCE(r.imdb_votes, 0), COALESCE(r.anilist_popularity, 0), 1)::double precision) * COALESCE(NULLIF(r.imdb_rating, 0), NULLIF(r.tmdb_vote_average, 0), COALESCE(r.anilist_score, 0) / 10.0, COALESCE(r.rt_score, 0)::double precision / 10.0, 0) * CASE WHEN t.year >= date_part('year', CURRENT_DATE)::int - 1 THEN 3.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 3 THEN 2.0 WHEN t.year >= date_part('year', CURRENT_DATE)::int - 7 THEN 1.35 ELSE 1.0 END DESC NULLS LAST, t.title ASC"
        }
        (SortField::RottenTomatoes, SortDir::Asc) => "r.rt_score ASC NULLS LAST, t.title ASC",
        (SortField::RottenTomatoes, SortDir::Desc) => "r.rt_score DESC NULLS LAST, t.title ASC",
        (SortField::Availability, SortDir::Asc) => {
            "(SELECT COALESCE(MAX(fr.available_peers), 0) FROM file_references fr WHERE fr.title_id = t.id) ASC, t.title ASC"
        }
        (SortField::Availability, SortDir::Desc) => {
            "(SELECT COALESCE(MAX(fr.available_peers), 0) FROM file_references fr WHERE fr.title_id = t.id) DESC, t.title ASC"
        }
        (SortField::ContinueWatching, SortDir::Asc) => "p.updated_at ASC, t.title ASC",
        (SortField::ContinueWatching, SortDir::Desc) => "p.updated_at DESC, t.title ASC",
    }
}
