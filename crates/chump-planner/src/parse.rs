//! Free-text reference extraction.
//!
//! Hard relations (`Blocks` / `BlockedOn` / `Supersedes` / `ClosedVia`) come
//! ONLY from structured YAML fields and are wired in `graph.rs`. This module
//! exists to surface advisory `SeeAlso` edges — bare gap-IDs mentioned in
//! prose. They never block dispatch; the only consumer is `--explain` in
//! v0.2 and the cross-reference column in the table output.
//!
//! Why so narrow: free-text patterns like `"NOT blocked on EVAL-X"`,
//! `"similar to INFRA-Y"`, `"after Z shipped"` would all generate
//! false-positive hard edges if we tried to parse intent. We intentionally
//! refuse to.

use crate::gap::{Gap, GapId};
use once_cell::sync::Lazy;
use regex::Regex;

#[derive(Debug, Clone)]
pub struct SeeAlsoMention {
    pub target: GapId,
    pub source_field: &'static str,
    pub source_span: String,
}

static GAP_ID_RE: Lazy<Regex> = Lazy::new(|| {
    // DOMAIN-NNNN. DOMAINs in the wild are 3–10 uppercase letters; numbers
    // are 1–5 digits. Word boundaries on both sides avoid matching e.g.
    // `FOO-BAR-12` middle segment as a gap id.
    Regex::new(r"\b([A-Z]{3,10})-(\d{1,5})\b").unwrap()
});

/// Extract bare gap-IDs from notes / description / AC. Deduplicated by
/// (target, field). The caller filters out self-references and unknown IDs.
pub fn extract_see_also(gap: &Gap) -> Vec<SeeAlsoMention> {
    let mut out = Vec::new();
    let mut sources: Vec<(&'static str, &str)> = Vec::new();
    if let Some(s) = gap.notes.as_deref() {
        sources.push(("notes", s));
    }
    if let Some(s) = gap.description.as_deref() {
        sources.push(("description", s));
    }

    let ac_blob;
    if let Some(ac) = gap.acceptance_criteria.as_ref() {
        ac_blob = ac.join("\n");
        sources.push(("acceptance_criteria", &ac_blob));
    }

    for (field, text) in sources {
        for caps in GAP_ID_RE.captures_iter(text) {
            let id = GapId(caps[0].to_string());
            if id == gap.id {
                continue;
            }
            let span = snippet(
                text,
                caps.get(0).unwrap().start(),
                caps.get(0).unwrap().end(),
            );
            out.push(SeeAlsoMention {
                target: id,
                source_field: field,
                source_span: span,
            });
        }
    }

    // Dedup on (target, field) keeping the first span found.
    out.sort_by(|a, b| {
        a.target
            .0
            .cmp(&b.target.0)
            .then_with(|| a.source_field.cmp(b.source_field))
    });
    out.dedup_by(|a, b| a.target == b.target && a.source_field == b.source_field);
    out
}

fn snippet(text: &str, start: usize, end: usize) -> String {
    // 30 chars of context on each side, single-line, trimmed. Indices are
    // byte offsets from regex; round down/up to the nearest char boundary
    // so multi-byte runes (em-dashes, smart quotes, emoji) don't split.
    let lo = floor_char_boundary(text, start.saturating_sub(30));
    let hi = ceil_char_boundary(text, (end + 30).min(text.len()));
    let raw = &text[lo..hi];
    raw.replace('\n', " ").trim().to_string()
}

fn floor_char_boundary(s: &str, mut i: usize) -> usize {
    if i >= s.len() {
        return s.len();
    }
    while !s.is_char_boundary(i) {
        i = i.saturating_sub(1);
    }
    i
}

fn ceil_char_boundary(s: &str, mut i: usize) -> usize {
    if i >= s.len() {
        return s.len();
    }
    while !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gap::{Domain, Effort, Priority, Status};

    fn mk_gap(notes: &str) -> Gap {
        Gap {
            id: GapId("INFRA-1".into()),
            domain: Domain::Infra,
            title: "t".into(),
            status: Status::Open,
            priority: Priority::P1,
            effort: Effort::S,
            opened_date: None,
            closed_date: None,
            closed_pr: None,
            notes: Some(notes.into()),
            description: None,
            acceptance_criteria: None,
            depends_on: vec![],
        }
    }

    #[test]
    fn extracts_bare_ids_from_notes() {
        let g = mk_gap("see also INFRA-100 and EVAL-42 for context");
        let m = extract_see_also(&g);
        let ids: Vec<_> = m.iter().map(|x| x.target.0.clone()).collect();
        assert!(ids.contains(&"INFRA-100".to_string()));
        assert!(ids.contains(&"EVAL-42".to_string()));
    }

    #[test]
    fn skips_self_reference() {
        let g = mk_gap("this is INFRA-1, do not include");
        assert!(extract_see_also(&g).is_empty());
    }

    #[test]
    fn does_not_distinguish_negation() {
        // We DELIBERATELY don't try to detect "NOT blocked on …" — that
        // ambiguity is exactly why this is SeeAlso-only.  The id surfaces;
        // the human reading --explain decides whether to promote it.
        let g = mk_gap("this is NOT blocked on EVAL-99 — moving forward");
        let m = extract_see_also(&g);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].target.0, "EVAL-99");
    }

    #[test]
    fn snippet_respects_char_boundaries_with_multibyte_text() {
        // The em-dash before INFRA-50 is 3 bytes; naïve byte slicing
        // would panic. We assert the extractor cleanly returns the id and
        // *some* span that didn't crash.
        let g = mk_gap("CREDIBLE force-fire — INFRA-50 surfaced both bugs in line ~108");
        let m = extract_see_also(&g);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].target.0, "INFRA-50");
        assert!(m[0].source_span.contains("INFRA-50"));
    }

    #[test]
    fn dedup_by_target_and_field() {
        let g = mk_gap("INFRA-50 mention, and again INFRA-50 here too");
        let m = extract_see_also(&g);
        assert_eq!(m.len(), 1);
    }
}
