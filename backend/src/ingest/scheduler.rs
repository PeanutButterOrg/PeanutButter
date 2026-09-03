use tracing::{error, info};
use tokio_cron_scheduler::{Job, JobScheduler};

use super::{run_full_sync, IngestContext};
use crate::error::Result;

pub async fn start(ctx: IngestContext) -> Result<JobScheduler> {
    let sched = JobScheduler::new().await.map_err(|e| {
        crate::error::AppError::Internal(format!("scheduler init failed: {e}"))
    })?;

    let popular = ctx.clone();
    let cron_popular = ctx.config.sync_cron_popular.clone();
    sched
        .add(
            Job::new_async(cron_popular.as_str(), move |_uuid, _lock| {
                let popular = popular.clone();
                Box::pin(async move {
                    info!("scheduled popular/trending sync");
                    if let Err(e) = run_full_sync(&popular).await {
                        error!(error = %e, "scheduled sync failed");
                    }
                })
            })
            .map_err(|e| crate::error::AppError::Internal(format!("popular cron: {e}")))?,
        )
        .await
        .map_err(|e| crate::error::AppError::Internal(format!("add popular job: {e}")))?;

    let stale = ctx.clone();
    let cron_stale = ctx.config.sync_cron_stale.clone();
    sched
        .add(
            Job::new_async(cron_stale.as_str(), move |_uuid, _lock| {
                let stale = stale.clone();
                Box::pin(async move {
                    info!("scheduled stale-title refresh");
                    if let Err(e) = super::refresh_stale(&stale).await {
                        error!(error = %e, "stale refresh failed");
                    }
                    if stale.config.live.jackett_configured() {
                        if let Err(e) = super::jackett::run_catalog_sync(&stale, false).await {
                            error!(error = %e, "Jackett catalog refresh failed");
                        }
                    }
                })
            })
            .map_err(|e| crate::error::AppError::Internal(format!("stale cron: {e}")))?,
        )
        .await
        .map_err(|e| crate::error::AppError::Internal(format!("add stale job: {e}")))?;

    sched
        .start()
        .await
        .map_err(|e| crate::error::AppError::Internal(format!("scheduler start: {e}")))?;
    info!(
        popular = %ctx.config.sync_cron_popular,
        stale = %ctx.config.sync_cron_stale,
        "ingest scheduler started"
    );
    Ok(sched)
}
