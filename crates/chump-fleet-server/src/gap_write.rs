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
#[derive(Debug, Deserialize)]
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
    /// RESILIENT-1030: `--evidence` text for the CREDIBLE-107 P0/P1
    /// RESILIENT/MISSION/CREDIBLE gate in `chump gap reserve`. Forwarded
    /// verbatim when non-empty; see `execute_gap_write`'s `reserve` arm for
    /// the exemption behavior when this is omitted.
    #[serde(default)]
    pub evidence: Option<String>,
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
            let mut has_set_fields = false;
            if let Some(ref outcome) = req.outcome {
                let outcome = outcome.trim();
                if !outcome.is_empty() {
                    set_args.push("--outcome".into());
                    set_args.push(outcome.to_string());
                    has_set_fields = true;
                }
            }
            if let Some(ref desc) = req.description {
                let desc = desc.trim();
                if !desc.is_empty() {
                    set_args.push("--description".into());
                    set_args.push(desc.to_string());
                    has_set_fields = true;
                }
            }
            if let Some(ref ac_list) = req.acceptance_criteria {
                for ac in ac_list {
                    let ac = ac.trim();
                    if !ac.is_empty() {
                        set_args.push("--acceptance-criteria".into());
                        set_args.push(ac.to_string());
                        has_set_fields = true;
                    }
                }
            }
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
            let mut touched = false;
            if let Some(ref v) = req.description {
                if !v.trim().is_empty() {
                    set_args.push("--description".into());
                    set_args.push(v.trim().to_string());
                    touched = true;
                }
            }
            if let Some(ref v) = req.priority {
                if !v.trim().is_empty() {
                    set_args.push("--priority".into());
                    set_args.push(sanitize_priority(Some(v)));
                    touched = true;
                }
            }
            if let Some(ref v) = req.effort {
                if !v.trim().is_empty() {
                    set_args.push("--effort".into());
                    set_args.push(sanitize_effort(Some(v)));
                    touched = true;
                }
            }
            if let Some(ref v) = req.outcome {
                if !v.trim().is_empty() {
                    set_args.push("--outcome".into());
                    set_args.push(v.trim().to_string());
                    touched = true;
                }
            }
            if let Some(ref v) = req.status {
                if !v.trim().is_empty() {
                    set_args.push("--status".into());
                    set_args.push(v.trim().to_string());
                    touched = true;
                }
            }
            if let Some(ref ac_list) = req.acceptance_criteria {
                for ac in ac_list {
                    let ac = ac.trim();
                    if !ac.is_empty() {
                        set_args.push("--acceptance-criteria".into());
                        set_args.push(ac.to_string());
                        touched = true;
                    }
                }
            }
            if !touched {
                anyhow::bail!("op=set requires at least one field to update");
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
            run_chump(&chump, repo_root, &["gap", "ship", gap_id])?;
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
            domain: None,
            title: None,
            gap_id: None,
            priority: None,
            outcome: None,
            effort: None,
            description: None,
            acceptance_criteria: None,
            status: None,
            evidence: None,
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("unsupported op"));
    }

    #[test]
    fn execute_gap_write_reserve_requires_domain_and_title() {
        let req = GapWriteRequest {
            op: "reserve".into(),
            domain: None,
            title: Some("t".into()),
            gap_id: None,
            priority: None,
            outcome: None,
            effort: None,
            description: None,
            acceptance_criteria: None,
            status: None,
            evidence: None,
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("domain"));
    }

    #[test]
    fn execute_gap_write_set_requires_gap_id_and_a_field() {
        let req = GapWriteRequest {
            op: "set".into(),
            domain: None,
            title: None,
            gap_id: None,
            priority: None,
            outcome: None,
            effort: None,
            description: None,
            acceptance_criteria: None,
            status: None,
            evidence: None,
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
    }

    #[test]
    fn execute_gap_write_ship_requires_gap_id() {
        let req = GapWriteRequest {
            op: "ship".into(),
            domain: None,
            title: None,
            gap_id: None,
            priority: None,
            outcome: None,
            effort: None,
            description: None,
            acceptance_criteria: None,
            status: None,
            evidence: None,
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
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
}
