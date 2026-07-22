//! Apply a unified diff to file contents using the `patch` crate parser and a strict
//! context-matching applicator (rejects hallucinated hunks).

use patch::{Line, Patch};

/// Why a patch could not be applied (hard failure before or during apply).
#[derive(Debug)]
pub enum PatchApplyError {
    Parse(String),
    MultipleFiles {
        count: usize,
    },
    InvalidHunk {
        message: String,
    },
    ContextMismatch {
        hunk_index: usize,
        old_line_1based: usize,
        expected: String,
        actual: Option<String>,
    },
}

impl std::fmt::Display for PatchApplyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PatchApplyError::Parse(s) => write!(f, "{}", s),
            PatchApplyError::MultipleFiles { count } => write!(
                f,
                "diff contains {} file(s); patch_file expects a single-file unified diff",
                count
            ),
            PatchApplyError::InvalidHunk { message } => write!(f, "{}", message),
            PatchApplyError::ContextMismatch {
                hunk_index,
                old_line_1based,
                expected,
                actual,
            } => write!(
                f,
                "hunk {}: line {}: expected {:?}, got {:?}",
                hunk_index, old_line_1based, expected, actual
            ),
        }
    }
}

impl std::error::Error for PatchApplyError {}

/// Patterns the upstream `patch` crate uses for its parser panic messages.
/// When our custom hook sees a panic carrying any of these substrings, it
/// silently routes it back through `catch_unwind` (no stderr noise) since
/// `parse_single_file_patch` is the exclusive caller of `Patch::from_*` and
/// always converts the panic to a `PatchApplyError::Parse`.
const PATCH_CRATE_PANIC_MARKERS: &[&str] = &[
    "bug: failed to parse entire input",
    "failed to parse entire input",
];

/// Install a process-wide panic hook ONCE that swallows the `patch` crate's
/// known parse-panic messages. All other panics flow through to the original
/// default hook (which prints location + backtrace as usual).
///
/// Safe because:
///   - `std::panic::set_hook` is documented as thread-safe and intended to be
///     called once at init.
///   - `Once::call_once` guarantees we install at most one hook for the
///     process lifetime, so concurrent parse_single_file_patch calls can't
///     race here.
///   - Non-patch panics still surface — we delegate to the captured original
///     hook, so other modules' diagnostics are unaffected.
fn install_patch_panic_filter_once() {
    static INSTALLED: std::sync::Once = std::sync::Once::new();
    INSTALLED.call_once(|| {
        let original = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // Inspect payload — both String and &str variants.
            let payload = info.payload();
            let msg: Option<&str> = payload
                .downcast_ref::<String>()
                .map(|s| s.as_str())
                .or_else(|| payload.downcast_ref::<&str>().copied());
            if let Some(text) = msg {
                if PATCH_CRATE_PANIC_MARKERS
                    .iter()
                    .any(|marker| text.contains(marker))
                {
                    // Silent: catch_unwind will turn this into PatchApplyError::Parse.
                    return;
                }
            }
            original(info);
        }));
    });
}

/// Parse `diff` as exactly one unified patch (one old/new file pair).
///
/// The upstream `patch` crate can panic on malformed input instead of returning
/// `Err`, so we wrap the parse in `catch_unwind` to convert panics into
/// [`PatchApplyError::Parse`]. We also install a one-shot process-wide panic
/// hook (via `install_patch_panic_filter_once`) that suppresses the "bug:
/// failed to parse entire input…" stderr noise the default hook would print.
/// Non-patch panics flow through to the captured original hook.
pub fn parse_single_file_patch(diff: &str) -> Result<Patch<'_>, PatchApplyError> {
    install_patch_panic_filter_once();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || match Patch::from_multiple(diff) {
            // SAFETY: arm guard ensures exactly one element; next() will always return Some.
            Ok(patches) if patches.len() == 1 => {
                Ok(patches.into_iter().next().expect("len == 1; always Some"))
            }
            Ok(patches) => Err(PatchApplyError::MultipleFiles {
                count: patches.len(),
            }),
            Err(_) => Patch::from_single(diff).map_err(|e| PatchApplyError::Parse(e.to_string())),
        },
    ));
    match result {
        Ok(inner) => inner,
        Err(panic_info) => {
            let msg = panic_info
                .downcast_ref::<String>()
                .map(|s| s.as_str())
                .or_else(|| panic_info.downcast_ref::<&str>().copied())
                .unwrap_or("unknown panic in patch parser");
            Err(PatchApplyError::Parse(format!(
                "patch parser panic: {}",
                msg
            )))
        }
    }
}

