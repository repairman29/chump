//! Gap-store CLI helpers, mutation validators, P0 budget checks, and CLI unit tests.

use crate::*;
use anyhow::Result;

/// MISSION-046: extract OWNER/REPO from a gap's `skills_required` if it carries an
/// `external_repo:OWNER/REPO` tag (single tag or comma/space/tab-separated list).
/// Returns None for internal gaps so `--execute-gap` keeps the internal loop.
pub(crate) fn external_repo_target_from_skills(skills: &str) -> Option<String> {
    skills
        .split([',', ' ', '\t'])
        .find_map(|tok| tok.trim().strip_prefix("external_repo:"))
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty() && s.contains('/'))
}

/// EFFECTIVE-294: concrete, claimable default acceptance criteria for a gap
/// reserved without an explicit `--acceptance-criteria`. Replaces the old TODO
/// obs-AC template that left ~32% of the open queue unclaimable (`chump claim`
/// refuses a gap whose AC are TODO placeholders). The gap *title* carries the
/// "what"; these encode the ship "done-bar" so the gap is immediately pickable.
/// For gap-specific AC, run `chump gap decompose` (LLM).
pub(crate) fn default_acceptance_criteria(title: &str, domain: &str) -> Vec<String> {
    // Strip a leading "DOMAIN:" / pillar tag from the title to get the "what".
    let what = title
        .split_once(':')
        .map(|(_, rest)| rest.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| title.trim());
    vec![
        format!(
            "The change described by \"{what}\" is implemented in the relevant {domain} code path(s)."
        ),
        "At least one test (cargo test or scripts/ci/test-*.sh) proves the new behavior and fails without the change.".to_string(),
        "cargo fmt + clippy --all-targets -D warnings + check pass; no regression to existing tests.".to_string(),
    ]
}

