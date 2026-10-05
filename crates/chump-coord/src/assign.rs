//! FLEET-034 — `chump-coord assign` daemon + `chump-coord worker` subscriber.
//!
//! Architecture (push-when-broker-available, pull-when-offline):
//!
//!   state.db  ──polls──►  assign daemon  ──publishes──►  chump.work.<P>.<class>.<machine>
//!                                                              │
//!                                                              ▼
//!                                                          NATS broker
//!                                                              │
//!                              ┌───────────────────────────────┼──────────────────────────────┐
//!                              ▼                               ▼                              ▼
//!                       worker A subscribes               worker B subscribes            worker C subscribes
//!                       chump.work.>.runtime.macbook      chump.work.>.docs.any          chump.work.>.coord.>
//!
//! - First worker to call `try_claim_gap` (KV CAS) wins the lease — that's the ack.
//! - If no worker claims within `ACK_TIMEOUT_S`, daemon redelivers.
//! - `replicas:N` on a gap → publish N copies (consumes INFRA-311 speculative override).
//! - **Offline fallback**: when NATS is unreachable, `assign` exits cleanly and
//!   workers continue running their existing pull loop (worker.sh).
//! - **Delta publish (ZERO-WASTE-003)**: each cycle only publishes gaps whose
//!   open+unclaimed routing fingerprint (priority/class/machine/replicas) is
//!   new or changed since the prior cycle. A steady-state backlog publishes
//!   ~0 envelopes per cycle instead of re-flooding the bus with the full open
//!   set every `poll_interval`. The daemon's in-memory [`DeltaState`] starts
//!   empty, so the first cycle after process start always republishes the
//!   full open set once (fail-open — there is no persisted state to miss or
//!   corrupt across a restart).
//!
//! Subject scheme: `chump.work.<priority>.<class>.<machine>`
//!   priority: P0 | P1 | P2 | P3
//!   class:    derived from gap.domain ∪ skills_required (runtime|docs|coord|...)
//!   machine:  gap.preferred_machine if set, else "any"

use crate::{CoordClient, DEFAULT_NATS_URL};
use anyhow::{anyhow, Result};
use bytes::Bytes;
use chump_gap_store::{GapRow, GapStore};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Duration;

/// Subject prefix for routed work. Workers subscribe under this.
pub const WORK_SUBJECT_PREFIX: &str = "chump.work";

/// Default ack-timeout: window in which a worker must claim before redelivery.
pub const DEFAULT_ACK_TIMEOUT_S: u64 = 60;

/// Default poll interval for the assign daemon (state.db → NATS).
pub const DEFAULT_POLL_INTERVAL_S: u64 = 5;

/// A work envelope published to `chump.work.>`.
///
/// Carries just enough for a worker to decide whether to claim — the
/// authoritative gap state still lives in `state.db`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkEnvelope {
    pub gap_id: String,
    pub priority: String,
    pub class: String,
    pub machine: String,
    pub skills_required: Vec<String>,
    pub preferred_backend: String,
    pub required_model: String,
    pub effort: String,
    pub title: String,
    pub replicas: u32,
    /// Monotonically increasing delivery counter (replicas-N goes 1..=N).
    pub delivery_seq: u32,
    /// Publish timestamp (RFC3339).
    pub published_at: String,
}

/// Derive the routing `class` from a gap row.
///
/// Heuristic: skills_required has the most signal; fall back to domain.
/// Returns "any" if nothing usable is present.
pub fn class_for(row: &GapRow) -> String {
    // Look for a coarse class hint in skills_required first.
    let skills = parse_skills(&row.skills_required);
    for hint in ["runtime", "docs", "coord", "infra", "fleet", "research"] {
        if skills.iter().any(|s| s.eq_ignore_ascii_case(hint)) {
            return hint.to_string();
        }
    }
    // Fall back to domain (lowercased).
    let d = row.domain.to_lowercase();
    if !d.is_empty() {
        return d;
    }
    "any".to_string()
}