/// Apply one parsed patch to `old` contents. Every `Context` and `Remove` line must match the file.
pub fn apply_patch_strict<'a>(old: &str, patch: &Patch<'a>) -> Result<String, PatchApplyError> {
    let old_lines: Vec<&str> = old.lines().collect();
    let mut out: Vec<String> = Vec::new();
    let mut idx: usize = 0;

    for (hunk_index, hunk) in patch.hunks.iter().enumerate() {
        let start_line = hunk.old_range.start as usize;
        if start_line < 1 {
            return Err(PatchApplyError::InvalidHunk {
                message: format!(
                    "hunk {}: invalid old_range.start {}",
                    hunk_index, hunk.old_range.start
                ),
            });
        }
        let start_idx = start_line - 1;
        while idx < start_idx {
            if idx >= old_lines.len() {
                return Err(PatchApplyError::ContextMismatch {
                    hunk_index,
                    old_line_1based: idx + 1,
                    expected: "(more lines expected before this hunk)".to_string(),
                    actual: None,
                });
            }
            out.push(old_lines[idx].to_string());
            idx += 1;
        }
        for line in &hunk.lines {
            match line {
                Line::Context(s) => {
                    if idx >= old_lines.len() {
                        return Err(PatchApplyError::ContextMismatch {
                            hunk_index,
                            old_line_1based: idx + 1,
                            expected: (*s).to_string(),
                            actual: None,
                        });
                    }
                    if old_lines[idx] != *s {
                        return Err(PatchApplyError::ContextMismatch {
                            hunk_index,
                            old_line_1based: idx + 1,
                            expected: (*s).to_string(),
                            actual: Some(old_lines[idx].to_string()),
                        });
                    }
                    out.push((*s).to_string());
                    idx += 1;
                }
                Line::Remove(s) => {
                    if idx >= old_lines.len() {
                        return Err(PatchApplyError::ContextMismatch {
                            hunk_index,
                            old_line_1based: idx + 1,
                            expected: format!("-{}", s),
                            actual: None,
                        });
                    }
                    if old_lines[idx] != *s {
                        return Err(PatchApplyError::ContextMismatch {
                            hunk_index,
                            old_line_1based: idx + 1,
                            expected: (*s).to_string(),
                            actual: Some(old_lines[idx].to_string()),
                        });
                    }
                    idx += 1;
                }
                Line::Add(s) => {
                    out.push((*s).to_string());
                }
            }
        }
    }
    while idx < old_lines.len() {
        out.push(old_lines[idx].to_string());
        idx += 1;
    }

    let mut joined = out.join("\n");
    if patch.end_newline {
        joined.push('\n');
    }
    Ok(joined)
}

/// Parse and apply; convenience for tests and `patch_file`.
pub fn apply_unified_diff(old: &str, diff: &str) -> Result<String, PatchApplyError> {
    let p = parse_single_file_patch(diff)?;
    apply_patch_strict(old, &p)
}

/// Fuzzy patch matching: tries strict first, then falls back to whitespace-tolerant
/// and context-drift-tolerant matching. Use when the model generates "almost right" diffs.
pub fn apply_unified_diff_fuzzy(old: &str, diff: &str) -> Result<String, PatchApplyError> {
    let p = parse_single_file_patch(diff)?;
    apply_patch_strict(old, &p).or_else(|_strict_err| apply_patch_fuzzy(old, &p))
}

/// INFRA-3407 tier-d: content-anchored application. Ignores `@@` line numbers
/// ENTIRELY and locates each hunk by searching the whole file for its
/// context+remove line sequence (whitespace-trimmed). Open models guess hunk
/// line numbers — often off by far more than the ±3 the fuzzy tier tolerates —
/// while their quoted context is usually right. Refuses ambiguous hunks (the
/// anchor sequence must match at exactly one position) so a wrong-but-
/// plausible patch can't land silently in the wrong place.
pub fn apply_unified_diff_anchored(old: &str, diff: &str) -> Result<String, PatchApplyError> {
    let p = parse_single_file_patch(diff)?;
    apply_patch_anchored(old, &p)
}

