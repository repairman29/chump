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

/// Parse `diff` as exactly one unified patch (one old/new file pair).
///
/// The upstream `patch` crate can panic on malformed input instead of returning
/// `Err`, so we wrap the parse in `catch_unwind` to convert panics into
/// [`PatchApplyError::Parse`].
///
/// The default panic hook still prints to stderr ("bug: failed to parse entire
/// input…"), which is cosmetic noise in dogfood logs but harmless — the `Err`
/// is returned and the agent loop continues. A process-wide panic hook swap
/// would be cleaner but is not thread-safe.
pub fn parse_single_file_patch(diff: &str) -> Result<Patch<'_>, PatchApplyError> {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match Patch::from_multiple(diff) {
            Ok(patches) if patches.len() == 1 => Ok(patches.into_iter().next().unwrap()),
            Ok(patches) => Err(PatchApplyError::MultipleFiles {
                count: patches.len(),
            }),
            Err(_) => {
                Patch::from_single(diff).map_err(|e| PatchApplyError::Parse(e.to_string()))
            }
        }
    }));
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

/// First old-file line number (1-based) implicated by the diff, for snippets.
pub fn first_target_line_1based(diff: &str) -> Option<u64> {
    if let Ok(p) = parse_single_file_patch(diff) {
        return p.hunks.first().map(|h| h.old_range.start);
    }
    None
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
}
