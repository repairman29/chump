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
use std::path::{Path, PathBuf};
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

/// Persisted cursor for delta-publish mode (ZERO-WASTE-003): the fingerprint
/// of the last-published envelope-relevant fields for each open+unclaimed gap
/// id. A cycle only re-publishes a gap when its id is new (never seen) or its
/// fingerprint changed since the prior cycle — an unchanged backlog publishes
/// ~0 envelopes instead of the full open set every cycle.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DeltaState {
    pub fingerprints: HashMap<String, String>,
}

impl DeltaState {
    /// Load from `path`. Missing or corrupt state is treated as "first run"
    /// (empty map) — fail-open, never wedges the daemon (AC2).
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, serde_json::to_string(self)?)?;
        Ok(())
    }
}

/// Fingerprint of the envelope-relevant fields of a gap row (excludes
/// `published_at`/`delivery_seq`, which change every cycle by design).
fn fingerprint_for(row: &GapRow, subject: &str, replicas: u32) -> String {
    format!(
        "{}|{}|{}|{}|{}|{}|{}",
        subject,
        row.skills_required,
        row.preferred_backend,
        row.required_model,
        row.effort,
        row.title,
        replicas
    )
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

/// One item this cycle decided to publish: a NATS subject plus the envelope
/// to send there.
struct PlannedPublish {
    subject: String,
    envelope: WorkEnvelope,
}

/// Pure planning step (no I/O): given the currently open gap rows and the
/// set of already-claimed gap ids, decide which envelopes to publish this
/// cycle and advance `state` in place. A gap is (re)published only when its
/// id is new to `state` or its envelope-relevant fields changed since the
/// last cycle that saw it (delta-publish, ZERO-WASTE-003). Gaps that are no
/// longer open+unclaimed (claimed or closed) are dropped from `state` so a
/// future reopen is treated as new-again, not "unchanged".
///
/// Split out from [`assign_cycle`] so the delta semantics are unit-testable
/// without a NATS connection.
fn plan_cycle(
    rows: Vec<GapRow>,
    claimed: &HashSet<String>,
    state: &mut DeltaState,
) -> Vec<PlannedPublish> {
    let mut current_ids: HashSet<String> = HashSet::new();
    let mut plan = Vec::new();

    for row in rows {
        if claimed.contains(&row.id) {
            continue;
        }
        let subject = subject_for(&row);
        let replicas = replicas_for(&row);
        current_ids.insert(row.id.clone());

        let fp = fingerprint_for(&row, &subject, replicas);
        let unchanged = state.fingerprints.get(&row.id) == Some(&fp);
        if unchanged {
            continue;
        }

        for seq in 1..=replicas {
            plan.push(PlannedPublish {
                subject: subject.clone(),
                envelope: envelope_for(&row, seq, replicas),
            });
        }
        state.fingerprints.insert(row.id.clone(), fp);
    }

    state.fingerprints.retain(|id, _| current_ids.contains(id));
    plan
}

/// One cycle of the assign daemon: read open gaps, publish to NATS for any
/// gap that is new-or-changed since the prior cycle (delta-publish,
/// ZERO-WASTE-003). `state` tracks what was published last cycle; an empty
/// `state` (first run, or reloaded after missing/corrupt persisted state)
/// republishes the full open+unclaimed set once, then subsequent calls with
/// the same `state` settle into delta mode.
///
/// Returns the count of envelopes published.
pub async fn assign_cycle(
    client: &CoordClient,
    store: &GapStore,
    state: &mut DeltaState,
) -> Result<usize> {
    let rows = store.list(Some("open"))?;

    // Cache active claims so we don't re-publish work that's already taken.
    let claimed: HashSet<String> = client
        .list_gap_claims()
        .await
        .unwrap_or_default()
        .into_iter()
        .map(|(id, _)| id)
        .collect();

    let plan = plan_cycle(rows, &claimed, state);
    let mut published = 0usize;
    for item in &plan {
        let payload: Bytes = serde_json::to_vec(&item.envelope)?.into();
        client
            .nats
            .publish(item.subject.clone(), payload)
            .await
            .map_err(|e| anyhow!("NATS publish to {}: {}", item.subject, e))?;
        published += 1;
    }

    // One flush per cycle keeps the publish loop snappy.
    client
        .nats
        .flush()
        .await
        .map_err(|e| anyhow!("NATS flush: {}", e))?;
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
    let state_path = repo_root
        .join(".chump-locks")
        .join("assign-delta-state.json");
    let mut state = DeltaState::load(&state_path);
    eprintln!(
        "[chump-coord assign] daemon up: watching {} every {:?} (delta-state: {})",
        db_path.display(),
        poll_interval,
        state_path.display()
    );
    loop {
        match assign_cycle(&client, &store, &mut state).await {
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
        if let Err(e) = state.save(&state_path) {
            eprintln!(
                "[chump-coord assign] warning: failed to persist delta-state: {} (continuing in-memory)",
                e
            );
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

    // ── ZERO-WASTE-003: delta-publish semantics (plan_cycle is pure, no NATS) ──

    #[test]
    fn plan_cycle_unchanged_backlog_publishes_zero() {
        let rows = vec![row_with("X-1", "P1", "INFRA", "", "")];
        let mut state = DeltaState::default();

        // Cycle 1: first run, empty state -> full backlog publishes once.
        let plan1 = plan_cycle(rows.clone(), &HashSet::new(), &mut state);
        assert_eq!(plan1.len(), 1, "first cycle republishes the open set once");

        // Cycle 2: identical gap set, state carried over -> steady state, 0.
        let plan2 = plan_cycle(rows, &HashSet::new(), &mut state);
        assert_eq!(plan2.len(), 0, "unchanged backlog must publish 0 envelopes");
    }

    #[test]
    fn plan_cycle_new_gap_publishes_exactly_one() {
        let mut state = DeltaState::default();
        let rows = vec![row_with("X-1", "P1", "INFRA", "", "")];
        plan_cycle(rows.clone(), &HashSet::new(), &mut state);

        // Add one new open gap alongside the unchanged one.
        let mut rows2 = rows;
        rows2.push(row_with("X-2", "P1", "INFRA", "", ""));
        let plan = plan_cycle(rows2, &HashSet::new(), &mut state);
        assert_eq!(
            plan.len(),
            1,
            "adding one open gap should publish exactly 1"
        );
        assert_eq!(plan[0].envelope.gap_id, "X-2");
    }

    #[test]
    fn plan_cycle_claim_drops_gap_from_next_publish() {
        let mut state = DeltaState::default();
        let rows = vec![row_with("X-1", "P1", "INFRA", "", "")];
        plan_cycle(rows.clone(), &HashSet::new(), &mut state);
        assert!(state.fingerprints.contains_key("X-1"));

        // X-1 is now claimed -> filtered out of the open+unclaimed rows the
        // caller passes in (mirrors what assign_cycle does against
        // list_gap_claims()), so the gap drops out of the plan and out of
        // the retained delta-state (0 publishes, no tombstone needed).
        let claimed: HashSet<String> = ["X-1".to_string()].into_iter().collect();
        let plan = plan_cycle(vec![], &claimed, &mut state);
        assert_eq!(plan.len(), 0, "claiming the only gap should publish 0");
        assert!(
            !state.fingerprints.contains_key("X-1"),
            "claimed gap must be dropped from delta-state so a future reopen republishes"
        );
    }

    #[test]
    fn plan_cycle_changed_fields_republish_even_with_same_id() {
        let mut state = DeltaState::default();
        let row = row_with("X-1", "P1", "INFRA", "", "");
        plan_cycle(vec![row], &HashSet::new(), &mut state);

        // Same id, priority changed -> subject changes -> must republish.
        let changed = row_with("X-1", "P0", "INFRA", "", "");
        let plan = plan_cycle(vec![changed], &HashSet::new(), &mut state);
        assert_eq!(
            plan.len(),
            1,
            "a changed gap must republish even with the same id"
        );
    }

    #[test]
    fn delta_state_load_missing_or_corrupt_fails_open() {
        let dir =
            std::env::temp_dir().join(format!("zw003-delta-state-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);

        // Missing file -> empty map, not an error.
        let missing = dir.join("missing.json");
        let _ = std::fs::remove_file(&missing);
        let s = DeltaState::load(&missing);
        assert!(s.fingerprints.is_empty());

        // Corrupt file -> empty map, not a panic/error.
        let corrupt = dir.join("corrupt.json");
        std::fs::write(&corrupt, b"not json{{{").unwrap();
        let s = DeltaState::load(&corrupt);
        assert!(s.fingerprints.is_empty());

        // Round-trips a real save/load.
        let good = dir.join("good.json");
        let mut original = DeltaState::default();
        original
            .fingerprints
            .insert("X-1".to_string(), "fp".to_string());
        original.save(&good).unwrap();
        let reloaded = DeltaState::load(&good);
        assert_eq!(reloaded.fingerprints.get("X-1"), Some(&"fp".to_string()));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// FLEET-034 fail-open path (AC3): a dead broker must not hang or error
    /// the daemon — it logs and exits `Ok(())` so a supervisor can restart it
    /// once NATS recovers, and workers fall back to the pull loop meanwhile.
    /// Points at an unreachable localhost port (never the shared fleet
    /// broker) so this test never touches live coordination state.
    #[tokio::test]
    async fn run_assign_daemon_exits_ok_when_broker_unreachable() {
        let prior = std::env::var("CHUMP_NATS_URL").ok();
        std::env::set_var("CHUMP_NATS_URL", "nats://127.0.0.1:19929");

        let dir =
            std::env::temp_dir().join(format!("zw003-broker-down-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);

        let result = tokio::time::timeout(
            Duration::from_secs(10),
            run_assign_daemon(dir.clone(), Duration::from_secs(1)),
        )
        .await
        .expect("run_assign_daemon must not hang against a dead broker");

        match prior {
            Some(v) => std::env::set_var("CHUMP_NATS_URL", v),
            None => std::env::remove_var("CHUMP_NATS_URL"),
        }
        let _ = std::fs::remove_dir_all(&dir);

        assert!(result.is_ok(), "dead broker must exit Ok(()), not error");
    }
}