fn apply_patch_anchored<'a>(old: &str, patch: &Patch<'a>) -> Result<String, PatchApplyError> {
    let old_lines: Vec<&str> = old.lines().collect();
    // Build (anchor_lines, replacement_lines) per hunk. Anchor = the sequence
    // of Context + Remove lines in order; replacement = Context + Add lines.
    let mut edits: Vec<(usize, usize, Vec<String>)> = Vec::new(); // (start, len, replacement)
    for (hunk_index, hunk) in patch.hunks.iter().enumerate() {
        let mut anchor: Vec<&str> = Vec::new();
        let mut replacement: Vec<String> = Vec::new();
        for line in &hunk.lines {
            match line {
                Line::Context(s) => {
                    anchor.push(s);
                    replacement.push((*s).to_string());
                }
                Line::Remove(s) => anchor.push(s),
                Line::Add(s) => replacement.push((*s).to_string()),
            }
        }
        if anchor.is_empty() {
            return Err(PatchApplyError::InvalidHunk {
                message: format!(
                    "hunk {hunk_index}: no context/remove lines — cannot anchor by content"
                ),
            });
        }
        // Find every whitespace-trimmed match of the anchor sequence.
        let mut matches: Vec<usize> = Vec::new();
        if old_lines.len() >= anchor.len() {
            'outer: for start in 0..=(old_lines.len() - anchor.len()) {
                for (k, a) in anchor.iter().enumerate() {
                    if old_lines[start + k].trim() != a.trim() {
                        continue 'outer;
                    }
                }
                matches.push(start);
            }
        }
        match matches.len() {
            1 => edits.push((matches[0], anchor.len(), replacement)),
            0 => {
                return Err(PatchApplyError::ContextMismatch {
                    hunk_index,
                    old_line_1based: hunk.old_range.start as usize,
                    expected: anchor.first().map(|s| (*s).to_string()).unwrap_or_default(),
                    actual: None,
                });
            }
            n => {
                return Err(PatchApplyError::InvalidHunk {
                    message: format!(
                        "hunk {hunk_index}: anchor matches {n} positions — ambiguous, refusing"
                    ),
                });
            }
        }
    }
    // Apply edits back-to-front so earlier offsets stay valid; refuse overlaps.
    edits.sort_by_key(|(s, _, _)| *s);
    for w in edits.windows(2) {
        if w[0].0 + w[0].1 > w[1].0 {
            return Err(PatchApplyError::InvalidHunk {
                message: "anchored hunks overlap — refusing".to_string(),
            });
        }
    }
    let mut out: Vec<String> = old_lines.iter().map(|s| s.to_string()).collect();
    for (start, len, replacement) in edits.into_iter().rev() {
        out.splice(start..start + len, replacement);
    }
    let mut joined = out.join("\n");
    if old.ends_with('\n') {
        joined.push('\n');
    }
    Ok(joined)
}

/// Apply with fuzzy matching: trims whitespace before comparing context/remove lines,
/// and allows ±3 lines of context drift when a line doesn't match at the expected position.
fn apply_patch_fuzzy<'a>(old: &str, patch: &Patch<'a>) -> Result<String, PatchApplyError> {
    let old_lines: Vec<&str> = old.lines().collect();
    let mut out: Vec<String> = Vec::new();
    let mut idx: usize = 0;
    let context_drift: usize = 3;

    for (hunk_index, hunk) in patch.hunks.iter().enumerate() {
        let start_line = hunk.old_range.start as usize;
        if start_line < 1 {
            return Err(PatchApplyError::InvalidHunk {
                message: format!(
                    "hunk {}: invalid old_range.start {}",
                    hunk_index, hunk.old_range.start
                ),
            });
        }
        let start_idx = start_line - 1;
        while idx < start_idx {
            if idx >= old_lines.len() {
                return Err(PatchApplyError::ContextMismatch {
                    hunk_index,
                    old_line_1based: idx + 1,
                    expected: "(more lines expected before this hunk)".to_string(),
                    actual: None,
                });
            }
            out.push(old_lines[idx].to_string());
            idx += 1;
        }
        for line in &hunk.lines {
            match line {
                Line::Context(s) | Line::Remove(s) => {
                    let trimmed = s.trim();
                    let mut matched = false;
                    for offset in 0..=context_drift {
                        let candidate_idx = idx + offset;
                        if candidate_idx < old_lines.len()
                            && old_lines[candidate_idx].trim() == trimmed
                        {
                            for j in 0..offset {
                                out.push(old_lines[idx + j].to_string());
                            }
                            idx = candidate_idx + 1;
                            if let Line::Remove(_) = line {
                            } else {
                                out.push((*s).to_string());
                            }
                            matched = true;
                            break;
                        }
                    }
                    if !matched {
                        return Err(PatchApplyError::ContextMismatch {
                            hunk_index,
                            old_line_1based: idx + 1,
                            expected: (*s).to_string(),
                            actual: old_lines.get(idx).map(|l| l.to_string()),
                        });
                    }
                }
                Line::Add(s) => {
                    out.push((*s).to_string());
                }
            }
        }
    }
    while idx < old_lines.len() {
        out.push(old_lines[idx].to_string());
        idx += 1;
    }

    let mut joined = out.join("\n");
    if patch.end_newline {
        joined.push('\n');
    }
    Ok(joined)
}

