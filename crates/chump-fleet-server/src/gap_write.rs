//! `POST /api/gap` — authenticated canonical gap-write (INFRA-3689).
//!
//! Second bat-phone surface alongside `POST /api/mission` (EFFECTIVE-513):
//! where `/api/mission` is decompose-oriented intake, `/api/gap` is the raw
//! `chump gap reserve|set|ship` primitive, exposed over HTTP so a
//! non-canonical/stale client (the operator's Mac) can mutate canonical gap
//! state WITHOUT holding a writable local canonical replica. The CLI-side
//! caller lives in the root `chump` binary's gap-mutation path
//! (`src/gap_route.rs`): when `CHUMP_GAP_SERVER` is set and the local
//! checkout is verifiably behind `origin/main`, the CLI routes the mutation
//! here instead of writing `state.db` directly.
//!
//! ## Security
//!
//! Same fail-closed bearer auth as `/api/mission` — the route handler in
//! `routes.rs` reuses `mission::configured_token()` /
//! `mission::constant_time_eq()` verbatim; there is no separate auth path to
//! audit here.
//!
//! ## Ops
//!
//! - `reserve` — `chump gap reserve --domain D --title T [--priority P] [--effort E]`,
//!   then (INFRA-3686 fix) a follow-up `chump gap set <id> --outcome O
//!   --acceptance-criteria ... --priority ...` when any of those fields were
//!   supplied, so a P0/P1 mission with an outcome doesn't 500 on the
//!   MISSION-045 close gate later — the CREATE path now forwards
//!   `req.outcome` all the way through instead of silently dropping it.
//! - `set` — `chump gap set <gap_id> [--description ...] [--priority ...]
//!   [--outcome ...] [--acceptance-criteria ...] [--status ...]`. Requires
//!   `gap_id`.
//! - `ship` — `chump gap ship <gap_id>`. Requires `gap_id`.

use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::mission::{
    is_gap_id, parse_gap_id, resolve_chump_bin, sanitize_effort, sanitize_priority,
};

/// The three ops `POST /api/gap` accepts. Anything else is a 400 at the
/// route handler, before this module ever runs.
pub const ALLOWED_OPS: &[&str] = &["reserve", "set", "ship"];

pub fn is_valid_op(op: &str) -> bool {
    ALLOWED_OPS.contains(&op)
}

/// Inbound gap-mutation payload for `POST /api/gap`.
#[derive(Debug, Default, Deserialize)]
pub struct GapWriteRequest {
    pub op: String,
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub gap_id: Option<String>,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub outcome: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub acceptance_criteria: Option<Vec<String>>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub depends_on: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub add_note: Option<String>,
    #[serde(default)]
    pub source_doc: Option<String>,
    #[serde(default)]
    pub opened_date: Option<String>,
    #[serde(default)]
    pub closed_date: Option<String>,
    #[serde(default)]
    pub closed_pr: Option<i64>,
    #[serde(default)]
    pub skills_required: Option<String>,
    #[serde(default)]
    pub preferred_backend: Option<String>,
    #[serde(default)]
    pub preferred_machine: Option<String>,
    #[serde(default)]
    pub estimated_minutes: Option<String>,
    #[serde(default)]
    pub required_model: Option<String>,
    /// RESILIENT-1030: `--evidence` text for the CREDIBLE-107 P0/P1
    /// RESILIENT/MISSION/CREDIBLE gate in `chump gap reserve`. Forwarded
    /// verbatim when non-empty; see `execute_gap_write`'s `reserve` arm for
    /// the exemption behavior when this is omitted.
    #[serde(default)]
    pub evidence: Option<String>,
    #[serde(default)]
    pub artifact_type: Option<String>,
    #[serde(default)]
    pub external_repo: Option<String>,
    #[serde(default)]
    pub force: Option<bool>,
    #[serde(default)]
    pub skip_obs_acs: Option<bool>,
    #[serde(default)]
    pub session: Option<String>,
    /// PRODUCT-323: every wire field not modelled above, kept only so an empty
    /// `op=set` can report which fields the caller actually sent.
    #[serde(flatten)]
    pub unrecognised: std::collections::BTreeMap<String, serde_json::Value>,
}

/// A caller error (bad/empty request) — surfaced as HTTP 400, not 500.
#[derive(Debug)]
pub struct InvalidRequest(pub String);

impl std::fmt::Display for InvalidRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for InvalidRequest {}

