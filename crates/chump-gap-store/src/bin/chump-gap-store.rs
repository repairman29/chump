//! `chump-gap-store` — CLI entrypoint for the checked-in shared gap-store
//! migrations (INFRA-4775, INFRA-3631 slice).
//!
//! `install-gap-substrate.sh`'s SCHEMA phase used to pipe
//! `supabase/migrations/0001_team_foundation.sql` + `0002_shared_gaps.sql`
//! through `psql` by hand. This binary wraps the same checked-in migration
//! files behind one idempotent Rust entrypoint
//! ([`chump_gap_store::backend::postgres::apply_shared_gap_store_migrations`])
//! so the provisioning script has a single command to call instead of
//! inlining SQL-application logic.
//!
//! ## Subcommands
//!
//! - `init-schema --db-url <conn-str> [--migrations-dir <dir>]` — apply the
//!   migrations if `shared_gaps` is missing; print "schema already
//!   up-to-date" and exit 0 if it's already there.

use std::path::PathBuf;
use std::process::ExitCode;

use chump_gap_store::backend::postgres::apply_shared_gap_store_migrations;
use postgres::{Client, NoTls};

fn usage() {
    eprintln!("usage: chump-gap-store init-schema --db-url <conn-str> [--migrations-dir <dir>]");
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) != Some("init-schema") {
        usage();
        return ExitCode::from(2);
    }

    let mut db_url: Option<String> = std::env::var("CHUMP_GAP_STORE_DB_URL").ok();
    let mut migrations_dir: Option<PathBuf> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--db-url" => {
                i += 1;
                db_url = args.get(i).cloned();
            }
            "--migrations-dir" => {
                i += 1;
                migrations_dir = args.get(i).map(PathBuf::from);
            }
            other => {
                eprintln!("[chump-gap-store] unknown arg: {other}");
                usage();
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let Some(db_url) = db_url else {
        eprintln!("[chump-gap-store] missing --db-url (or CHUMP_GAP_STORE_DB_URL)");
        return ExitCode::from(2);
    };
    let migrations_dir = migrations_dir.unwrap_or_else(|| PathBuf::from("supabase/migrations"));

    let mut client = match Client::connect(&db_url, NoTls) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[chump-gap-store] connect failed: {e:#}");
            return ExitCode::FAILURE;
        }
    };

    match apply_shared_gap_store_migrations(&mut client, &migrations_dir) {
        Ok(true) => {
            println!("schema already up-to-date");
            ExitCode::SUCCESS
        }
        Ok(false) => {
            println!("schema applied");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[chump-gap-store] init-schema failed: {e:#}");
            ExitCode::FAILURE
        }
    }
}