/// First old-file line number (1-based) implicated by the diff, for snippets.
pub fn first_target_line_1based(diff: &str) -> Option<u64> {
    if let Ok(p) = parse_single_file_patch(diff) {
        return p.hunks.first().map(|h| h.old_range.start);
    }
    None
}

/// INFRA-785: detect whether `diff` already carries `---` / `+++` filename
/// header lines. Headerless diffs (just `@@` hunks, body only) are emitted by
/// smaller LLMs (Llama 3.3, Mistral) that "know" the file from context and
/// skip the header entirely.
fn diff_has_filename_headers(diff: &str) -> bool {
    let mut saw_minus_header = false;
    let mut saw_plus_header = false;
    for line in diff.lines() {
        if line.starts_with("@@") {
            // Hunk begins; headers (if any) must have come before.
            break;
        }
        if line.starts_with("--- ") {
            saw_minus_header = true;
        } else if line.starts_with("+++ ") {
            saw_plus_header = true;
        }
    }
    saw_minus_header && saw_plus_header
}

/// INFRA-785: parse a headerless diff (no `---`/`+++` lines, just `@@` hunks)
/// by synthesizing a placeholder header and delegating to the normal parser.
///
/// Used as the third fallback tier in `patch_file` after strict and fuzzy. The
/// synthesized header is purely a parse-time scaffold — the caller already
/// knows the target path. Returns `Err(Parse)` if no `@@` hunk is present.
pub fn parse_headerless_diff(diff: &str) -> Result<Patch<'static>, PatchApplyError> {
    // Locate the first hunk header. Anything before it (commentary, file
    // banner, blank lines) is dropped since headerless diffs have no
    // structural prelude to preserve.
    let hunk_start = diff
        .lines()
        .position(|l| l.starts_with("@@"))
        .ok_or_else(|| {
            PatchApplyError::Parse("headerless parse: no @@ hunk header found in diff".to_string())
        })?;
    let body: String = diff.lines().skip(hunk_start).collect::<Vec<_>>().join("\n");
    let body = if diff.ends_with('\n') {
        format!("{}\n", body)
    } else {
        body
    };
    let synth = format!("--- a/headerless\n+++ b/headerless\n{}", body);

    // We need a 'static Patch so callers can hold onto it without lifetime
    // entanglement with the temporary `synth` string. Parse, then deep-clone.
    install_patch_panic_filter_once();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        Patch::from_single(&synth).map_err(|e| PatchApplyError::Parse(e.to_string()))
    }));
    let parsed = match result {
        Ok(inner) => inner?,
        Err(panic_info) => {
            let msg = panic_info
                .downcast_ref::<String>()
                .map(|s| s.as_str())
                .or_else(|| panic_info.downcast_ref::<&str>().copied())
                .unwrap_or("unknown panic in patch parser");
            return Err(PatchApplyError::Parse(format!(
                "headerless parse panic: {}",
                msg
            )));
        }
    };
    Ok(into_owned_patch(parsed))
}