fn parse_skills(csv: &str) -> Vec<String> {
    // skills_required can be either a comma list or a JSON array; accept both.
    let trimmed = csv.trim();
    if trimmed.starts_with('[') {
        if let Ok(v) = serde_json::from_str::<Vec<String>>(trimmed) {
            return v;
        }
    }
    trimmed
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Sanitize an arbitrary string into a single NATS-safe subject token.
/// NATS subject tokens cannot contain spaces, dots, `*`, `>`, or be empty —
/// and gap fields (priority/class/machine, derived from skills_required etc.)
/// can contain anything, so we map every non-`[A-Za-z0-9_-]` char to `_`,
/// trim, cap length, and fall back to `x` if empty. Without this, a single gap
/// with a polluted routing field (e.g. a description leaked into
/// skills_required) yields an invalid subject and crashes the assign daemon
/// every cycle — which is exactly why the mesh publisher never ran (INFRA-2476).
fn sanitize_token(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let token: String = cleaned.trim_matches('_').chars().take(48).collect();
    if token.is_empty() {
        "x".to_string()
    } else {
        token
    }
}

/// Build the subject for a gap row. Every token is sanitized so arbitrary gap
/// data can never produce an invalid NATS subject (INFRA-2476).
pub fn subject_for(row: &GapRow) -> String {
    let machine = if row.preferred_machine.is_empty() {
        "any".to_string()
    } else {
        row.preferred_machine.clone()
    };
    format!(
        "{}.{}.{}.{}",
        WORK_SUBJECT_PREFIX,
        sanitize_token(&row.priority),
        sanitize_token(&class_for(row)),
        sanitize_token(&machine)
    )
}

/// Replica count for speculative override (INFRA-311). Looks up `replicas:N`
/// in notes; defaults to 1 if absent or unparseable.
fn replicas_for(row: &GapRow) -> u32 {
    // Cheap parse: search notes for "replicas: N" or "replicas=N".
    let hay = &row.notes;
    if let Some(idx) = hay.find("replicas") {
        let after = &hay[idx + "replicas".len()..];
        let after = after.trim_start_matches([' ', ':', '=']);
        let num_str: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(n) = num_str.parse::<u32>() {
            if n > 0 && n <= 16 {
                return n;
            }
        }
    }
    1
}

fn envelope_for(row: &GapRow, seq: u32, replicas: u32) -> WorkEnvelope {
    WorkEnvelope {
        gap_id: row.id.clone(),
        priority: row.priority.clone(),
        class: class_for(row),
        machine: if row.preferred_machine.is_empty() {
            "any".to_string()
        } else {
            row.preferred_machine.clone()
        },
        skills_required: parse_skills(&row.skills_required),
        preferred_backend: row.preferred_backend.clone(),
        required_model: row.required_model.clone(),
        effort: row.effort.clone(),
        title: row.title.clone(),
        replicas,
        delivery_seq: seq,
        published_at: chrono::Utc::now().to_rfc3339(),
    }
}

/// Routing fingerprint for a gap: the fields that, if unchanged since the
/// prior cycle, mean the gap doesn't need to be re-published (ZERO-WASTE-003).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct DeltaFingerprint {
    priority: String,
    class: String,
    machine: String,
    replicas: u32,
}

fn fingerprint_for(row: &GapRow) -> DeltaFingerprint {
    DeltaFingerprint {
        priority: row.priority.clone(),
        class: class_for(row),
        machine: if row.preferred_machine.is_empty() {
            "any".to_string()
        } else {
            row.preferred_machine.clone()
        },
        replicas: replicas_for(row),
    }
}

/// Carries the "what did we publish last cycle" snapshot so `assign_cycle`
/// can skip gaps whose open+unclaimed routing state hasn't changed.
///
/// A fresh/default `DeltaState` (e.g. right after daemon start) has no prior
/// fingerprints, so every open+unclaimed gap looks "new" on the first cycle —
/// that's the intentional fail-open full-republish (AC2), not a bug.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DeltaState {
    published: HashMap<String, DeltaFingerprint>,
}

