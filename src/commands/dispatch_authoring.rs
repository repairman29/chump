//! INFRA-3298 (slice 2 of INFRA-3287 main.rs decomposition): dispatch for the
//! INFRA-2399 author-time helper commands — small scaffolding CLIs that keep a
//! *later* PR from tripping a CI coverage gate (env-var / event-registry /
//! install-manifest / path-filter / raw-gh-allowlist).
//!
//! Extracted verbatim from `main()`'s argv chain. `try_dispatch` returns
//! `Some(exit_code)` when it handled the command, `None` otherwise, so `main()`
//! stays a thin switchboard. Pure move — no behavior change.

/// Handle the author-time helper command group. Returns `Some(exit_code)` when a
/// command in this group matched, `None` to let the next dispatcher try.
pub fn try_dispatch(args: &[String]) -> Option<i32> {
    // `chump add-env-var <NAME> --tier 1|2|3 [--gap-id X]` (INFRA-2399) —
    // author-time helper: adds a new env var to .env.example (tier 1) or
    // scripts/ci/env-vars-internal.txt (tier 2/3). Prevents CI env-var-coverage
    // gate from firing on the NEXT PR. CRITICAL: never inline comments on the
    // var line — audit treats whole line as var name.
    if args.get(1).map(String::as_str) == Some("add-env-var") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::commands::add_env_var::run(&sub_args));
    }

    // `chump emit-event <kind> [--gap-id X] [--description "..."]` (INFRA-2399) —
    // author-time helper: registers a new event kind in
    // docs/observability/EVENT_REGISTRY.yaml. Prevents CI event-registry-coverage
    // gate failures on the next PR.
    if args.get(1).map(String::as_str) == Some("emit-event") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::commands::emit_event::run(&sub_args));
    }

    // `chump install-daemon <stem> --kind required|optional|deprecated [--gap-id X]`
    // (INFRA-2399) — author-time helper: registers a new install script in the
    // correct bootstrap manifest (REQUIRED_DAEMONS or allowlist). Prevents CI
    // install-manifest gate failures on the next PR.
    if args.get(1).map(String::as_str) == Some("install-daemon") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::commands::install_daemon::run(&sub_args));
    }

    // `chump add-path-filter <dir>` (INFRA-2399) — author-time helper: inserts
    // a new `- '<dir>/**'` entry into the `code:` paths-filter block in
    // .github/workflows/ci.yml. Prevents INFRA-272/682 stuck-PR class.
    if args.get(1).map(String::as_str) == Some("add-path-filter") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::commands::add_path_filter::run(&sub_args));
    }

    // `chump add-raw-gh-allowlist <script-path> --migration-gap <ID>` (INFRA-2399) —
    // author-time helper: registers a script in scripts/ci/raw-gh-allowlist.txt
    // (INFRA-1274 cache-first mandate). --migration-gap is required as audit trail.
    if args.get(1).map(String::as_str) == Some("add-raw-gh-allowlist") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::commands::add_raw_gh_allowlist::run(&sub_args));
    }

    None
}
