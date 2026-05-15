//! INFRA-1370: `chump audit aha-sweep` — generate "ah-ha" findings by walking
//! the code/runtime/effect triangle for every feature claim in the codebase.
//!
//! Most CI/SLO dashboards check **code-present** + **runtime-up**; almost
//! nothing checks **measured effect**. This module systematises the
//! triangulation as a recurring sweep: when any of the three legs diverges
//! while the other two are green, the divergence is the ah-ha.
//!
//! v1 scope (this commit): walk every `kind` registered in
//! `docs/observability/EVENT_REGISTRY.yaml`, read its `effect_metric`
//! declaration (added by INFRA-1371), and verify the kind has fired at least
//! once in the recent ambient stream. Surface "registered but silent" kinds
//! as `kind=audit_finding` events with severity warn/alert.
//!
//! Routes and PWA-component sweeps are deferred to a follow-up — the
//! EVENT_REGISTRY leg is the highest-leverage starter because every
//! observability claim in the system is now self-describing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// One row of the audit table: the kind name, its declared effect metric, the
/// last-N-days emit count, and the verdict.
#[derive(Debug, Clone)]
pub struct AuditFinding {
    pub feature_id: String,
    pub feature_class: String, // "ambient_kind" | "api_route" | "pwa_component"
    pub plumbing_ok: bool,
    pub heartbeat_ok: bool,
    pub effect_ok: bool,
    pub effect_metric_name: String,
    pub effect_observed: u64,
    pub effect_expected_min: Option<u64>,
    pub severity: AuditSeverity,
    pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuditSeverity {
    Ok,
    Warn,
    Alert,
}

impl AuditSeverity {
    pub fn as_str(&self) -> &'static str {
        match self {
            AuditSeverity::Ok => "ok",
            AuditSeverity::Warn => "warn",
            AuditSeverity::Alert => "alert",
        }
    }
}

/// Configuration for the sweep.
pub struct SweepConfig {
    pub repo_root: PathBuf,
    pub window: Duration,
    /// When `effect_metric == "self"` and no `expected_min_per_day` is set,
    /// treat any kind with zero recent emits as warn. When `false`, only
    /// flag kinds with a declared `expected_min_per_day` floor.
    pub flag_silent_self: bool,
}

impl SweepConfig {
    pub fn default_for(repo_root: PathBuf) -> Self {
        SweepConfig {
            repo_root,
            window: Duration::from_secs(7 * 24 * 3600),
            flag_silent_self: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RegistryEntry {
    pub kind: String,
    pub effect_metric: String,
    pub expected_min_per_day: Option<u64>,
    pub status: String, // "stable" | "deprecated" | ""
}

/// Parse EVENT_REGISTRY.yaml into a flat list of entries.
///
/// We intentionally avoid pulling in serde_yaml here — the registry has a
/// uniform "block per kind" shape and a tiny hand-rolled parser keeps the
/// dependency surface small. Lines like:
///   - kind: foo
///     effect_metric: bar
///     expected_min_per_day: 10
///     status: stable
/// are recognised; everything else is ignored.
pub fn parse_event_registry(path: &Path) -> Result<Vec<RegistryEntry>, String> {
    let raw =
        std::fs::read_to_string(path).map_err(|e| format!("read {}: {}", path.display(), e))?;
    let mut entries: Vec<RegistryEntry> = Vec::new();
    let mut cur: Option<RegistryEntry> = None;
    for raw_line in raw.lines() {
        let line = raw_line.trim_end();
        // Stop tracking an entry when we hit a comment line at column 0 or
        // a non-event top-level key.
        if let Some(rest) = line.strip_prefix("  - kind: ") {
            if let Some(prev) = cur.take() {
                entries.push(prev);
            }
            cur = Some(RegistryEntry {
                kind: rest.trim().to_string(),
                effect_metric: String::new(),
                expected_min_per_day: None,
                status: String::new(),
            });
            continue;
        }
        if let Some(ref mut e) = cur {
            if let Some(rest) = line.strip_prefix("    effect_metric: ") {
                e.effect_metric = rest.trim().trim_matches('"').to_string();
            } else if let Some(rest) = line.strip_prefix("    expected_min_per_day: ") {
                if let Ok(n) = rest.trim().parse::<u64>() {
                    e.expected_min_per_day = Some(n);
                }
            } else if let Some(rest) = line.strip_prefix("    status: ") {
                e.status = rest.trim().trim_matches('"').to_string();
            }
        }
    }
    if let Some(prev) = cur.take() {
        entries.push(prev);
    }
    Ok(entries)
}

/// Count occurrences of each `kind` in the recent ambient stream within the
/// configured window. Reads `.chump-locks/ambient.jsonl` directly.
pub fn ambient_kind_counts(
    repo_root: &Path,
    window: Duration,
) -> Result<HashMap<String, u64>, String> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if !ambient_path.exists() {
        return Ok(HashMap::new());
    }
    let raw = std::fs::read_to_string(&ambient_path)
        .map_err(|e| format!("read {}: {}", ambient_path.display(), e))?;
    let cutoff_secs = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("clock: {}", e))?
        .as_secs())
    .saturating_sub(window.as_secs());

