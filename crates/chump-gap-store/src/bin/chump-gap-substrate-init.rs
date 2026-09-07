//! `chump-gap-substrate-init` — INFRA-3631 / INFRA-5402 slice.
//!
//! Applies the shared-fleet queue schema (`shared_gaps`, `shared_claims`,
//! `worker_capabilities`, plus the `teams` table they FK against) to a
//! Postgres database via
//! [`chump_gap_store::backend::postgres::PostgresBackend::init_shared_schema`],
//! replacing the previous approach of piping the checked-in
//! `supabase/migrations/000{1,2}_*.sql` files through `psql`.
//!
//! Every statement `init_shared_schema` runs is idempotent
//! (`CREATE ... IF NOT EXISTS`), so re-running against an already-initialized
//! database is a clean no-op — exit 0, no attempt to recreate existing
//! objects.
//!
//! Usage:
//!   chump-gap-substrate-init <libpq-connection-string>
//!   chump-gap-substrate-init   # reads CHUMP_SUBSTRATE_PG_CONN instead

use std::process::ExitCode;

use chump_gap_store::backend::postgres::PostgresBackend;

fn main() -> ExitCode {
    let conn_str = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("CHUMP_SUBSTRATE_PG_CONN").ok());

    let conn_str = match conn_str {
        Some(c) => c,
        None => {
            eprintln!(
                "usage: chump-gap-substrate-init <libpq-connection-string>\n\
                 (or set CHUMP_SUBSTRATE_PG_CONN)"
            );
            return ExitCode::from(2);
        }
    };

    // `open` also runs the base `init_schema` (the single-node "gaps" table
    // from INFRA-2092) as a side effect — harmless and idempotent, but not
    // what this tool is for; `init_shared_schema` below is the actual point.
    let backend = match PostgresBackend::open(&conn_str) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[chump-gap-substrate-init] connect failed: {:#}", e);
            return ExitCode::from(1);
        }
    };

    match backend.init_shared_schema() {
        Ok(()) => {
            println!(
                "[chump-gap-substrate-init] schema applied: teams, shared_gaps, \
                 shared_claims, worker_capabilities (idempotent, no-op if already present)"
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!(
                "[chump-gap-substrate-init] init_shared_schema failed: {:#}",
                e
            );
            ExitCode::from(1)
        }
    }
}
