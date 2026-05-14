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
use std::collections::HashSet;
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

/// Build the subject for a gap row.
pub fn subject_for(row: &GapRow) -> String {
    let machine = if row.preferred_machine.is_empty() {
        "any".to_string()
    } else {
        row.preferred_machine.clone()
    };
    format!(
        "{}.{}.{}.{}",
        WORK_SUBJECT_PREFIX,
        row.priority,
        class_for(row),
        machine
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

/// One cycle of the assign daemon: read open gaps, publish to NATS for any
/// gap not currently claimed.
///
/// Returns the count of envelopes published.
pub async fn assign_cycle(client: &CoordClient, store: &GapStore) -> Result<usize> {
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

    for row in rows {
        if claimed.contains(&row.id) {
            continue;
        }
        let subject = subject_for(&row);
        let replicas = replicas_for(&row);
        for seq in 1..=replicas {
            let env = envelope_for(&row, seq, replicas);
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
    eprintln!(
        "[chump-coord assign] daemon up: watching {} every {:?}",
        db_path.display(),
        poll_interval
    );
    loop {
        match assign_cycle(&client, &store).await {
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
}