/// Pure planning step (no I/O): decide which open+unclaimed gaps are new or
/// changed since `prior`, and compute the next delta state. Split out from
/// [`assign_cycle`] so the delta logic is testable with a fixed `GapRow` set
/// and no NATS broker (ZERO-WASTE-003 AC4).
fn plan_publish<'a>(
    rows: &'a [GapRow],
    claimed: &HashSet<String>,
    prior: &DeltaState,
) -> (Vec<&'a GapRow>, DeltaState) {
    let mut next = DeltaState::default();
    let mut to_publish = Vec::new();
    for row in rows {
        if claimed.contains(&row.id) {
            continue;
        }
        let fp = fingerprint_for(row);
        if prior.published.get(&row.id) != Some(&fp) {
            to_publish.push(row);
        }
        next.published.insert(row.id.clone(), fp);
    }
    (to_publish, next)
}

/// One cycle of the assign daemon: read open gaps, publish to NATS only for
/// gaps whose open+unclaimed routing state is new or changed since the prior
/// cycle (`delta`). Claimed gaps are dropped from the next delta state, so a
/// freshly-claimed gap naturally stops being republished without needing an
/// explicit tombstone.
///
/// Returns the count of envelopes published.
pub async fn assign_cycle(
    client: &CoordClient,
    store: &GapStore,
    delta: &mut DeltaState,
) -> Result<usize> {
    let rows = store.list(Some("open"))?;
    let mut published = 0usize;

    // Cache active claims so we don't re-publish work that's already taken.
    let claimed: HashSet<String> = client
        .list_gap_claims()
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|(id, _)| id)
        .collect();

    let (to_publish, next_delta) = plan_publish(&rows, &claimed, delta);

    for row in to_publish {
        let subject = subject_for(row);
        let replicas = replicas_for(row);
        for seq in 1..=replicas {
            let env = envelope_for(row, seq, replicas);
            let payload: Bytes = serde_json::to_vec(&env)?.into();
            client
                .nats
                .publish(subject.clone(), payload)
                .await
                .map_err(|e| anyhow!("NATS publish to {}: {}", subject, e))?;
            published += 1;
        }
    }
    // One flush per cycle keeps the publish loop snappy.
    client
        .nats
        .flush()
        .await
        .map_err(|e| anyhow!("NATS flush: {}", e))?;
    *delta = next_delta;
    Ok(published)
}

/// Run the assign daemon loop. Polls `state.db` every `poll_interval`.
///
/// Exits with `Ok(())` if NATS becomes unreachable (graceful degradation
/// — workers fall back to pull). The caller decides whether to restart.
pub async fn run_assign_daemon(repo_root: PathBuf, poll_interval: Duration) -> Result<()> {
    let client = match CoordClient::connect_or_skip().await {
        Some(c) => c,
        None => {
            eprintln!(
                "[chump-coord assign] NATS unreachable ({}). Workers will run pull-fallback. Exiting cleanly.",
                std::env::var("CHUMP_NATS_URL").unwrap_or_else(|_| DEFAULT_NATS_URL.to_string())
            );
            return Ok(());
        }
    };
    let db_path = GapStore::db_path(&repo_root);
    let store = GapStore::open(&repo_root)?;
    let mut delta = DeltaState::default();
    eprintln!(
        "[chump-coord assign] daemon up: watching {} every {:?}",
        db_path.display(),
        poll_interval
    );
    loop {
        match assign_cycle(&client, &store, &mut delta).await {
            Ok(n) if n > 0 => {
                eprintln!("[chump-coord assign] published {} envelope(s)", n);
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!(
                    "[chump-coord assign] cycle error: {} — exiting for restart",
                    e
                );
                return Ok(());
            }
        }
        tokio::time::sleep(poll_interval).await;
    }
}

