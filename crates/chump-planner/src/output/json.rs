//! JSON output for `chump-plan --format json`.
//!
//! Emits a single JSON object suitable for `.chump-locks/gap-priority.json`
//! consumption by the fleet picker (INFRA-1258). Schema is intentionally
//! minimal and stable — picker logic should depend only on the documented
//! fields below.
//!
//! Schema:
//! ```json
//! {
//!   "generated_at": "2026-05-14T16:35:00Z",
//!   "planner_version": "0.1.0",
//!   "weights_identity": "<sha256-16>",
//!   "items": [
//!     {
//!       "rank": 1,
//!       "gap_id": "INFRA-1237",
//!       "score": 12.4,
//!       "domain": "INFRA",
//!       "pillar": "CREDIBLE",
//!       "priority": "P0",
//!       "effort": "m",
//!       "title": "...",
//!       "unblocks_count": 3,
//!       "prerequisites": []
//!     },
//!     ...
//!   ]
//! }
//! ```

use crate::plan::PlanItem;
use crate::score::Weights;
use sha2::{Digest, Sha256};
use std::io::Write;

/// Stable hash of the weight values so consumers can detect when the
/// scoring tuning has changed (and snapshots / dashboards need refresh).
pub fn weights_identity(w: &Weights) -> String {
    let payload = format!(
        "p0={} p1={} p2={} p3={} unblock={} xs={} s={} m={} l={} xl={} age={} road={} cap={} fail={} stale={}",
        w.p0, w.p1, w.p2, w.p3, w.unblocking_bonus,
        w.effort_xs, w.effort_s, w.effort_m, w.effort_l, w.effort_xl,
        w.cycle_age, w.roadmap_alignment, w.pillar_cap_penalty,
        w.recent_failure, w.stale_doc_penalty,
    );
    let mut hasher = Sha256::new();
    hasher.update(payload.as_bytes());
    let bytes = hasher.finalize();
    bytes.iter().take(8).map(|b| format!("{:02x}", b)).collect()
}

pub fn render_json<W: Write>(
    items: &[PlanItem],
    weights: &Weights,
    writer: &mut W,
) -> std::io::Result<()> {
    let now = chrono::Utc::now();
    writer.write_all(b"{\n")?;
    writeln!(
        writer,
        "  \"generated_at\": \"{}\",",
        now.format("%Y-%m-%dT%H:%M:%SZ")
    )?;
    writeln!(
        writer,
        "  \"planner_version\": \"{}\",",
        env!("CARGO_PKG_VERSION")
    )?;
    writeln!(
        writer,
        "  \"weights_identity\": \"{}\",",
        weights_identity(weights)
    )?;
    writer.write_all(b"  \"items\": [\n")?;
    let last = items.len().saturating_sub(1);
    for (idx, item) in items.iter().enumerate() {
        let comma = if idx == last { "" } else { "," };
        let priority = item.gap.priority.as_str();
        let effort = item.gap.effort.as_str();
        let prereqs = item
            .prerequisites
            .iter()
            .map(|g| format!("\"{}\"", json_escape(&g.0)))
            .collect::<Vec<_>>()
            .join(",");
        writeln!(writer, "    {{")?;
        writeln!(writer, "      \"rank\": {},", idx + 1)?;
        writeln!(
            writer,
            "      \"gap_id\": \"{}\",",
            json_escape(&item.gap.id.0)
        )?;
        writeln!(writer, "      \"score\": {:.4},", item.score.total)?;
        writeln!(
            writer,
            "      \"domain\": \"{}\",",
            json_escape(&format!("{:?}", item.gap.domain))
        )?;
        writeln!(writer, "      \"priority\": \"{}\",", priority)?;
        writeln!(writer, "      \"effort\": \"{}\",", effort)?;
        writeln!(
            writer,
            "      \"title\": \"{}\",",
            json_escape(&item.gap.title)
        )?;
        writeln!(
            writer,
            "      \"unblocks_count\": {},",
            item.score.unblocks_count
        )?;
        writeln!(writer, "      \"prerequisites\": [{}]", prereqs)?;
        writeln!(writer, "    }}{}", comma)?;
    }
    writer.write_all(b"  ]\n}\n")?;
    Ok(())
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parses_as_json(bytes: &[u8]) -> serde_yaml::Value {
        // serde_yaml accepts JSON as a subset — handy because the crate
        // already depends on it. Avoids adding serde_json just for tests.
        serde_yaml::from_slice(bytes).expect("output must parse as JSON")
    }

    #[test]
    fn json_escape_meta_chars() {
        assert_eq!(json_escape("a\"b"), "a\\\"b");
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("line1\nline2"), "line1\\nline2");
    }

    #[test]
    fn render_empty_items_yields_valid_json() {
        let weights = Weights::default();
        let mut buf = Vec::new();
        render_json(&[], &weights, &mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        assert!(s.contains("\"items\": [\n"));
        assert!(s.contains("\"weights_identity\""));
        let _ = parses_as_json(s.as_bytes());
    }
}
