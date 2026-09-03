use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use tracing::{info, warn};

use super::IngestContext;
use crate::db;
use crate::error::Result;
use crate::jackett::JackettClient;

#[allow(dead_code)]
pub async fn resume_incomplete_catalog(ctx: &IngestContext) -> Result<()> {
    if !ctx.config.live.jackett_configured() {
        return Ok(());
    }
    let pending = db::jackett_pending_titles(&ctx.pool, 0, 1).await?;
    if pending.is_empty() {
        let status = db::jackett_sync_status(&ctx.pool).await?;
        if status.last_full_sync_at.is_none() {
            db::jackett_finish_sync(&ctx.pool, true, None).await?;
        }
        info!("Jackett catalog cache is ready; skipping rebuild on startup");
        return Ok(());
    }
    run_catalog_sync(ctx, false).await
}

pub async fn run_catalog_sync(ctx: &IngestContext, rebuild: bool) -> Result<()> {
    if !ctx.config.live.jackett_configured() {
        return Ok(());
    }
    if ctx
        .jackett_syncing
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        info!("Jackett catalog sync already running");
        return Ok(());
    }
    let result = run_catalog_sync_inner(ctx, rebuild).await;
    ctx.jackett_syncing.store(false, Ordering::SeqCst);
    result
}

async fn run_catalog_sync_inner(ctx: &IngestContext, rebuild: bool) -> Result<()> {
    if rebuild {
        db::jackett_reset_checked(&ctx.pool).await?;
    }
    let initial = db::jackett_sync_status(&ctx.pool)
        .await?
        .last_full_sync_at
        .is_none();
    let total = db::title_count(&ctx.pool).await? as i32;
    let pending = db::jackett_pending_titles(
        &ctx.pool,
        if rebuild || initial { 0 } else { 24 },
        20_000,
    )
    .await?;
    if pending.is_empty() {
        db::jackett_finish_sync(&ctx.pool, true, None).await?;
        info!(total, "Jackett catalog cache is complete");
        return Ok(());
    }
    let already = db::jackett_checked_count(&ctx.pool).await?;
    db::jackett_begin_sync(&ctx.pool, total, rebuild).await?;
    if !rebuild && already > 0 {
        let _ = db::jackett_bump_progress(&ctx.pool, already, total.max(1)).await;
    }
    info!(
        total,
        pending = pending.len(),
        already,
        rebuild,
        initial,
        "Jackett catalog sync started"
    );

    let client = match JackettClient::from_live(&ctx.http, &ctx.config.live) {
        Ok(c) => c,
        Err(e) => {
            let msg = e.to_string();
            warn!(error = %msg, "Jackett catalog sync could not start");
            db::jackett_finish_sync(&ctx.pool, true, Some(&msg)).await?;
            return Ok(());
        }
    };
    let resolution = ctx.config.live.streaming_resolution();
    let done = Arc::new(AtomicI32::new(already));
    let fail = Arc::new(AtomicBool::new(false));
    let mut set = tokio::task::JoinSet::new();
    let mut pending = pending.into_iter();

    while set.len() < 8 {
        let Some(work) = pending.next() else { break };
        queue_index(
            &mut set,
            work,
            ctx.pool.clone(),
            client.clone(),
            resolution.clone(),
            done.clone(),
            fail.clone(),
            total.max(1),
        );
    }
    while set.join_next().await.is_some() {
        if let Some(work) = pending.next() {
            queue_index(
                &mut set,
                work,
                ctx.pool.clone(),
                client.clone(),
                resolution.clone(),
                done.clone(),
                fail.clone(),
                total.max(1),
            );
        }
    }

    let had_error = fail.load(Ordering::Relaxed);
    db::jackett_finish_sync(
        &ctx.pool,
        initial || rebuild,
        had_error.then_some("Some titles could not be indexed"),
    )
    .await?;
    info!(
        done = done.load(Ordering::Relaxed),
        "Jackett catalog sync finished"
    );
    Ok(())
}

fn queue_index(
    set: &mut tokio::task::JoinSet<()>,
    work: db::JackettTitleWork,
    pool: sqlx::PgPool,
    client: JackettClient,
    resolution: String,
    done: Arc<AtomicI32>,
    fail: Arc<AtomicBool>,
    work_total: i32,
) {
    set.spawn(async move {
        if let Err(e) = index_one(&client, &pool, &work, &resolution).await {
            warn!(title = %work.title, error = %e, "Jackett title index failed");
            fail.store(true, Ordering::Relaxed);
        }
        let n = done.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = db::jackett_bump_progress(&pool, n, work_total.max(1)).await;
    });
}

async fn index_one(
    client: &JackettClient,
    pool: &sqlx::PgPool,
    work: &db::JackettTitleWork,
    resolution: &str,
) -> Result<()> {
    let _ = (client, resolution);
    db::jackett_mark_checked(pool, work.id).await?;
    Ok(())
}

#[allow(dead_code)]
pub fn spawn_catalog_sync(ctx: IngestContext, rebuild: bool) {
    tokio::spawn(async move {
        if let Err(e) = run_catalog_sync(&ctx, rebuild).await {
            warn!(error = %e, "Jackett catalog sync stopped");
        }
    });
}