    let mut counts: HashMap<String, u64> = HashMap::new();
    for line in raw.lines() {
        // Cheap line filter — skip lines without "kind":"
        if !line.contains("\"kind\"") {
            continue;
        }
        // Try to parse the ts field for window filtering. Lines without a ts
        // are counted (best effort).
        if let Some(ts_str) = extract_string_field(line, "ts") {
            if let Some(line_secs) = parse_iso8601(&ts_str) {
                if line_secs < cutoff_secs {
                    continue;
                }
            }
        }
        if let Some(kind_str) = extract_string_field(line, "kind") {
            *counts.entry(kind_str).or_insert(0) += 1;
        }
    }
    Ok(counts)
}

/// Extract `"FIELD":"value"` from a JSON-ish line. Naive but fast and works on
/// the ambient stream's flat JSON shape.
fn extract_string_field(line: &str, field: &str) -> Option<String> {
    let needle = format!("\"{}\":", field);
    let idx = line.find(&needle)?;
    let after = &line[idx + needle.len()..];
    let after = after.trim_start();
    let after = after.strip_prefix('"')?;
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

/// Parse an ISO-8601 UTC timestamp `YYYY-MM-DDTHH:MM:SSZ` to unix seconds.
/// Uses chrono to stay consistent with the rest of the codebase.
fn parse_iso8601(s: &str) -> Option<u64> {
    use chrono::DateTime;
    let dt = DateTime::parse_from_rfc3339(s).ok()?;
    let secs = dt.timestamp();
    if secs < 0 {
        return None;
    }
    Some(secs as u64)
}

/// Run the sweep — returns one finding per registered kind whose effect
/// declaration cannot be reconciled with the observed ambient activity.
pub fn sweep_event_registry(cfg: &SweepConfig) -> Result<Vec<AuditFinding>, String> {
    let registry_path = cfg
        .repo_root
        .join("docs")
        .join("observability")
        .join("EVENT_REGISTRY.yaml");
    let entries = parse_event_registry(&registry_path)?;
    let counts = ambient_kind_counts(&cfg.repo_root, cfg.window)?;
    let window_days = (cfg.window.as_secs() as f64 / 86400.0).max(1.0);

    let mut findings: Vec<AuditFinding> = Vec::with_capacity(entries.len());
    for entry in entries {
        // Plumbing leg: the registry entry itself exists; we read it.
        let plumbing_ok = true;
        // Heartbeat leg: deprecated kinds are skipped (intentional silence).
        let heartbeat_ok = entry.status != "deprecated";
        if !heartbeat_ok {
            continue;
        }
        let observed = counts.get(&entry.kind).copied().unwrap_or(0);

        // Per-kind effect criterion:
        // - if expected_min_per_day is set: window-scaled minimum
        // - else if effect_metric != "self": no auto-check (downstream metric
        //   exists outside ambient — flagged "needs_metric_resolver" once we
        //   ship per-metric resolvers; for now emit informational severity=ok)
        // - else (effect_metric == "self" and no floor): if flag_silent_self
        //   is true, anything below 1 is warn
        let (effect_ok, effect_expected_min, severity, note) =
            if let Some(per_day) = entry.expected_min_per_day {
                let expected = ((per_day as f64) * window_days).round() as u64;
                if observed >= expected {
                    (true, Some(expected), AuditSeverity::Ok, String::new())
                } else if observed == 0 {
                    (
                        false,
                        Some(expected),
                        AuditSeverity::Alert,
                        format!(
                            "0 emits in {:.0}d window; floor was {} (expected ≥{} over window)",
                            window_days, per_day, expected
                        ),
                    )
                } else {
                    (
                        false,
                        Some(expected),
                        AuditSeverity::Warn,
                        format!(
                            "{} emits in {:.0}d window; floor was {} (expected ≥{})",
                            observed, window_days, per_day, expected
                        ),
                    )
                }
            } else if entry.effect_metric != "self" && !entry.effect_metric.is_empty() {
                // Downstream-metric kinds: needs a resolver. For v1 emit ok
                // with a note rather than guessing.
                (
                    true,
                    None,
                    AuditSeverity::Ok,
                    format!(
                        "downstream metric '{}' not yet resolvable by aha-sweep v1 (informational)",
                        entry.effect_metric
                    ),
                )
            } else if cfg.flag_silent_self && observed == 0 {
                (
                    false,
                    None,
                    AuditSeverity::Warn,
                    format!("0 emits in {:.0}d window; effect_metric=self", window_days),
                )
            } else {
                (true, None, AuditSeverity::Ok, String::new())
            };

        findings.push(AuditFinding {
            feature_id: entry.kind.clone(),
            feature_class: "ambient_kind".to_string(),
            plumbing_ok,
            heartbeat_ok,
            effect_ok,
            effect_metric_name: if entry.effect_metric.is_empty() {
                "self".to_string()
            } else {
                entry.effect_metric.clone()
            },
            effect_observed: observed,
            effect_expected_min,
            severity,
            note,
        });
    }
    Ok(findings)
}

/// Emit `kind=audit_finding` to ambient.jsonl for every non-ok finding.
pub fn emit_findings(repo_root: &Path, findings: &[AuditFinding]) -> std::io::Result<()> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let mut out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)?;
    use std::io::Write;
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    for f in findings {
        if f.severity == AuditSeverity::Ok {
            continue;
        }
        let payload = serde_json::json!({
            "ts": ts,
            "kind": "audit_finding",
            "feature_id": f.feature_id,
            "feature_class": f.feature_class,
            "plumbing_ok": f.plumbing_ok,
            "heartbeat_ok": f.heartbeat_ok,
            "effect_ok": f.effect_ok,
            "effect_metric_name": f.effect_metric_name,
            "effect_observed": f.effect_observed,
            "effect_expected_min": f.effect_expected_min,
            "severity": f.severity.as_str(),
            "note": f.note,
        });
        writeln!(out, "{}", payload)?;
    }
    Ok(())
}