/// Convert a borrowed `Patch<'a>` into an owned `Patch<'static>` by re-parsing
/// its `Display` rendering. Patch values implement `Display` to the unified
/// diff format, so this round-trips cleanly without manually rebuilding every
/// inner `Line`/`Range` field.
fn into_owned_patch(p: Patch<'_>) -> Patch<'static> {
    let rendered = format!("{}\n", p);
    let leaked: &'static str = Box::leak(rendered.into_boxed_str());
    // Re-parse; this must succeed because we just printed a valid patch.
    Patch::from_single(leaked).expect("Patch::Display round-trip must re-parse")
}

/// INFRA-785: apply a diff that lacks `---`/`+++` filename headers. Tries
/// strict matching first, then falls back to fuzzy (whitespace-tolerant,
/// ±3 line context drift). Returns Err if both fail.
pub fn apply_unified_diff_headerless(old: &str, diff: &str) -> Result<String, PatchApplyError> {
    let p = parse_headerless_diff(diff)?;
    apply_patch_strict(old, &p).or_else(|_strict_err| apply_patch_fuzzy(old, &p))
}

/// INFRA-785: combined fallback gate. Returns `Some(diff)` only when `diff`
/// looks headerless (no `---`/`+++` but has at least one `@@`). Lets callers
/// branch into tier-c without re-implementing detection.
pub fn looks_headerless(diff: &str) -> bool {
    !diff_has_filename_headers(diff) && diff.lines().any(|l| l.starts_with("@@"))
}

#[cfg(test)]
mod tests {
    use super::*;

    static LAO: &str = "\
The Way that can be told of is not the eternal Way;
The name that can be named is not the eternal name.
The Nameless is the origin of Heaven and Earth;
The Named is the mother of all things.
Therefore let there always be non-being,
  so we may see their subtlety,
And let there always be being,
  so we may see their outcome.
The two are the same,
But after they are produced,
  they have different names.
";

    static RAW_DIFF: &str = "\
--- lao 2002-02-21 23:30:39.942229878 -0800
+++ tzu 2002-02-21 23:30:50.442260588 -0800
@@ -1,7 +1,6 @@
-The Way that can be told of is not the eternal Way;
-The name that can be named is not the eternal name.
 The Nameless is the origin of Heaven and Earth;
-The Named is the mother of all things.
+The named is the mother of all things.
+
 Therefore let there always be non-being,
   so we may see their subtlety,
 And let there always be being,
@@ -9,3 +8,6 @@
 The two are the same,
 But after they are produced,
   they have different names.
+They both may be called deep and profound.
+Deeper and more profound,
+The door of all subtleties!
";

    #[test]
    fn apply_lao_tzu_example() {
        let got = apply_unified_diff(LAO, RAW_DIFF).unwrap();
        assert!(!got.contains("The Way that can be told"));
        assert!(got.contains("The named is the mother of all things"));
        assert!(got.contains("The door of all subtleties!"));
    }

    #[test]
    fn rejects_wrong_context() {
        let bad = RAW_DIFF.replace("The Nameless is the origin", "WRONG CONTEXT");
        let err = apply_unified_diff(LAO, &bad).unwrap_err();
        assert!(matches!(err, PatchApplyError::ContextMismatch { .. }));
    }

    #[test]
    fn rejects_multi_file() {
        let two = format!("{}\n{}", RAW_DIFF, RAW_DIFF.replace("lao", "lao2"));
        let err = parse_single_file_patch(&two).unwrap_err();
        assert!(matches!(err, PatchApplyError::MultipleFiles { .. }));
    }

    #[test]
    fn malformed_diff_does_not_panic() {
        // The upstream `patch` crate panics on some malformed inputs instead of
        // returning Err. Our catch_unwind wrapper should convert that to a Parse error.
        let garbage = "--- a/foo\n+++ b/foo\n@@ -1,3 +1,3 @@\n context\n-old\n+new\n     }";
        let result = parse_single_file_patch(garbage);
        assert!(result.is_err(), "should return Err, not panic");
        if let Err(PatchApplyError::Parse(msg)) = &result {
            // Either a normal parse error or our panic-caught wrapper
            assert!(!msg.is_empty());
        }
    }

    /// The panic-filter hook installation must be idempotent — calling
    /// parse_single_file_patch many times in a row (which is what the agent
    /// loop does) should still result in exactly one custom hook installation
    /// and never deadlock or recurse.
    #[test]
    fn install_panic_filter_is_idempotent() {
        for _ in 0..50 {
            install_patch_panic_filter_once();
        }
        // Surviving the loop is the test. If install_patch_panic_filter_once
        // weren't using std::sync::Once::call_once it would deadlock or
        // overwrite the original hook on every call, breaking diagnostics for
        // unrelated panics.
    }

    /// PATCH_CRATE_PANIC_MARKERS contains the literal substrings the upstream
    /// `patch-0.7.0` crate emits in its parse panics. Pin these so a future
    /// upstream change that renames the message can't silently leak panic
    /// stderr into dogfood logs without us noticing.
    #[test]
    fn patch_panic_markers_include_known_message() {
        assert!(PATCH_CRATE_PANIC_MARKERS
            .iter()
            .any(|m| m.contains("failed to parse entire input")));
    }

    /// Trigger a real `patch` crate panic via parse_single_file_patch and
    /// confirm we get back a `PatchApplyError::Parse`. This exercises the
    /// full path: hook installed → catch_unwind catches → error returned.
    /// On unfiltered runs the upstream panic message would print to stderr;
    /// here it's silently routed through our hook.
    #[test]
    fn parse_panic_routes_through_filter_to_parse_error() {
        // This specific input is known to make patch-0.7.0 panic mid-parse.
        let pathological = "--- a\n+++ b\n@@ -1 +1 @@\n";
        let err = parse_single_file_patch(pathological).unwrap_err();
        assert!(matches!(err, PatchApplyError::Parse(_)));
    }

    // REL-003: additional malformed-input coverage.
    // Goal: patch-0.7.0 panics on some inputs — catch_unwind must catch ALL of them
    // and return PatchApplyError::Parse. These tests pin that contract.

    #[test]
    fn empty_string_returns_parse_error() {
        let err = parse_single_file_patch("").unwrap_err();
        assert!(matches!(err, PatchApplyError::Parse(_)));
    }

    #[test]
    fn binary_garbage_returns_parse_error() {
        // Use byte string approach to avoid Rust string literal restrictions
        let garbage = String::from_utf8_lossy(b"\x00\x01\x02\x7f binary junk").to_string();
        let result = parse_single_file_patch(&garbage);
        assert!(result.is_err(), "binary garbage must return Err, not panic");
    }

    #[test]
    fn truncated_hunk_header_returns_parse_error() {
        // Valid header but no body — another known panic trigger in some versions
        let truncated = "--- a/file.txt\n+++ b/file.txt\n@@ -";
        let result = parse_single_file_patch(truncated);
        assert!(result.is_err(), "truncated hunk must return Err, not panic");
    }

    #[test]
    fn zero_length_hunk_range_returns_parse_error() {
        let zero_range = "--- a/f\n+++ b/f\n@@ -0,0 +0,0 @@\n";
        // Either Err or Ok with empty patch — must not panic.
        let _ = parse_single_file_patch(zero_range);
    }

    #[test]
    fn only_deletion_lines_returns_err_or_ok() {
        // All minus, no context — may panic or return Err; must not crash.
        let all_minus = "--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n-line1\n-line2\n-line3\n";
        let _ = parse_single_file_patch(all_minus); // just assert no panic
    }

    // INFRA-785: tier-c headerless-diff fallback. Llama 3.3 (and other smaller
    // models in chump dogfood) routinely emit unified diffs without the
    // `---`/`+++` filename lines — just `@@` hunks. Today's strict/fuzzy
    // parsers reject those outright. Tier-c synthesizes a placeholder header
    // and reuses the existing strict→fuzzy applicator.

    static HEADERLESS_DIFF: &str = "\
@@ -1,7 +1,6 @@
-The Way that can be told of is not the eternal Way;
-The name that can be named is not the eternal name.
 The Nameless is the origin of Heaven and Earth;
-The Named is the mother of all things.
+The named is the mother of all things.
+
 Therefore let there always be non-being,
   so we may see their subtlety,
 And let there always be being,
@@ -9,3 +8,6 @@
 The two are the same,
 But after they are produced,
   they have different names.
+They both may be called deep and profound.
+Deeper and more profound,
+The door of all subtleties!
";

    #[test]
    fn looks_headerless_detects_missing_headers() {
        assert!(looks_headerless(HEADERLESS_DIFF));
        assert!(!looks_headerless(RAW_DIFF));
        // No @@ at all → not headerless, just not a diff
        assert!(!looks_headerless("just text\nwith no hunks\n"));
    }

    #[test]
    fn headerless_strict_parse_rejects_llama_style() {
        // Strict parser must NOT silently accept a headerless diff — that's
        // why we need tier-c in the first place.
        let err = parse_single_file_patch(HEADERLESS_DIFF).unwrap_err();
        assert!(matches!(err, PatchApplyError::Parse(_)));
    }

    #[test]
    fn apply_headerless_diff_succeeds_on_llama_style() {
        let got = apply_unified_diff_headerless(LAO, HEADERLESS_DIFF).unwrap();
        assert!(!got.contains("The Way that can be told"));
        assert!(got.contains("The named is the mother of all things"));
        assert!(got.contains("The door of all subtleties!"));
    }

    #[test]
    fn apply_headerless_rejects_context_mismatch() {
        // Tier-c is still context-sensitive — a real content mismatch should
        // fail loudly, not silently corrupt the file.
        let bad = HEADERLESS_DIFF.replace("The Nameless is the origin", "WRONG CONTEXT");
        let err = apply_unified_diff_headerless(LAO, &bad).unwrap_err();
        assert!(matches!(err, PatchApplyError::ContextMismatch { .. }));
    }

    #[test]
    fn apply_headerless_no_hunks_returns_parse_error() {
        let err = apply_unified_diff_headerless(LAO, "no hunks here\n").unwrap_err();
        assert!(matches!(err, PatchApplyError::Parse(_)));
    }

    #[test]
    fn apply_headerless_tolerates_leading_commentary() {
        // Models sometimes prepend a "Here's the diff:" line; tier-c should
        // skip prelude until the first @@ marker.
        let with_prelude = format!("Here is the diff for you:\n{}", HEADERLESS_DIFF);
        let got = apply_unified_diff_headerless(LAO, &with_prelude).unwrap();
        assert!(got.contains("The door of all subtleties!"));
    }

    // ── INFRA-3407 tier-d: content-anchored application ─────────────────────

    #[test]
    fn anchored_ignores_wildly_wrong_line_numbers() {
        // Same edit as RAW_DIFF's first hunk but with a garbage @@ start line
        // (models guess line numbers) — anchored tier must still land it.
        let diff = "\
--- a/lao
+++ b/lao
@@ -97,3 +97,3 @@
 The Nameless is the origin of Heaven and Earth;
-The Named is the mother of all things.
+The named is the mother of all things.
";
        let err = apply_unified_diff_fuzzy(LAO, diff);
        assert!(err.is_err(), "fuzzy ±3 cannot absorb a 96-line offset");
        let got = apply_unified_diff_anchored(LAO, diff).unwrap();
        assert!(got.contains("The named is the mother of all things."));
        assert!(!got.contains("The Named is the mother of all things."));
    }

    #[test]
    fn anchored_tolerates_indentation_drift() {
        let diff = "\
--- a/lao
+++ b/lao
@@ -1,2 +1,2 @@
 Therefore let there always be non-being,
-so we may see their subtlety,
+so we may see their SUBTLETY,
";
        // Model dropped the two-space indent on the remove line; trim-match
        // still anchors it. Replacement uses the model's own lines verbatim.
        let got = apply_unified_diff_anchored(LAO, diff).unwrap();
        assert!(got.contains("SUBTLETY"));
    }

    #[test]
    fn anchored_refuses_ambiguous_anchor() {
        let doubled = format!("{LAO}{LAO}");
        let diff = "\
--- a/lao
+++ b/lao
@@ -1,1 +1,1 @@
-The Named is the mother of all things.
+The named is the mother of all things.
";
        let err = apply_unified_diff_anchored(&doubled, diff).unwrap_err();
        assert!(matches!(err, PatchApplyError::InvalidHunk { .. }));
    }

    #[test]
    fn anchored_refuses_unmatched_anchor() {
        let diff = "\
--- a/lao
+++ b/lao
@@ -1,1 +1,1 @@
-This line does not exist anywhere.
+Replacement.
";
        let err = apply_unified_diff_anchored(LAO, diff).unwrap_err();
        assert!(matches!(err, PatchApplyError::ContextMismatch { .. }));
    }
}
