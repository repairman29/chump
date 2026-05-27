//! `chump-check-gaps-integrity` — Rust port of
//! `scripts/coord/check-gaps-integrity.py` (Phase 1 of INFRA-2000 /
//! META-107).
//!
//! Matches the Python tool's CLI surface 1:1:
//!
//! ```text
//! chump-check-gaps-integrity [--per-file DIR] [PATH]
//! ```
//!
//! Where `PATH` is the monolithic `docs/gaps.yaml` (default) and
//! `--per-file DIR` switches to the post-INFRA-188 canonical per-file
//! layout. Exits non-zero on any failure (duplicate IDs, missing IDs,
//! YAML parse error).

use std::path::PathBuf;
use std::process::ExitCode;

use chump_gap_store::maintenance::integrity::{check_gaps_integrity, IntegritySource};

fn usage() {
    eprintln!("usage: chump-check-gaps-integrity [--per-file DIR] [PATH]");
}

fn main() -> ExitCode {
    let raw_args: Vec<String> = std::env::args().skip(1).collect();
    let mut per_file: Option<PathBuf> = None;
    let mut path_arg: Option<PathBuf> = None;
    let mut i = 0;
    while i < raw_args.len() {
        match raw_args[i].as_str() {
            "--per-file" => {
                per_file = raw_args.get(i + 1).map(PathBuf::from);
                if per_file.is_none() {
                    usage();
                    return ExitCode::from(2);
                }
                i += 2;
                continue;
            }
            "-h" | "--help" => {
                usage();
                return ExitCode::SUCCESS;
            }
            other => {
                if other.starts_with("--") {
                    eprintln!("[chump-check-gaps-integrity] unknown flag: {}", other);
                    usage();
                    return ExitCode::from(2);
                }
                path_arg = Some(PathBuf::from(other));
            }
        }
        i += 1;
    }

    let source = match per_file {
        Some(d) => IntegritySource::PerFile(d),
        None => {
            IntegritySource::Monolithic(path_arg.unwrap_or_else(|| PathBuf::from("docs/gaps.yaml")))
        }
    };
    let report = match check_gaps_integrity(&source) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-check-gaps-integrity] {}", e);
            return ExitCode::from(1);
        }
    };
    let rendered = report.render();
    if report.failing() {
        eprint!("{}", rendered);
        ExitCode::from(1)
    } else {
        print!("{}", rendered);
        ExitCode::SUCCESS
    }
}