/// Render a human-readable summary table. Non-ok findings first.
pub fn render_text(findings: &[AuditFinding]) -> String {
    let mut out = String::new();
    out.push_str("=== chump audit aha-sweep ===\n");
    let alerts: Vec<&AuditFinding> = findings
        .iter()
        .filter(|f| f.severity == AuditSeverity::Alert)
        .collect();
    let warns: Vec<&AuditFinding> = findings
        .iter()
        .filter(|f| f.severity == AuditSeverity::Warn)
        .collect();
    out.push_str(&format!(
        "scanned: {}   alert: {}   warn: {}   ok: {}\n\n",
        findings.len(),
        alerts.len(),
        warns.len(),
        findings.len() - alerts.len() - warns.len()
    ));
    for f in alerts.iter().chain(warns.iter()) {
        out.push_str(&format!(
            "  [{}] {} (class={}, observed={}, metric={})\n      {}\n",
            f.severity.as_str(),
            f.feature_id,
            f.feature_class,
            f.effect_observed,
            f.effect_metric_name,
            f.note
        ));
    }
    if alerts.is_empty() && warns.is_empty() {
        out.push_str("  no divergences detected.\n");
    }
    out
}

/// Render as JSON for tooling (PWA panel, dashboards).
pub fn render_json(findings: &[AuditFinding]) -> serde_json::Value {
    let items: Vec<serde_json::Value> = findings
        .iter()
        .map(|f| {
            serde_json::json!({
                "feature_id": f.feature_id,
                "feature_class": f.feature_class,
                "plumbing_ok": f.plumbing_ok,
                "heartbeat_ok": f.heartbeat_ok,
                "effect_ok": f.effect_ok,
                "effect_metric_name": f.effect_metric_name,
                "effect_observed": f.effect_observed,
                "effect_expected_min": f.effect_expected_min,
                "severity": f.severity.as_str(),
                "note": f.note,
            })
        })
        .collect();
    let alert_count = findings
        .iter()
        .filter(|f| f.severity == AuditSeverity::Alert)
        .count();
    let warn_count = findings
        .iter()
        .filter(|f| f.severity == AuditSeverity::Warn)
        .count();
    serde_json::json!({
        "ts": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        "scanned": findings.len(),
        "alert_count": alert_count,
        "warn_count": warn_count,
        "findings": items,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_registry(s: &str) -> Vec<RegistryEntry> {
        let p = std::env::temp_dir().join(format!("chump-audit-test-{}.yaml", std::process::id()));
        std::fs::write(&p, s).unwrap();
        let r = parse_event_registry(&p).unwrap();
        let _ = std::fs::remove_file(&p);
        r
    }

    #[test]
    fn parser_extracts_three_entries() {
        let r = fixture_registry(
            r#"
schema_version: 2
events:
  - kind: alpha
    effect_metric: self
    emitter: x
  - kind: beta
    effect_metric: downstream_count
    expected_min_per_day: 10
  - kind: gamma
    effect_metric: self
    status: deprecated
"#,
        );
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].kind, "alpha");
        assert_eq!(r[0].effect_metric, "self");
        assert_eq!(r[1].effect_metric, "downstream_count");
        assert_eq!(r[1].expected_min_per_day, Some(10));
        assert_eq!(r[2].status, "deprecated");
    }

    #[test]
    fn deprecated_kinds_are_skipped() {
        let dir = std::env::temp_dir().join(format!("chump-audit-sweep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("docs/observability")).unwrap();
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::write(
            dir.join("docs/observability/EVENT_REGISTRY.yaml"),
            r#"events:
  - kind: zombie
    effect_metric: self
    status: deprecated
"#,
        )
        .unwrap();
        let cfg = SweepConfig::default_for(dir.clone());
        let findings = sweep_event_registry(&cfg).unwrap();
        assert_eq!(findings.len(), 0, "deprecated kinds should be skipped");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn floor_violation_emits_alert() {
        let dir = std::env::temp_dir().join(format!("chump-audit-floor-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("docs/observability")).unwrap();
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::write(
            dir.join("docs/observability/EVENT_REGISTRY.yaml"),
            r#"events:
  - kind: hourly_heartbeat
    effect_metric: self
    expected_min_per_day: 24
"#,
        )
        .unwrap();
        // No ambient.jsonl entries → 0 observed; expected ≥24/d * 7d = 168.
        let cfg = SweepConfig::default_for(dir.clone());
        let findings = sweep_event_registry(&cfg).unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].severity, AuditSeverity::Alert);
        assert_eq!(findings[0].effect_observed, 0);
        assert_eq!(findings[0].effect_expected_min, Some(168));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn downstream_metric_is_informational_not_failure() {
        let dir =
            std::env::temp_dir().join(format!("chump-audit-downstream-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("docs/observability")).unwrap();
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::write(
            dir.join("docs/observability/EVENT_REGISTRY.yaml"),
            r#"events:
  - kind: gap_claimed
    effect_metric: gap_shipped_within_deadline_for_same_id
"#,
        )
        .unwrap();
        let cfg = SweepConfig::default_for(dir.clone());
        let findings = sweep_event_registry(&cfg).unwrap();
        assert_eq!(findings.len(), 1);
        // V1 cannot resolve the downstream metric — treat as informational.
        assert_eq!(findings[0].severity, AuditSeverity::Ok);
        assert!(findings[0].note.contains("downstream metric"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn render_text_groups_alerts_first() {
        let findings = vec![
            AuditFinding {
                feature_id: "ok_kind".into(),
                feature_class: "ambient_kind".into(),
                plumbing_ok: true,
                heartbeat_ok: true,
                effect_ok: true,
                effect_metric_name: "self".into(),
                effect_observed: 5,
                effect_expected_min: None,
                severity: AuditSeverity::Ok,
                note: "".into(),
            },
            AuditFinding {
                feature_id: "alert_kind".into(),
                feature_class: "ambient_kind".into(),
                plumbing_ok: true,
                heartbeat_ok: true,
                effect_ok: false,
                effect_metric_name: "self".into(),
                effect_observed: 0,
                effect_expected_min: Some(10),
                severity: AuditSeverity::Alert,
                note: "0 emits".into(),
            },
        ];
        let s = render_text(&findings);
        assert!(s.contains("scanned: 2"));
        assert!(s.contains("alert: 1"));
        assert!(s.contains("alert_kind"));
    }
}