/// Message for an `op=set` that changed nothing: names the fields received so
/// the caller can see which one the server did not recognise.
fn empty_set_message(req: &GapWriteRequest) -> String {
    let mut received: Vec<&str> = req.unrecognised.keys().map(String::as_str).collect();
    received.insert(0, "op");
    if req.gap_id.is_some() {
        received.insert(1, "gap_id");
    }
    format!(
        "op=set requires at least one recognised field to update; received fields: [{}]; \
         unrecognised: [{}]",
        received.join(", "),
        req.unrecognised
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// Result of a successful gap mutation, serialized back to the caller.
#[derive(Debug, Serialize)]
pub struct GapWriteOutcome {
    pub gap_id: String,
    pub op: String,
    pub status: String,
    pub detail: String,
}

fn run_chump(chump: &Path, repo_root: &Path, args: &[&str]) -> anyhow::Result<String> {
    let out = Command::new(chump)
        .current_dir(repo_root)
        .args(args)
        .output()
        .map_err(|e| anyhow::anyhow!("failed to spawn `chump {}`: {e}", args.join(" ")))?;
    if !out.status.success() {
        anyhow::bail!(
            "`chump {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// RESILIENT-1030 / CREDIBLE-107: `chump gap reserve` refuses P0/P1
/// RESILIENT/MISSION/CREDIBLE gaps without `--evidence`. The bat-phone
/// bearer token already gates this whole route, so a caller who cleared
/// auth is treated the same as an operator dispatching from the CLI:
/// forward real evidence when given, otherwise pass
/// `--no-evidence-required` so an authed P0/P1 dispatch never 500s on the
/// evidence gate. Pure + unit-testable (no shell-out).
fn evidence_gate_args(evidence: Option<&str>) -> Vec<String> {
    match evidence.map(str::trim) {
        Some(ev) if !ev.is_empty() => vec!["--evidence".into(), ev.to_string()],
        _ => vec!["--no-evidence-required".into()],
    }
}

/// Translate the full `chump gap set` mutation surface into CLI flags. Keep
/// this alongside the wire schema so a canonical client cannot report success
/// while silently dropping fields it would have applied locally.
fn append_string_arg(args: &mut Vec<String>, flag: &str, value: &Option<String>) -> bool {
    if let Some(value) = value {
        args.push(flag.into());
        args.push(value.clone());
        true
    } else {
        false
    }
}

fn append_set_args(args: &mut Vec<String>, req: &GapWriteRequest) -> bool {
    let mut touched = append_string_arg(args, "--title", &req.title);
    touched |= append_string_arg(args, "--description", &req.description);
    if let Some(v) = &req.priority {
        args.push("--priority".into());
        args.push(sanitize_priority(Some(v)));
        touched = true;
    }
    if let Some(v) = &req.effort {
        args.push("--effort".into());
        args.push(sanitize_effort(Some(v)));
        touched = true;
    }
    touched |= append_string_arg(args, "--status", &req.status);
    touched |= append_string_arg(args, "--outcome", &req.outcome);
    if let Some(ac_list) = &req.acceptance_criteria {
        for ac in ac_list {
            args.push("--acceptance-criteria".into());
            args.push(ac.clone());
            touched = true;
        }
    }
    touched |= append_string_arg(args, "--depends-on", &req.depends_on);
    touched |= append_string_arg(args, "--notes", &req.notes);
    touched |= append_string_arg(args, "--add-note", &req.add_note);
    touched |= append_string_arg(args, "--source-doc", &req.source_doc);
    touched |= append_string_arg(args, "--opened-date", &req.opened_date);
    touched |= append_string_arg(args, "--closed-date", &req.closed_date);
    if let Some(v) = req.closed_pr {
        args.push("--closed-pr".into());
        args.push(v.to_string());
        touched = true;
    }
    touched |= append_string_arg(args, "--skills-required", &req.skills_required);
    touched |= append_string_arg(args, "--preferred-backend", &req.preferred_backend);
    touched |= append_string_arg(args, "--preferred-machine", &req.preferred_machine);
    touched |= append_string_arg(args, "--estimated-minutes", &req.estimated_minutes);
    touched |= append_string_arg(args, "--required-model", &req.required_model);
    touched |= append_string_arg(args, "--evidence", &req.evidence);
    touched |= append_string_arg(args, "--artifact-type", &req.artifact_type);
    touched
}

/// Env var: override the max age (seconds) a server's own HEAD commit may
/// be before it refuses canonical gap writes (RESILIENT-1513).
pub const STALE_MAX_AGE_ENV: &str = "CHUMP_FLEET_SERVER_STALE_MAX_AGE_S";
/// Default staleness ceiling: 48h. Main merges many times a day in this
/// fleet, so a HEAD this old means the node's checkout stopped advancing —
/// e.g. a dead refresh timer — not that main itself went quiet.
const DEFAULT_STALE_MAX_AGE_S: u64 = 172_800;

/// Age (seconds) of `repo_root`'s current HEAD commit, or `None` if git is
/// unavailable/unparseable. Deliberately HEAD-commit-age rather than an
/// ahead/behind comparison against a cached `origin/main` ref: a node that
/// stopped fetching days ago has a cached ref that is ALSO stale, so an
/// ahead/behind count would under-report exactly the condition this guards
/// against (RESILIENT-1513 — the node whose store froze on 2026-09-29 still
/// looked "0 behind" against its own last-seen origin/main).
fn head_commit_age_s(repo_root: &Path) -> Option<u64> {
    let out = Command::new("git")
        .current_dir(repo_root)
        .args(["log", "-1", "--format=%ct"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let ts: i64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;
    Some((now - ts).max(0) as u64)
}

/// RESILIENT-1513: refuse canonical gap writes when this server's own repo
/// checkout has gone stale (stopped advancing) rather than silently writing
/// into a frozen store — the exact failure that let a Mac client's gap
/// filings land on a node whose store had been frozen since 2026-09-29. A
/// stale node answers with a clear, named reason instead of a false
/// success, so the CALLER (or the operator) can resolve the API to whichever
/// node actually holds the canonical, advancing store.
///
/// Pure + unit-testable (no network/HTTP); callers pass a real repo root.
pub fn staleness_guard(repo_root: &Path) -> Option<String> {
    let max_age = std::env::var(STALE_MAX_AGE_ENV)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_STALE_MAX_AGE_S);
    match head_commit_age_s(repo_root) {
        Some(age) if age > max_age => Some(format!(
            "this fleet-server's checkout is stale (HEAD commit is {age}s old, max {max_age}s) \
             — refusing canonical gap write; this node may not hold the canonical store, resolve \
             the gap API to the node whose checkout is current"
        )),
        _ => None,
    }
}

/// Execute a `reserve|set|ship` gap mutation canonically (blocking; call
/// from `spawn_blocking`), reusing the exact `Command::new(chump)
/// .current_dir(repo_root)...` pattern `mission::create_mission_gap` uses
/// for `POST /api/mission`.
pub fn execute_gap_write(
    repo_root: &Path,
    req: GapWriteRequest,
) -> anyhow::Result<GapWriteOutcome> {
    let op = req.op.trim().to_lowercase();
    if !is_valid_op(&op) {
        anyhow::bail!("unsupported op {:?} (allowed: {:?})", req.op, ALLOWED_OPS);
    }
    let chump = resolve_chump_bin(repo_root);

    match op.as_str() {
        "reserve" => {
            let domain = req
                .domain
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=reserve requires non-empty `domain`"))?;
            let title = req
                .title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=reserve requires non-empty `title`"))?;
            let priority = sanitize_priority(req.priority.as_deref());
            let effort = sanitize_effort(req.effort.as_deref());
            let domain_up = crate::mission::sanitize_domain(domain);

            let mut reserve_args: Vec<String> = vec![
                "gap".into(),
                "reserve".into(),
                "--domain".into(),
                domain_up,
                "--title".into(),
                title.to_string(),
                "--priority".into(),
                priority,
                "--effort".into(),
                effort,
            ];
            reserve_args.extend(evidence_gate_args(req.evidence.as_deref()));
            if req.force == Some(true) {
                reserve_args.push("--force".into());
            }
            if req.skip_obs_acs == Some(true) {
                reserve_args.push("--skip-obs-acs".into());
            }
            if let Some(ref ac_list) = req.acceptance_criteria {
                let ac: Vec<&str> = ac_list
                    .iter()
                    .map(String::as_str)
                    .filter(|item| !item.trim().is_empty())
                    .collect();
                if !ac.is_empty() {
                    reserve_args.push("--acceptance-criteria".into());
                    reserve_args.push(ac.join("|"));
                }
            }
            if let Some(ref external_repo) = req.external_repo {
                reserve_args.push("--external-repo".into());
                reserve_args.push(external_repo.clone());
            }
            let reserve_args_ref: Vec<&str> = reserve_args.iter().map(String::as_str).collect();

            let stdout = run_chump(&chump, repo_root, &reserve_args_ref)?;
            let gap_id = parse_gap_id(&stdout).ok_or_else(|| {
                anyhow::anyhow!(
                    "could not parse gap id from reserve output: {}",
                    stdout.trim()
                )
            })?;
            if !is_gap_id(&gap_id) {
                anyhow::bail!("reserve produced a malformed gap id: {gap_id:?}");
            }

            // INFRA-3686 fix: forward outcome/priority/AC/description via a
            // follow-up `gap set` so a P0/P1 mission with an outcome doesn't
            // silently drop it and 500 later on the MISSION-045 close gate.
            let mut set_args: Vec<String> = vec!["gap".into(), "set".into(), gap_id.clone()];
            let has_set_fields = append_set_args(&mut set_args, &req);
            if has_set_fields {
                let args_ref: Vec<&str> = set_args.iter().map(String::as_str).collect();
                run_chump(&chump, repo_root, &args_ref)?;
            }

            Ok(GapWriteOutcome {
                gap_id,
                op: "reserve".into(),
                status: "reserved".into(),
                detail: if has_set_fields {
                    "gap reserved; outcome/description/AC applied via follow-up gap set".into()
                } else {
                    "gap reserved".into()
                },
            })
        }
        "set" => {
            let gap_id = req
                .gap_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=set requires non-empty `gap_id`"))?;
            if !is_gap_id(gap_id) {
                anyhow::bail!("op=set: {gap_id:?} does not look like a gap id");
            }
            let mut set_args: Vec<String> = vec!["gap".into(), "set".into(), gap_id.to_string()];
            let touched = append_set_args(&mut set_args, &req);
            if !touched {
                return Err(InvalidRequest(empty_set_message(&req)).into());
            }
            let args_ref: Vec<&str> = set_args.iter().map(String::as_str).collect();
            run_chump(&chump, repo_root, &args_ref)?;
            Ok(GapWriteOutcome {
                gap_id: gap_id.to_string(),
                op: "set".into(),
                status: "updated".into(),
                detail: "gap fields updated".into(),
            })
        }
        "ship" => {
            let gap_id = req
                .gap_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=ship requires non-empty `gap_id`"))?;
            if !is_gap_id(gap_id) {
                anyhow::bail!("op=ship: {gap_id:?} does not look like a gap id");
            }
            let mut ship_args = vec!["gap".to_string(), "ship".to_string(), gap_id.to_string()];
            if let Some(closed_pr) = req.closed_pr {
                ship_args.push("--closed-pr".into());
                ship_args.push(closed_pr.to_string());
            }
            if let Some(ref session) = req.session {
                ship_args.push("--session".into());
                ship_args.push(session.clone());
            }
            let ship_args_ref: Vec<&str> = ship_args.iter().map(String::as_str).collect();
            run_chump(&chump, repo_root, &ship_args_ref)?;
            Ok(GapWriteOutcome {
                gap_id: gap_id.to_string(),
                op: "ship".into(),
                status: "done".into(),
                detail: "gap shipped".into(),
            })
        }
        other => anyhow::bail!("unsupported op {other:?}"),
    }
}

/// `GET /api/gaps` (RESILIENT-1030): authed read of the open-gap queue
/// state, so the operator can see what's pickable over the tailnet instead
/// of SSH+sqlite. Blocking (shells out to `chump gap list --json`); call
/// from `spawn_blocking`. Returns the raw JSON array `chump gap list`
/// already produces — no reshaping, so the CLI and the API never drift.
pub fn list_open_gaps(repo_root: &Path) -> anyhow::Result<serde_json::Value> {
    let chump = resolve_chump_bin(repo_root);
    let stdout = run_chump(
        &chump,
        repo_root,
        &["gap", "list", "--status", "open", "--json"],
    )?;
    parse_gap_list_json(&stdout)
}

/// Pure JSON-parse step, split out from `list_open_gaps` so it's
/// unit-testable without shelling out to a real `chump` binary.
fn parse_gap_list_json(stdout: &str) -> anyhow::Result<serde_json::Value> {
    serde_json::from_str(stdout)
        .map_err(|e| anyhow::anyhow!("could not parse `chump gap list --json` output: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_set_message_names_received_fields() {
        let req: GapWriteRequest =
            serde_json::from_str(r#"{"op":"set","gap_id":"INFRA-1","note":"x","source":"holler"}"#)
                .unwrap();
        let mut args = vec![];
        assert!(!append_set_args(&mut args, &req));
        let msg = empty_set_message(&req);
        assert!(
            msg.contains("received fields: [op, gap_id, note, source]"),
            "{msg}"
        );
        assert!(msg.contains("unrecognised: [note, source]"), "{msg}");
    }

    #[test]
    fn is_valid_op_allows_only_the_three_ops() {
        assert!(is_valid_op("reserve"));
        assert!(is_valid_op("set"));
        assert!(is_valid_op("ship"));
        assert!(!is_valid_op("delete"));
        assert!(!is_valid_op(""));
        assert!(!is_valid_op("RESERVE")); // case-sensitive at this layer; execute_gap_write lowercases first
    }

    #[test]
    fn execute_gap_write_rejects_bad_op_before_shelling_out() {
        let req = GapWriteRequest {
            op: "delete".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("unsupported op"));
    }

    #[test]
    fn execute_gap_write_reserve_requires_domain_and_title() {
        let req = GapWriteRequest {
            op: "reserve".into(),
            title: Some("t".into()),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("domain"));
    }

    #[test]
    fn execute_gap_write_set_requires_gap_id_and_a_field() {
        let req = GapWriteRequest {
            op: "set".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
    }

    #[test]
    fn execute_gap_write_ship_requires_gap_id() {
        let req = GapWriteRequest {
            op: "ship".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
    }

    #[test]
    fn append_set_args_preserves_nontrivial_mutation_fields() {
        let req = GapWriteRequest {
            title: Some("new title".into()),
            depends_on: Some("INFRA-1,INFRA-2".into()),
            add_note: Some("operator note".into()),
            closed_pr: Some(42),
            artifact_type: Some("design".into()),
            ..Default::default()
        };
        let mut args = vec!["gap".into(), "set".into(), "INFRA-9".into()];

        assert!(append_set_args(&mut args, &req));
        assert_eq!(
            args,
            vec![
                "gap",
                "set",
                "INFRA-9",
                "--title",
                "new title",
                "--depends-on",
                "INFRA-1,INFRA-2",
                "--add-note",
                "operator note",
                "--closed-pr",
                "42",
                "--artifact-type",
                "design",
            ]
        );
    }

    // RESILIENT-1030: the evidence gate must forward real evidence when
    // given, and otherwise exempt the (already bearer-authed) dispatch via
    // `--no-evidence-required` instead of letting P0/P1 RESILIENT/MISSION/
    // CREDIBLE reserves 500 against the CREDIBLE-107 CLI gate.
    #[test]
    fn evidence_gate_forwards_real_evidence_when_present() {
        let args = evidence_gate_args(Some("COMMAND/OUTPUT/THEORY/ALT"));
        assert_eq!(args, vec!["--evidence", "COMMAND/OUTPUT/THEORY/ALT"]);
    }

    #[test]
    fn evidence_gate_exempts_authed_dispatch_when_absent() {
        assert_eq!(evidence_gate_args(None), vec!["--no-evidence-required"]);
        assert_eq!(evidence_gate_args(Some("")), vec!["--no-evidence-required"]);
        assert_eq!(
            evidence_gate_args(Some("   ")),
            vec!["--no-evidence-required"]
        );
    }

    #[test]
    fn parse_gap_list_json_accepts_a_valid_array() {
        let parsed = parse_gap_list_json(r#"[{"id":"RESILIENT-1","status":"open"}]"#).unwrap();
        assert_eq!(parsed[0]["id"], "RESILIENT-1");
    }

    #[test]
    fn parse_gap_list_json_rejects_garbage() {
        let err = parse_gap_list_json("not json").unwrap_err();
        assert!(err.to_string().contains("could not parse"));
    }

    // RESILIENT-1513: a non-git / nonexistent path can't compute a HEAD age,
    // so the guard fails OPEN (no verdict) rather than refusing every write
    // on a host where git itself is unavailable.
    #[test]
    fn staleness_guard_is_none_when_head_age_unknown() {
        assert!(staleness_guard(Path::new("/nonexistent/not-a-repo")).is_none());
    }

    // Both ceilings are exercised in ONE test (rather than two #[test] fns)
    // because they mutate the same process-global env var — separate tests
    // would race under the default parallel test runner.
    #[test]
    fn staleness_guard_respects_the_configured_ceiling() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap();

        // This checkout's own HEAD is always far younger than 0 seconds, so a
        // max-age of 0 deterministically trips the guard without needing a
        // synthetic stale repo fixture.
        std::env::set_var(STALE_MAX_AGE_ENV, "0");
        let reason = staleness_guard(&repo_root).expect("HEAD age must exceed a 0s ceiling");
        assert!(reason.contains("stale"), "{reason}");
        assert!(reason.contains("resolve"), "{reason}");

        std::env::set_var(STALE_MAX_AGE_ENV, "999999999");
        let reason = staleness_guard(&repo_root);
        std::env::remove_var(STALE_MAX_AGE_ENV);
        assert!(reason.is_none(), "{reason:?}");
    }
}