/// Decide whether a worker with `skills` / `machine` / `backend` should accept
/// a work envelope. Mirrors INFRA-314 affinity scoring but as a hard filter.
pub fn worker_accepts(
    env: &WorkEnvelope,
    worker_skills: &[String],
    worker_machine: &str,
    worker_backend: &str,
) -> bool {
    // Hard filter: every required skill must be present.
    for required in &env.skills_required {
        let have = worker_skills
            .iter()
            .any(|s| s.eq_ignore_ascii_case(required));
        if !have {
            return false;
        }
    }
    // Machine: "any" matches anything; otherwise must match.
    if env.machine != "any" && !worker_machine.is_empty() && env.machine != worker_machine {
        return false;
    }
    // Backend: empty preference matches anything.
    if !env.preferred_backend.is_empty()
        && !worker_backend.is_empty()
        && env.preferred_backend != worker_backend
    {
        return false;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn row_with(id: &str, prio: &str, domain: &str, machine: &str, skills: &str) -> GapRow {
        GapRow {
            id: id.to_string(),
            domain: domain.to_string(),
            title: format!("test {}", id),
            description: String::new(),
            priority: prio.to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: String::new(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: skills.to_string(),
            preferred_backend: String::new(),
            preferred_machine: machine.to_string(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    #[test]
    fn subject_priority_class_machine() {
        let r = row_with("INFRA-1", "P0", "INFRA", "macbook", "runtime");
        assert_eq!(subject_for(&r), "chump.work.P0.runtime.macbook");

        let r = row_with("DOC-1", "P2", "DOC", "", "");
        assert_eq!(subject_for(&r), "chump.work.P2.doc.any");
    }

    #[test]
    fn class_prefers_skill_hint_over_domain() {
        let r = row_with("INFRA-2", "P1", "INFRA", "", "coord,git");
        assert_eq!(class_for(&r), "coord");
    }

    #[test]
    fn replicas_parses_from_notes() {
        let mut r = row_with("X-1", "P1", "INFRA", "", "");
        r.notes = "speculative: replicas: 3 — needed for fleet test".to_string();
        assert_eq!(replicas_for(&r), 3);

        r.notes = "replicas=2".to_string();
        assert_eq!(replicas_for(&r), 2);

        r.notes = "no replica hint".to_string();
        assert_eq!(replicas_for(&r), 1);
    }

    #[test]
    fn worker_accepts_skill_match() {
        let env = WorkEnvelope {
            gap_id: "G".into(),
            priority: "P1".into(),
            class: "runtime".into(),
            machine: "any".into(),
            skills_required: vec!["rust".into(), "sqlite".into()],
            preferred_backend: "".into(),
            required_model: "".into(),
            effort: "s".into(),
            title: "t".into(),
            replicas: 1,
            delivery_seq: 1,
            published_at: "".into(),
        };
        assert!(worker_accepts(
            &env,
            &["rust".into(), "sqlite".into(), "git".into()],
            "macbook",
            "claude"
        ));
        // Missing required skill.
        assert!(!worker_accepts(&env, &["rust".into()], "macbook", "claude"));
    }

    #[test]
    fn worker_rejects_machine_mismatch() {
        let env = WorkEnvelope {
            gap_id: "G".into(),
            priority: "P1".into(),
            class: "runtime".into(),
            machine: "pi-mesh".into(),
            skills_required: vec![],
            preferred_backend: "".into(),
            required_model: "".into(),
            effort: "s".into(),
            title: "t".into(),
            replicas: 1,
            delivery_seq: 1,
            published_at: "".into(),
        };
        assert!(!worker_accepts(&env, &[], "macbook", ""));
        assert!(worker_accepts(&env, &[], "pi-mesh", ""));
    }

    #[test]
    fn sanitize_token_yields_valid_nats_tokens() {
        // INFRA-2476 regression: a description leaked into a routing field
        // (spaces/colons/semicolons/dots) crashed the assign daemon every cycle
        // with "invalid subject format". sanitize_token must neutralize it.
        let dirty = "INFRA:P2.n routing hint for one-jeff-many-repos; metadata";
        let clean = sanitize_token(dirty);
        for bad in [' ', '.', ':', ';', '*', '>'] {
            assert!(
                !clean.contains(bad),
                "token still contains {:?}: {}",
                bad,
                clean
            );
        }
        assert!(!clean.is_empty());
        assert!(clean.len() <= 48, "token not length-capped: {}", clean);
        // empty / all-garbage falls back to a non-empty placeholder
        assert_eq!(sanitize_token(""), "x");
        assert_eq!(sanitize_token("   "), "x");
        // clean values pass through unchanged
        assert_eq!(sanitize_token("P0"), "P0");
        assert_eq!(sanitize_token("runtime"), "runtime");
        // a full subject built from the cleaned token is dot-split-safe (3 dots)
        assert_eq!(format!("chump.work.{}.any", clean).matches('.').count(), 3);
    }

    // ── ZERO-WASTE-003: delta publish ──────────────────────────────────────

    #[test]
    fn delta_publish_unchanged_backlog_publishes_nothing() {
        let rows = vec![row_with("INFRA-1", "P1", "INFRA", "", "")];
        let claimed = HashSet::new();
        let (first, delta_after_cycle_1) = plan_publish(&rows, &claimed, &DeltaState::default());
        assert_eq!(first.len(), 1, "first cycle republishes the full open set");

        // Same gap set, same claims, second cycle: nothing changed.
        let (second, _) = plan_publish(&rows, &claimed, &delta_after_cycle_1);
        assert_eq!(
            second.len(),
            0,
            "unchanged backlog must publish 0 on the second cycle"
        );
    }

    #[test]
    fn delta_publish_new_gap_publishes_exactly_one() {
        let rows_cycle_1 = vec![row_with("INFRA-1", "P1", "INFRA", "", "")];
        let claimed = HashSet::new();
        let (_, delta) = plan_publish(&rows_cycle_1, &claimed, &DeltaState::default());

        let rows_cycle_2 = vec![
            row_with("INFRA-1", "P1", "INFRA", "", ""),
            row_with("INFRA-2", "P2", "INFRA", "", ""),
        ];
        let (to_publish, _) = plan_publish(&rows_cycle_2, &claimed, &delta);
        assert_eq!(to_publish.len(), 1);
        assert_eq!(to_publish[0].id, "INFRA-2");
    }

    #[test]
    fn delta_publish_claim_drops_gap_from_next_cycle() {
        let rows = vec![row_with("INFRA-1", "P1", "INFRA", "", "")];
        let (_, delta) = plan_publish(&rows, &HashSet::new(), &DeltaState::default());

        // INFRA-1 gets claimed between cycles; `rows` still comes back from
        // `store.list(Some("open"))` (claim doesn't change gap status), but
        // the claimed-set filter drops it before it reaches the delta diff.
        let claimed_now: HashSet<String> = ["INFRA-1".to_string()].into_iter().collect();
        let (to_publish, next_delta) = plan_publish(&rows, &claimed_now, &delta);
        assert_eq!(
            to_publish.len(),
            0,
            "claimed gap publishes 0 (no tombstone)"
        );
        assert!(
            !next_delta.published.contains_key("INFRA-1"),
            "claimed gap must drop out of delta state"
        );
    }

    #[test]
    fn delta_publish_changed_fingerprint_republishes() {
        let claimed = HashSet::new();
        let rows_cycle_1 = vec![row_with("INFRA-1", "P2", "INFRA", "", "")];
        let (_, delta) = plan_publish(&rows_cycle_1, &claimed, &DeltaState::default());

        // Priority bumped P2 -> P0 between cycles: same gap id, changed fingerprint.
        let rows_cycle_2 = vec![row_with("INFRA-1", "P0", "INFRA", "", "")];
        let (to_publish, _) = plan_publish(&rows_cycle_2, &claimed, &delta);
        assert_eq!(
            to_publish.len(),
            1,
            "changed routing fingerprint republishes"
        );
    }

    #[tokio::test]
    #[serial]
    async fn broker_down_exits_ok_without_wedging() {
        // FLEET-034 fail-open path (AC3): a dead broker must exit 0, not hang
        // or error, so a supervisor can restart the daemon cleanly.
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:1");
        std::env::set_var("CHUMP_NATS_TIMEOUT_MS", "50");
        let tmp = tempfile::tempdir().expect("tempdir");
        let result = run_assign_daemon(tmp.path().to_path_buf(), Duration::from_millis(10)).await;
        std::env::remove_var("CHUMP_NATS_URL");
        std::env::remove_var("CHUMP_NATS_TIMEOUT_MS");
        assert!(result.is_ok(), "broker-down path must exit 0: {:?}", result);
    }
}
