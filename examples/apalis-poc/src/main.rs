//! Minimal offline PoC: one SQLite-backed job, one worker, one successful completion.
//! Run: `cargo run --manifest-path examples/apalis-poc/Cargo.toml`

use apalis::prelude::*;
use apalis_sqlite::SqliteStorage;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PurgeStaleLeases {
    max_age_secs: u64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pool = apalis_sqlite::SqlitePool::connect(":memory:").await?;
    SqliteStorage::setup(&pool).await?;
    let mut storage = SqliteStorage::new(&pool);
    storage
        .push(PurgeStaleLeases { max_age_secs: 3600 })
        .await?;

    async fn work(job: PurgeStaleLeases, ctx: WorkerContext) -> Result<(), BoxDynError> {
        println!("handled purge job (max_age_secs={})", job.max_age_secs);
        ctx.stop()?;
        Ok(())
    }

    let worker = WorkerBuilder::new("chump-apalis-poc")
        .backend(storage)
        .build(work);
    worker.run().await?;
    Ok(())
}
