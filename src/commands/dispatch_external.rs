//! INFRA-3289 (slice 1 of INFRA-3287 main.rs decomposition): dispatch for the
//! external-repo command group — `onboard`, `improve`, `external verify-merge`.
//!
//! Extracted verbatim from `main()`'s argv chain. `try_dispatch` returns
//! `Some(exit_code)` if it handled the command, `None` otherwise, so `main()`
//! stays a thin switchboard: `if let Some(c) = dispatch_external::try_dispatch(&args) { exit(c) }`.
//! Pure move — no behavior change.

/// Handle the external-repo command group. Returns `Some(exit_code)` when a
/// command in this group matched, `None` to let the next dispatcher try.
pub fn try_dispatch(args: &[String]) -> Option<i32> {
    // `chump onboard <repo-url-or-path>` (INFRA-2108, META-123 Wave 2) —
    // first-touch external-repo scanner: shallow-clone, read intent docs,
    // propose 5–10 next-step gaps via provider cascade, print markdown table.
    // --apply reserves each gap with skills_required: external_repo:<owner>/<repo>.
    if args.get(1).map(String::as_str) == Some("onboard") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::onboard::run(&sub_args));
    }

    // `chump improve <owner/repo>` (EFFECTIVE-177) — autonomous external-repo
    // improve loop (Mode-D path). Chains 4 stages:
    //   1. PICK      — scout via onboard scan (ExternalRepoContract / OnboardScan)
    //   2. DEDUP     — skip if work already done (ZERO-WASTE-006)
    //   3. IMPLEMENT — spawn claude -p agent in the clone; open external PR
    //   4. VERIFY-MERGE — delegate to `chump external verify-merge` (CREDIBLE-096)
    // Dry-run by default; --apply executes for real.
    if args.get(1).map(String::as_str) == Some("improve") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        return Some(crate::improve::run(&sub_args));
    }

    // `chump external verify-merge` (CREDIBLE-096) — autonomous PR merge judge.
    // Decides whether a PR on an external repo meets the bar for autonomous merge:
    //   Gate 1: repo CI green (zero checks → HELD(no-gates))
    //   Gate 2: anti-cosmetic — diff adds a test that fails-on-base, passes-on-head
    //   Gate 3: no-regression (covered by CI gate 1 unless CHUMP_EXTERNAL_VERIFY_FULL_SUITE=1)
    // Dry-run by default; --apply executes the merge.
    // Kill-switch: CHUMP_EXTERNAL_VERIFY_MERGE_DISABLED=1
    if args.get(1).map(String::as_str) == Some("external")
        && args.get(2).map(String::as_str) == Some("verify-merge")
    {
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        return Some(crate::external_verify_merge::run(&sub_args));
    }

    None
}