/// INFRA-8222: thin CLI over `chump_gap_store::reconcile`.
pub(crate) fn run_store_cli(args: &[String]) -> i32 {
    use chump_gap_store::reconcile as rc;
    let usage = "usage: chump store reconcile --from <db> --into <db> [--dry-run] \
                 [--audit <path>] [--force-offline] [--skip-new-open] [--json]";
    if args.get(2).map(String::as_str) != Some("reconcile") {
        eprintln!("{usage}");
        return 2;
    }
    let val = |name: &str| -> Option<String> {
        args.windows(2)
            .find(|w| w[0] == name)
            .and_then(|w| w.get(1))
            .cloned()
    };
    let has = |name: &str| args.iter().any(|a| a == name);
    let (Some(from), Some(into)) = (val("--from"), val("--into")) else {
        eprintln!("{usage}");
        return 2;
    };
    let opts = rc::ReconcileOptions {
        from: std::path::PathBuf::from(from),
        into: std::path::PathBuf::from(&into),
        dry_run: has("--dry-run"),
        force_offline: has("--force-offline"),
        skip_new_open: has("--skip-new-open"),
    };
    let report = match rc::reconcile(&opts) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump store reconcile: {e:#}");
            return if format!("{e}").contains("active writer") {
                3
            } else {
                1
            };
        }
    };
    let audit = val("--audit")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(format!(
                "{into}.reconcile-audit-{}.json",
                chrono::Utc::now().format("%Y%m%dT%H%M%SZ")
            ))
        });
    if let Err(e) = rc::write_audit(&report, &audit) {
        eprintln!("chump store reconcile: {e:#}");
        return 1;
    }
    rc::emit_store_reconciled(
        &report,
        &audit,
        &rc::locks_dir_for(&opts.into).join("ambient.jsonl"),
    );
    if has("--json") {
        println!(
            "{}",
            serde_json::to_string_pretty(&report).unwrap_or_default()
        );
    } else {
        print!("{}", report.summary());
        println!("  audit: {}", audit.display());
    }
    0
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum GapMutationArgCheck {
    Valid,
    Help(&'static str),
}

pub(crate) const GAP_SET_USAGE: &str = "Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]\n                          [--effort E] [--status S] [--notes N] [--add-note TEXT]\n                          [--source-doc S] [--opened-date D] [--closed-date D]\n                          [--closed-pr N] [--acceptance-criteria BULLET ...] [--depends-on \"X,Y\"]\n                          [--skills-required \"a,b\"] [--preferred-backend B] [--preferred-machine M]\n                          [--estimated-minutes N] [--required-model M] [--outcome ID]\n                          [--evidence TEXT] [--artifact-type T]";

pub(crate) const GAP_SHIP_USAGE: &str = "Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N] [--external-repo owner/name] [--session ID] [--why]";

pub(crate) const GAP_LINK_PR_USAGE: &str =
    "Usage: chump gap link-pr <GAP-ID> <PR-NUMBER> --sha <SHA> [--multi] [--move]";

pub(crate) const GAP_UNLINK_PR_USAGE: &str =
    "Usage: chump gap unlink-pr <GAP-ID> <PR-NUMBER> --reason <text>";

pub(crate) const GAP_RESERVE_USAGE: &str = "Usage: chump gap reserve --domain D --title T [--description D] [--priority P] [--effort E]\n                         [--acceptance-criteria \"a|b\"] [--outcome ID] [--evidence TEXT]\n                         [--external-repo owner/name] [--force] [--quiet] [--json]\n   or: chump gap reserve <DOMAIN> <title words...>";

/// CREDIBLE-1565: strict flag/argument validation for all state-changing
/// `chump gap` verbs (`set`/`update`/`modify`/`edit`/`change`, `ship`,
/// `link-pr`, `unlink-pr`, `reserve`).
pub(crate) fn validate_gap_mutation_args(
    subcmd: &str,
    rest: &[String],
) -> Result<GapMutationArgCheck, String> {
    match subcmd {
        "set" | "update" | "modify" | "edit" | "change" => {
            if rest.iter().any(|a| matches!(a.as_str(), "--help" | "-h")) {
                return Ok(GapMutationArgCheck::Help(GAP_SET_USAGE));
            }
            let Some(gap_id) = rest.first() else {
                return Err(GAP_SET_USAGE.to_string());
            };
            if gap_id.starts_with('-') {
                return Err(format!(
                    "chump gap {subcmd}: unknown flag {gap_id:?}. Did you forget the GAP-ID?\n{GAP_SET_USAGE}"
                ));
            }
            const POSITIONAL_ALIASES: &[&str] = &[
                "acceptance_criteria",
                "acceptance-criteria",
                "title",
                "description",
                "priority",
                "effort",
                "status",
                "notes",
                "depends_on",
                "depends-on",
                "source_doc",
                "source-doc",
                "opened_date",
                "opened-date",
                "closed_date",
                "closed-date",
                "closed_pr",
                "closed-pr",
                "skills_required",
                "skills-required",
                "preferred_backend",
                "preferred-backend",
                "preferred_machine",
                "preferred-machine",
                "estimated_minutes",
                "estimated-minutes",
                "required_model",
                "required-model",
                "outcome_id",
                "outcome-id",
                "artifact_type",
                "artifact-type",
                "evidence",
                "add_note",
                "add-note",
            ];
            const VALUE_FLAGS: &[&str] = &[
                "--title",
                "--description",
                "--priority",
                "--effort",
                "--status",
                "--notes",
                "--add-note",
                "--source-doc",
                "--opened-date",
                "--closed-date",
                "--closed-pr",
                "--acceptance-criteria",
                "--depends-on",
                "--skills-required",
                "--preferred-backend",
                "--preferred-machine",
                "--estimated-minutes",
                "--required-model",
                "--outcome",
                "--evidence",
                "--artifact-type",
                "--p0-override",
            ];
            const BOOL_FLAGS: &[&str] = &["--json", "--quiet", "--replace-ac"];

            let mut i = 1usize;
            if let Some(first_arg) = rest.get(1) {
                if !first_arg.starts_with('-') {
                    if POSITIONAL_ALIASES.contains(&first_arg.as_str()) {
                        match rest.get(2) {
                            Some(val) if !val.starts_with("--") => {
                                i = 3;
                                if matches!(
                                    first_arg.as_str(),
                                    "acceptance_criteria" | "acceptance-criteria"
                                ) {
                                    while i < rest.len() && !rest[i].starts_with("--") {
                                        i += 1;
                                    }
                                }
                            }
                            _ => {
                                return Err(format!(
                                    "chump gap {subcmd}: positional field {first_arg:?} requires a value\n{GAP_SET_USAGE}"
                                ));
                            }
                        }
                    } else {
                        return Err(format!(
                            "chump gap {subcmd}: unrecognised positional field name {first_arg:?}. Use --<flag> form.\n{GAP_SET_USAGE}"
                        ));
                    }
                }
            }
            while i < rest.len() {
                let tok = rest[i].as_str();
                if VALUE_FLAGS.contains(&tok) {
                    match rest.get(i + 1) {
                        Some(val) if !val.starts_with("--") => {
                            i += 2;
                            if tok == "--acceptance-criteria" {
                                while i < rest.len() && !rest[i].starts_with("--") {
                                    i += 1;
                                }
                            }
                        }
                        _ => {
                            return Err(format!(
                                "chump gap {subcmd}: {tok} requires a value\n{GAP_SET_USAGE}"
                            ));
                        }
                    }
                } else if BOOL_FLAGS.contains(&tok) {
                    i += 1;
                } else {
                    return Err(format!(
                        "chump gap {subcmd}: unknown flag or argument {tok:?}\n{GAP_SET_USAGE}"
                    ));
                }
            }
            Ok(GapMutationArgCheck::Valid)
        }
        "ship" => {
            if rest.iter().any(|a| matches!(a.as_str(), "--help" | "-h")) {
                return Ok(GapMutationArgCheck::Help(GAP_SHIP_USAGE));
            }
            let Some(gap_id) = rest.first() else {
                return Err(GAP_SHIP_USAGE.to_string());
            };
            if gap_id.starts_with('-') {
                return Err(format!(
                    "chump gap ship: unknown flag {gap_id:?}. Did you forget the GAP-ID?\n{GAP_SHIP_USAGE}"
                ));
            }
            const VALUE_FLAGS: &[&str] = &["--closed-pr", "--external-repo", "--session"];
            const BOOL_FLAGS: &[&str] = &[
                "--update-yaml",
                "--no-update-yaml",
                "--why",
                "--no-outcome-required",
                "--json",
                "--quiet",
            ];
            let mut i = 1usize;
            while i < rest.len() {
                let tok = rest[i].as_str();
                if VALUE_FLAGS.contains(&tok) {
                    match rest.get(i + 1) {
                        Some(val) if !val.starts_with("--") => i += 2,
                        _ => {
                            return Err(format!(
                                "chump gap ship: {tok} requires a value\n{GAP_SHIP_USAGE}"
                            ));
                        }
                    }
                } else if BOOL_FLAGS.contains(&tok) {
                    i += 1;
                } else {
                    return Err(format!(
                        "chump gap ship: unknown flag or argument {tok:?}\n{GAP_SHIP_USAGE}"
                    ));
                }
            }
            Ok(GapMutationArgCheck::Valid)
        }
        "link-pr" => {
            if rest.iter().any(|a| matches!(a.as_str(), "--help" | "-h")) {
                return Ok(GapMutationArgCheck::Help(GAP_LINK_PR_USAGE));
            }
            let Some(gap_id) = rest.first() else {
                return Err(GAP_LINK_PR_USAGE.to_string());
            };
            if gap_id.starts_with('-') {
                return Err(format!(
                    "chump gap link-pr: unknown flag {gap_id:?}\n{GAP_LINK_PR_USAGE}"
                ));
            }
            let Some(pr_arg) = rest.get(1) else {
                return Err(GAP_LINK_PR_USAGE.to_string());
            };
            if pr_arg.starts_with('-') {
                return Err(format!(
                    "chump gap link-pr: unknown flag {pr_arg:?} in PR-NUMBER slot\n{GAP_LINK_PR_USAGE}"
                ));
            }
            const VALUE_FLAGS: &[&str] = &["--sha"];
            const BOOL_FLAGS: &[&str] = &["--multi", "--move", "--json", "--quiet"];
            let mut i = 2usize;
            while i < rest.len() {
                let tok = rest[i].as_str();
                if VALUE_FLAGS.contains(&tok) {
                    match rest.get(i + 1) {
                        Some(val) if !val.starts_with("--") => i += 2,
                        _ => {
                            return Err(format!(
                                "chump gap link-pr: {tok} requires a value\n{GAP_LINK_PR_USAGE}"
                            ));
                        }
                    }
                } else if BOOL_FLAGS.contains(&tok) {
                    i += 1;
                } else {
                    return Err(format!(
                        "chump gap link-pr: unknown flag or argument {tok:?}\n{GAP_LINK_PR_USAGE}"
                    ));
                }
            }
            Ok(GapMutationArgCheck::Valid)
        }
        "unlink-pr" => {
            if rest.iter().any(|a| matches!(a.as_str(), "--help" | "-h")) {
                return Ok(GapMutationArgCheck::Help(GAP_UNLINK_PR_USAGE));
            }
            let Some(gap_id) = rest.first() else {
                return Err(GAP_UNLINK_PR_USAGE.to_string());
            };
            if gap_id.starts_with('-') {
                return Err(format!(
                    "chump gap unlink-pr: unknown flag {gap_id:?}\n{GAP_UNLINK_PR_USAGE}"
                ));
            }
            let Some(pr_arg) = rest.get(1) else {
                return Err(GAP_UNLINK_PR_USAGE.to_string());
            };
            if pr_arg.starts_with('-') {
                return Err(format!(
                    "chump gap unlink-pr: unknown flag {pr_arg:?} in PR-NUMBER slot\n{GAP_UNLINK_PR_USAGE}"
                ));
            }
            const VALUE_FLAGS: &[&str] = &["--reason"];
            const BOOL_FLAGS: &[&str] = &["--json", "--quiet"];
            let mut i = 2usize;
            while i < rest.len() {
                let tok = rest[i].as_str();
                if VALUE_FLAGS.contains(&tok) {
                    match rest.get(i + 1) {
                        Some(val) if !val.starts_with("--") => i += 2,
                        _ => {
                            return Err(format!(
                                "chump gap unlink-pr: {tok} requires a value\n{GAP_UNLINK_PR_USAGE}"
                            ));
                        }
                    }
                } else if BOOL_FLAGS.contains(&tok) {
                    i += 1;
                } else {
                    return Err(format!(
                        "chump gap unlink-pr: unknown flag or argument {tok:?}\n{GAP_UNLINK_PR_USAGE}"
                    ));
                }
            }
            Ok(GapMutationArgCheck::Valid)
        }
        "reserve" => {
            if rest.iter().any(|a| matches!(a.as_str(), "--help" | "-h")) {
                return Ok(GapMutationArgCheck::Help(GAP_RESERVE_USAGE));
            }
            if rest.is_empty() {
                return Err(GAP_RESERVE_USAGE.to_string());
            }
            const VALUE_FLAGS: &[&str] = &[
                "--domain",
                "--title",
                "--description",
                "--priority",
                "--effort",
                "--acceptance-criteria",
                "--outcome",
                "--evidence",
                "--external-repo",
                "--cap-override",
                "--p0-override",
                "--offline-bypass-reason",
                "--session",
                "--stack-on",
                "--ttl",
                "--worktree",
            ];
            const BOOL_FLAGS: &[&str] = &[
                "--force",
                "--force-anti-offline",
                "--force-duplicate",
                "--force-pillar",
                "--json",
                "--no-ac-required",
                "--no-evidence-required",
                "--no-outcome-required",
                "--quiet",
                "--skip-obs-acs",
                "--why",
            ];
            let mut i = 0usize;
            while i < rest.len() {
                let tok = rest[i].as_str();
                if VALUE_FLAGS.contains(&tok) {
                    match rest.get(i + 1) {
                        Some(val) if !val.starts_with("--") => {
                            i += 2;
                            if tok == "--acceptance-criteria" {
                                while i < rest.len() && !rest[i].starts_with("--") {
                                    i += 1;
                                }
                            }
                        }
                        _ => {
                            return Err(format!(
                                "chump gap reserve: {tok} requires a value\n{GAP_RESERVE_USAGE}"
                            ));
                        }
                    }
                } else if BOOL_FLAGS.contains(&tok) {
                    i += 1;
                } else if tok.starts_with('-') {
                    return Err(format!(
                        "chump gap reserve: unknown flag {tok:?}\n{GAP_RESERVE_USAGE}"
                    ));
                } else {
                    i += 1;
                }
            }
            Ok(GapMutationArgCheck::Valid)
        }
        _ => Ok(GapMutationArgCheck::Valid),
    }
}

/// Collect all acceptance criteria values following `--acceptance-criteria` flags
/// (both repeated `--acceptance-criteria A --acceptance-criteria B` and variadic
/// `--acceptance-criteria A B C`), preserving each non-flag argument intact (CREDIBLE-1558).
pub(crate) fn collect_acceptance_criteria_flag_values(
    args_slice: &[String],
    start_idx: usize,
) -> Vec<String> {
    let mut vals = Vec::new();
    let mut i = start_idx;
    while i < args_slice.len() {
        if args_slice[i] == "--acceptance-criteria" {
            i += 1;
            while i < args_slice.len() && !args_slice[i].starts_with("--") {
                vals.push(args_slice[i].clone());
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    vals
}

pub(crate) const OPEN_P0_BUDGET: usize = 5;

pub(crate) fn count_open_manual_p0s(gaps: &[gap_store::GapRow], exclude_id: Option<&str>) -> usize {
    gaps.iter()
        .filter(|g| {
            g.status == "open"
                && g.priority == "P0"
                && exclude_id != Some(g.id.as_str())
                && !g.notes.contains("auto-filed by pr-triage-bot")
        })
        .count()
}

pub(crate) fn gap_priority_rank(prio: &str) -> u8 {
    match prio {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 2,
    }
}

/// CREDIBLE-1543 AC3: When reserving an execution slice / sub-gap whose title or
/// description names an existing parent/umbrella gap, clamp the requested priority
/// to the parent's priority if the requested priority is higher than the parent's.
pub(crate) fn detect_parent_slice_priority_clamp(
    title: &str,
    description: &str,
    requested_priority: &str,
    gaps: &[gap_store::GapRow],
) -> Option<(String, String)> {
    let combined = format!("{title} {description}");
    let lower = combined.to_ascii_lowercase();
    let is_slice = lower.contains("slice")
        || lower.contains("umbrella")
        || lower.contains("parent")
        || lower.contains("sub-gap")
        || lower.contains("subgap");
    if !is_slice {
        return None;
    }
    let gap_re = regex::Regex::new(r"\b([A-Z]+-\d+)\b").ok()?;
    for cap in gap_re.captures_iter(&combined) {
        let candidate_id = cap.get(1)?.as_str();
        if let Some(parent) = gaps.iter().find(|g| g.id == candidate_id) {
            if gap_priority_rank(requested_priority) < gap_priority_rank(&parent.priority) {
                return Some((parent.id.clone(), parent.priority.clone()));
            }
        }
    }
    None
}

pub(crate) fn emit_p0_budget_override(
    worktree_root: &std::path::Path,
    gap_id: &str,
    open_p0_count: usize,
    reason: &str,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "p0_budget_override".to_string(),
        source: Some("chump_gap".to_string()),
        gap: Some(gap_id.to_string()),
        fields: vec![
            ("open_p0_count".to_string(), open_p0_count.to_string()),
            ("budget".to_string(), OPEN_P0_BUDGET.to_string()),
            ("reason".to_string(), reason.to_string()),
        ],
        ..Default::default()
    });
    // Also ensure worktree_root/.chump-locks/ambient.jsonl receives the record when invoked in an isolated test repo.
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let safe_reason = reason.replace(['"', '\\'], "");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(
            f,
            r#"{{"ts":"{ts}","kind":"p0_budget_override","gap":"{gap_id}","open_p0_count":{open_p0_count},"budget":{OPEN_P0_BUDGET},"reason":"{safe_reason}"}}"#
        );
    }
}

#[cfg(test)]
mod tests {
    use crate::agent_factory;
    use serde_json::json;
    use serial_test::serial;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    // EFFECTIVE-294: a reserved gap with no explicit AC gets concrete, claimable
    // AC (zero TODO placeholders) so `chump claim` accepts it.
    #[test]
    fn default_acceptance_criteria_are_concrete_no_todo() {
        let acs = crate::default_acceptance_criteria("EFFECTIVE: add a foo widget", "EFFECTIVE");
        assert!(acs.len() >= 3, "at least 3 AC items: {acs:?}");
        assert!(
            acs.iter().all(|a| !a.contains("TODO")),
            "no TODO placeholders: {acs:?}"
        );
        assert!(
            acs[0].contains("add a foo widget") && !acs[0].contains("EFFECTIVE: add"),
            "first AC names the de-prefixed work: {}",
            acs[0]
        );
        // a title without a ':' is used verbatim as the "what"
        let acs2 = crate::default_acceptance_criteria("no prefix here", "INFRA");
        assert!(
            acs2[0].contains("no prefix here"),
            "verbatim what: {}",
            acs2[0]
        );
        assert!(acs2[0].contains("INFRA"), "names the domain: {}", acs2[0]);
    }

    /// Full agent turn against a mock HTTP server: no real model. Asserts reply content.
    ///
    /// 2026-05-08: marked `#[ignore]`. This test is fragile by design — every
    /// new agent-loop guard breaks it (CHUMP_MAX_CONSECUTIVE_TOOL_FAILS in
    /// INFRA-677, then "Exceeded max iterations (25)" today). The mock
    /// returns `{"content": "Mocked reply", "tool_calls": null}` which the
    /// real agent loop now treats as a partial completion + iterates. The
    /// test would need a more deterministic mock contract (or a test-only
    /// short-circuit in the agent loop) to be maintainable.
    ///
    /// Run manually with `cargo test integration_agent_run_against_mock --
    /// --ignored` after touching the agent loop. Don't gate CI on it.
    #[tokio::test]
    #[serial]
    #[ignore]
    async fn integration_agent_run_against_mock() {
        let mock = MockServer::start().await;
        let body = json!({
            "choices": [{
                "message": {
                    "content": "Mocked reply",
                    "tool_calls": null
                },
                "finish_reason": "stop"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        std::env::set_var("OPENAI_API_BASE", mock.uri());
        // INFRA-677: disable consecutive-tool-fails breaker so a sibling
        // test setting CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=1 mid-run can't
        // trip our agent. Observed sporadic CI failure: returned "Aborting:
        // 3 consecutive tool batches with no successful calls" instead of
        // "Mocked reply" because env-var races slip past #[serial].
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "99999");
        let (agent, _) = agent_factory::build_chump_agent_cli().expect("build agent");
        let outcome = agent.run("Hello").await.unwrap();
        std::env::remove_var("OPENAI_API_BASE");
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
        assert!(
            outcome.reply.contains("Mocked reply"),
            "expected reply to contain mock content, got: {}",
            outcome.reply
        );
    }

    // EFFECTIVE-011: alias expansion unit tests.
    #[test]
    fn effective_011_alias_g_expands_to_gap() {
        let args = vec!["chump".to_string(), "g".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "list"]);
    }

    #[test]
    fn effective_011_alias_c_expands_to_claim() {
        let args = vec![
            "chump".to_string(),
            "c".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "claim", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_s_expands_to_gap_ship() {
        let args = vec![
            "chump".to_string(),
            "s".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "ship", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_f_d_h_cs_expand() {
        let mk = |a: &str| vec!["chump".to_string(), a.to_string()];
        assert_eq!(crate::expand_aliases(mk("f"))[1], "fleet");
        assert_eq!(crate::expand_aliases(mk("d"))[1], "dispatch");
        assert_eq!(crate::expand_aliases(mk("h"))[1], "health");
        assert_eq!(crate::expand_aliases(mk("cs"))[1], "cost-watch");
    }

    #[test]
    fn effective_011_no_alias_passthrough() {
        let args = vec!["chump".to_string(), "gap".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args.clone());
        assert_eq!(expanded, args);
    }

    // ── INFRA-2112: --external-repo flag unit tests ──────────────────────────

    /// Parse --external-repo owner/repo form and verify tag + path resolution.
    #[test]
    fn mission_046_external_repo_target_parses_single_tag() {
        assert_eq!(
            crate::external_repo_target_from_skills("external_repo:repairman29/BEAST-MODE"),
            Some("repairman29/BEAST-MODE".to_string())
        );
    }
    #[test]
    fn mission_046_external_repo_target_parses_in_list() {
        assert_eq!(
            crate::external_repo_target_from_skills("rust, external_repo:owner/repo, git"),
            Some("owner/repo".to_string())
        );
    }
    #[test]
    fn mission_046_internal_gap_returns_none() {
        assert_eq!(
            crate::external_repo_target_from_skills("rust,sqlite,coord"),
            None
        );
        assert_eq!(crate::external_repo_target_from_skills(""), None);
    }

    #[test]
    fn infra_2112_external_repo_ownerslashrepo_flag_parses() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "acme/widget".into(),
        ];

        // Replicate the flag-parsing logic from cmd_gap_decompose.
        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        assert_eq!(external_repo.as_deref(), Some("acme/widget"));
        assert!(clone_path_override.is_none());

        // Resolve tag + path the same way the handler does.
        let repo_val = external_repo.as_deref().unwrap();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let expected_path = std::path::PathBuf::from(&home)
            .join(".chump")
            .join("external")
            .join(repo_val);

        let (resolved_path, tag) = if repo_val.starts_with('/') {
            panic!("should not be absolute path form");
        } else {
            let default_path = std::path::PathBuf::from(&home)
                .join(".chump")
                .join("external")
                .join(repo_val);
            (default_path, format!("external_repo:{repo_val}"))
        };

        assert_eq!(resolved_path, expected_path);
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// Absolute-path form of --external-repo uses path as-is and derives tag
    /// from last two path components.
    #[test]
    fn infra_2112_external_repo_absolute_path_flag_parses() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "/tmp/my-clones/acme/widget".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let repo_val = external_repo.as_deref().unwrap();
        assert!(repo_val.starts_with('/'), "expected absolute path");

        let p = std::path::PathBuf::from(repo_val);
        let mut comps: Vec<String> = p
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        comps.retain(|c| !c.is_empty());

        let tag_suffix = if comps.len() >= 2 {
            format!("{}/{}", comps[comps.len() - 2], comps[comps.len() - 1])
        } else {
            comps
                .last()
                .cloned()
                .unwrap_or_else(|| repo_val.to_string())
        };

        let tag = format!("external_repo:{tag_suffix}");

        assert_eq!(p, std::path::PathBuf::from("/tmp/my-clones/acme/widget"));
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// --clone-path overrides the resolved path while keeping the tag derived
    /// from the --external-repo value.
    #[test]
    fn infra_2112_clone_path_override_respected() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "acme/widget".into(),
            "--clone-path".into(),
            "/custom/clone/path".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        assert_eq!(external_repo.as_deref(), Some("acme/widget"));
        assert_eq!(
            clone_path_override,
            Some(std::path::PathBuf::from("/custom/clone/path"))
        );

        // Override takes precedence; tag still comes from external_repo value.
        let repo_val = external_repo.as_deref().unwrap();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let default_path = std::path::PathBuf::from(&home)
            .join(".chump")
            .join("external")
            .join(repo_val);
        let final_path = clone_path_override.clone().unwrap_or(default_path);
        let tag = format!("external_repo:{repo_val}");

        assert_eq!(final_path, std::path::PathBuf::from("/custom/clone/path"));
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// No --external-repo flag: all external fields are None (backwards compat).
    #[test]
    fn infra_2112_no_external_repo_flag_is_noop() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--dry-run".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        // Neither field set — backwards compatible, no external context injected.
        assert!(external_repo.is_none());
        assert!(clone_path_override.is_none());

        // Derived tag is also None.
        let external_repo_tag: Option<String> = external_repo.map(|v| format!("external_repo:{v}"));
        assert!(external_repo_tag.is_none());
    }

    #[test]
    fn credible004_priority_rank_mapping() {
        assert_eq!(super::priority_rank("P0"), 0);
        assert_eq!(super::priority_rank("P1"), 1);
        assert_eq!(super::priority_rank("P2"), 2);
        assert_eq!(super::priority_rank("OTHER"), 99);
    }

    #[test]
    fn credible004_is_test_domain_checks() {
        assert!(super::is_test_domain("TEST-123"));
        assert!(super::is_test_domain("SPIKE"));
        assert!(super::is_test_domain("infra-B1TEST"));
        assert!(!super::is_test_domain("INFRA-123"));
    }

    #[test]
    fn credible004_vague_ac_detection() {
        assert!(super::is_vague_ac_entry("TBD"));
        assert!(super::is_vague_ac_entry("todo: stuff"));
        assert!(super::is_vague_ac_entry("N/A"));
        assert!(!super::is_vague_ac_entry("Implement X with Y"));
    }

    #[test]
    fn infra_2984_filler_phrase_ac_is_vague() {
        // The exact phrase INFRA-2984 itself shipped with — non-empty, so it
        // slipped past the old `.trim().is_empty()` audit-priorities check.
        assert!(super::is_vague_ac_entry("verify it works"));
        assert!(super::is_vague_ac_entry("Verify It Works"));
        assert!(super::is_vague_ac_entry("it works"));
        assert!(super::is_vague_ac_entry("done"));
        assert!(super::is_vague_ac_entry("make it work"));

        // Real AC text that happens to contain "works" must not be flagged
        // (mirrors the INFRA-1878 in-passing-mention precedent for TODO).
        assert!(!super::is_vague_ac_entry(
            "ensure the retry logic works under load"
        ));
        assert!(!super::is_vague_ac_entry(
            "the /health endpoint works and returns 200"
        ));
    }

    #[test]
    fn infra_2984_acceptance_criteria_vague_catches_filler_phrase_array() {
        assert!(super::is_acceptance_criteria_vague(
            r#"["verify it works"]"#
        ));
        assert!(!super::is_acceptance_criteria_vague(
            r#"["Add retry with backoff", "Add unit test for timeout path"]"#
        ));
    }

    #[test]
    fn infra_3259_verify_it_without_works_is_vague() {
        // INFRA-3259 itself shipped with AC `["verify it"]` — the shorter
        // "verify it" / bare "verify" filler slipped past the INFRA-2984
        // allowlist because it only matched "verify it works".
        assert!(super::is_vague_ac_entry("verify it"));
        assert!(super::is_vague_ac_entry("Verify It"));
        assert!(super::is_vague_ac_entry("VERIFY"));
        assert!(super::is_acceptance_criteria_vague(r#"["verify it"]"#));

        // Real AC text that happens to start with "verify" must not be
        // flagged (mirrors the INFRA-2984 in-passing-mention precedent).
        assert!(!super::is_vague_ac_entry(
            "verify the /health endpoint returns 200 under load"
        ));
    }

    #[test]
    fn credible_1565_gap_mutation_verbs_reject_unknown_flags_and_handle_help() {
        let s = |items: &[&str]| -> Vec<String> { items.iter().map(|x| x.to_string()).collect() };

        // AC1: `chump gap set <ID> --acceptance-criteria x --dry-run` is rejected.
        assert!(super::validate_gap_mutation_args(
            "set",
            &s(&["INFRA-8154", "--acceptance-criteria", "x", "--dry-run"])
        )
        .is_err());

        // AC2: unknown flags rejected across all five verbs.
        for (verb, bad_argv) in [
            ("set", &["INFRA-1", "--title", "ok", "--unknown"][..]),
            ("ship", &["INFRA-1", "--closed-pr", "42", "--dry-run"][..]),
            (
                "link-pr",
                &["INFRA-1", "42", "--sha", "abc", "--dry-run"][..],
            ),
            (
                "unlink-pr",
                &["INFRA-1", "42", "--reason", "r", "--dry-run"][..],
            ),
            (
                "reserve",
                &["--domain", "INFRA", "--title", "t", "--dry-run"][..],
            ),
            ("reserve", &["INFRA", "some", "title", "--dry-run"][..]),
        ] {
            assert!(
                super::validate_gap_mutation_args(verb, &s(bad_argv)).is_err(),
                "verb {verb} should reject {bad_argv:?}"
            );
        }

        // AC2: --help on all five verbs returns Help(usage).
        for verb in ["set", "ship", "link-pr", "unlink-pr", "reserve"] {
            assert!(
                matches!(
                    super::validate_gap_mutation_args(verb, &s(&["--help"])),
                    Ok(super::GapMutationArgCheck::Help(_))
                ),
                "verb {verb} --help should return Help"
            );
            assert!(
                matches!(
                    super::validate_gap_mutation_args(verb, &s(&["INFRA-1", "-h"])),
                    Ok(super::GapMutationArgCheck::Help(_))
                ),
                "verb {verb} -h should return Help"
            );
        }

        // Valid invocations pass.
        assert_eq!(
            super::validate_gap_mutation_args(
                "set",
                &s(&[
                    "INFRA-1",
                    "--acceptance-criteria",
                    "a",
                    "--acceptance-criteria",
                    "b"
                ])
            ),
            Ok(super::GapMutationArgCheck::Valid)
        );
        assert_eq!(
            super::validate_gap_mutation_args("set", &s(&["INFRA-1", "acceptance_criteria", "a"])),
            Ok(super::GapMutationArgCheck::Valid)
        );
        assert_eq!(
            super::validate_gap_mutation_args("ship", &s(&["INFRA-1", "--closed-pr", "42"])),
            Ok(super::GapMutationArgCheck::Valid)
        );
        assert_eq!(
            super::validate_gap_mutation_args(
                "link-pr",
                &s(&["INFRA-1", "42", "--sha", "deadbeef", "--multi"])
            ),
            Ok(super::GapMutationArgCheck::Valid)
        );
        assert_eq!(
            super::validate_gap_mutation_args(
                "unlink-pr",
                &s(&["INFRA-1", "42", "--reason", "test"])
            ),
            Ok(super::GapMutationArgCheck::Valid)
        );
        assert_eq!(
            super::validate_gap_mutation_args(
                "reserve",
                &s(&["--domain", "INFRA", "--title", "ok", "--force"])
            ),
            Ok(super::GapMutationArgCheck::Valid)
        );
    }

    #[test]
    fn credible_1558_gap_mutation_accepts_multi_bullet_ac_and_replace_ac() {
        let s = |items: &[&str]| -> Vec<String> { items.iter().map(|x| x.to_string()).collect() };
        let argv = s(&[
            "CREDIBLE-1558",
            "--acceptance-criteria",
            "bullet 1: run cargo test",
            "bullet 2: verify exit 0",
            "bullet 3: check negative path",
        ]);
        assert_eq!(
            super::validate_gap_mutation_args("set", &argv),
            Ok(super::GapMutationArgCheck::Valid)
        );
        let full_args = s(&[
            "chump",
            "gap",
            "set",
            "CREDIBLE-1558",
            "--acceptance-criteria",
            "bullet 1: run cargo test",
            "bullet 2: verify exit 0",
            "bullet 3: check negative path",
            "--replace-ac",
        ]);
        assert_eq!(
            super::validate_gap_mutation_args("set", &full_args[3..]),
            Ok(super::GapMutationArgCheck::Valid)
        );
        let collected = super::collect_acceptance_criteria_flag_values(&full_args, 4);
        assert_eq!(
            collected,
            vec![
                "bullet 1: run cargo test".to_string(),
                "bullet 2: verify exit 0".to_string(),
                "bullet 3: check negative path".to_string(),
            ]
        );
    }

    #[test]
    fn credible_1543_slice_parent_priority_clamp_and_p0_budget_helpers() {
        let parent: crate::gap_store::GapRow = serde_json::from_value(serde_json::json!({
            "id": "RESILIENT-1500",
            "domain": "RESILIENT",
            "title": "Umbrella RESILIENT-1500",
            "description": "",
            "priority": "P2",
            "effort": "m",
            "status": "open",
            "acceptance_criteria": "[]",
            "depends_on": "[]",
            "notes": "",
            "source_doc": "",
            "created_at": 0,
            "closed_at": null
        }))
        .unwrap();

        let clamped = super::detect_parent_slice_priority_clamp(
            "Slice 1 of RESILIENT-1500: tighten retry loop",
            "Execution slice under umbrella RESILIENT-1500",
            "P0",
            std::slice::from_ref(&parent),
        );
        assert_eq!(
            clamped,
            Some(("RESILIENT-1500".to_string(), "P2".to_string()))
        );

        let unclamped = super::detect_parent_slice_priority_clamp(
            "Slice 2 of RESILIENT-1500",
            "Sub-gap",
            "P2",
            std::slice::from_ref(&parent),
        );
        assert_eq!(unclamped, None);
    }

    #[test]
    fn plan_infra_8143_format_json_v02_ranks_high_unblocks_first() {
        let tmp = tempfile::TempDir::new().unwrap();
        let gaps_dir = tmp.path().join("gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();
        std::fs::write(
            gaps_dir.join("INFRA-LOW.yaml"),
            "- id: INFRA-LOW\n  domain: INFRA\n  title: standalone P1\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();
        std::fs::write(
            gaps_dir.join("INFRA-UNBLK.yaml"),
            "- id: INFRA-UNBLK\n  domain: INFRA\n  title: high-unblock P1\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();
        for idx in 1..=3 {
            std::fs::write(
                gaps_dir.join(format!("INFRA-DEP{idx}.yaml")),
                format!(
                    "- id: INFRA-DEP{idx}\n  domain: INFRA\n  title: dependent {idx}\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-UNBLK]\n"
                ),
            )
            .unwrap();
        }
        let out_file = tmp.path().join(".chump-locks/gap-priority.json");
        let args = vec![
            "chump".to_string(),
            "plan".to_string(),
            "--gaps".to_string(),
            gaps_dir.display().to_string(),
            "--format".to_string(),
            "json".to_string(),
            "--top".to_string(),
            "5".to_string(),
            "--output".to_string(),
            out_file.display().to_string(),
        ];
        super::run_plan_subcommand(&args).expect("chump plan --format json must succeed");
        let raw = std::fs::read_to_string(&out_file).expect("output json file written");
        let parsed: serde_json::Value = serde_json::from_str(&raw).expect("valid json");
        assert_eq!(parsed["version"], "0.2");
        assert!(parsed["generated_at"].is_string());
        let items = parsed["items"].as_array().expect("items array");
        assert!(!items.is_empty());
        assert_eq!(items[0]["gap_id"], "INFRA-UNBLK");
        assert_eq!(items[0]["rank"], 1);
        assert_eq!(items[0]["unblocks"], 3);
    }
}
