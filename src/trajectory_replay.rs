//! Golden trajectory replay — the multi-turn piece deferred from `EvalCase`.
//!
//! `src/eval_harness.rs` checks single-turn properties (52 seed cases). It
//! can't catch the kind of bug that manifests across 3-25 turns with
//! accumulating state — the qwen3:8b `<think>` regression is the canonical
//! example: every single turn passed schema validation, but the suite of
//! turns drifted until the 25-iteration cap tripped. This module closes
//! `EVAL-003` in `docs/gaps.yaml`.
//!
//! A [`GoldenTrajectory`] is a saved user-turn sequence plus structural
//! expectations about the tool-call shape and final state. The "structural"
//! part is load-bearing: exact-text diffs fail on cosmetic phrasing drift,
//! so we match on tool NAMES (order-sensitive or multiset), argument
//! patterns (substring / JSON-path contains), and final-state properties.
//!
//! ## Storage
//!
//! Trajectories live as JSON files in `tests/fixtures/golden_trajectories/`
//! so they can be reviewed via normal code-review and version-controlled
//! alongside the code that makes them pass. Use [`load_trajectory_from_file`]
//! to read them.
//!
//! ## Replay
//!
//! The replay driver itself (feeding a trajectory into a live agent and
//! collecting tool calls) lives in `scripts/eval/replay-trajectory.sh` — that
//! part is inherently integration-style. The module here is the offline
//! scoring engine: given a trajectory + an observed [`ActualRun`], produce
//! a [`TrajectoryReplayResult`] describing every mismatch.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::eval_harness::ExpectedProperty;

/// A saved multi-turn conversation expectation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoldenTrajectory {
    /// Stable identifier (see `tests/fixtures/golden_trajectories/*.json` filenames).
    pub id: String,
    /// Human-readable description of what this trajectory exercises.
    pub description: String,
    /// User turns in order. A 1-turn trajectory is a single string; a
    /// multi-turn one is the actual back-and-forth we want to replay.
    pub user_turns: Vec<String>,
    /// Tool calls the agent is expected to make, in order (unless
    /// `order_sensitive` is false).
    pub expected_tool_sequence: Vec<ExpectedToolCall>,
    /// Tools the agent must NOT call. Caught as a hard failure.
    #[serde(default)]
    pub forbidden_tools: Vec<String>,
    /// Single-turn properties that must hold on the final assistant message.
    #[serde(default)]
    pub expected_properties: Vec<ExpectedProperty>,
    /// If true (default), the tool-call sequence must match the order in
    /// `expected_tool_sequence`. When false, we check as a multiset.
    #[serde(default = "default_true")]
    pub order_sensitive: bool,
    /// If set, total tool calls must be >= this.
    #[serde(default)]
    pub min_tool_calls: Option<usize>,
    /// If set, total tool calls must be <= this. Catches "storming" regressions.
    #[serde(default)]
    pub max_tool_calls: Option<usize>,
}

fn default_true() -> bool {
    true
}

/// One expected tool call. Name must match exactly; argument matchers are
/// structural (substring within a JSON path) so cosmetic phrasing drift on
/// the args doesn't fail.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpectedToolCall {
    pub name: String,
    /// Optional structural argument matchers. Each matcher targets a JSON
    /// path in the tool call's `input` (e.g. `"path"` or `"options.num_ctx"`).
    #[serde(default)]
    pub arg_matchers: Vec<ArgMatcher>,
}

/// A single argument match: pull a value at `path` from the tool call's input
/// JSON and assert it matches `pattern`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArgMatcher {
    /// Dotted JSON path in the tool call input (e.g. `"path"`, `"diff"`).
    pub path: String,
    /// Match strategy.
    pub pattern: ArgPattern,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ArgPattern {
    /// Value at `path` is a string containing `value` (substring).
    Contains { value: String },
    /// Value at `path` equals `value` as a string.
    Equals { value: String },
    /// Value at `path` is a non-empty array/object/string.
    NonEmpty,
    /// Value at `path` is present (key exists, any type).
    Present,
}

/// What the agent actually did. Callers populate this from a replay run —
/// whether that's a live agent call or a recorded transcript.
#[derive(Debug, Clone)]
pub struct ActualRun {
    /// Ordered list of tool calls the agent made during the replay.
    pub tool_calls: Vec<ActualToolCall>,
    /// Final user-visible text the agent produced (post-`<think>` strip).
    pub final_text: String,
}

#[derive(Debug, Clone)]
pub struct ActualToolCall {
    pub name: String,
    pub input: Value,
}

/// Verdict after scoring an [`ActualRun`] against a [`GoldenTrajectory`].
#[derive(Debug, Clone)]
pub struct TrajectoryReplayResult {
    pub matched: bool,
    pub step_diffs: Vec<StepDiff>,
    pub property_diffs: Vec<PropertyDiff>,
    pub tool_count_ok: bool,
    pub forbidden_tool_violations: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum StepDiff {
    /// An expected tool call was missing / mismatched. `index` is the
    /// position in `expected_tool_sequence`.
    Missing {
        index: usize,
        expected_name: String,
        reason: String,
    },
    /// Tool called with wrong argument. Reported in addition to a matched
    /// tool name if arg_matchers fail.
    ArgMismatch {
        index: usize,
        tool_name: String,
        path: String,
        reason: String,
    },
    /// Expected tool calls consumed; the replay still has extra calls. Not
    /// always a failure (informational in multiset mode).
    ExtraCalls { count: usize },
}

#[derive(Debug, Clone)]
pub struct PropertyDiff {
    pub property: String,
    pub passed: bool,
}

/// Score an [`ActualRun`] against a [`GoldenTrajectory`].
pub fn score_trajectory(
    trajectory: &GoldenTrajectory,
    actual: &ActualRun,
) -> TrajectoryReplayResult {
    let mut step_diffs = Vec::new();

    // Tool count bounds.
    let total = actual.tool_calls.len();
    let min_ok = trajectory.min_tool_calls.is_none_or(|m| total >= m);
    let max_ok = trajectory.max_tool_calls.is_none_or(|m| total <= m);
    let tool_count_ok = min_ok && max_ok;

    // Forbidden-tool check.
    let forbidden_tool_violations: Vec<String> = actual
        .tool_calls
        .iter()
        .filter(|t| trajectory.forbidden_tools.iter().any(|f| f == &t.name))
        .map(|t| t.name.clone())
        .collect();

    // Tool sequence match.
    if trajectory.order_sensitive {
        step_diffs.extend(order_sensitive_diffs(
            &trajectory.expected_tool_sequence,
            &actual.tool_calls,
        ));
    } else {
        step_diffs.extend(multiset_diffs(
            &trajectory.expected_tool_sequence,
            &actual.tool_calls,
        ));
    }

    // Property checks on final text.
    let property_diffs: Vec<PropertyDiff> = trajectory
        .expected_properties
        .iter()
        .map(|p| {
            let tool_names: Vec<String> =
                actual.tool_calls.iter().map(|t| t.name.clone()).collect();
            let passed = crate::eval_harness::check_property(p, &actual.final_text, &tool_names);
            PropertyDiff {
                property: format!("{:?}", p),
                passed,
            }
        })
        .collect();

    let matched = step_diffs.is_empty()
        && property_diffs.iter().all(|p| p.passed)
        && tool_count_ok
        && forbidden_tool_violations.is_empty();

    TrajectoryReplayResult {
        matched,
        step_diffs,
        property_diffs,
        tool_count_ok,
        forbidden_tool_violations,
    }
}

fn order_sensitive_diffs(
    expected: &[ExpectedToolCall],
    actual: &[ActualToolCall],
) -> Vec<StepDiff> {
    let mut diffs = Vec::new();
    // Walk the expected sequence. For each expected call, advance the actual
    // cursor until we find the tool name. Gaps in between are allowed —
    // small models sometimes sprinkle extra read_files. What's NOT allowed
    // is skipping an expected call or getting them out of order.
    let mut cursor = 0usize;
    for (idx, exp) in expected.iter().enumerate() {
        let found = actual[cursor..]
            .iter()
            .position(|a| a.name == exp.name)
            .map(|p| p + cursor);
        match found {
            Some(pos) => {
                // Check arg_matchers.
                for matcher in &exp.arg_matchers {
                    if let Err(reason) = apply_matcher(&actual[pos].input, matcher) {
                        diffs.push(StepDiff::ArgMismatch {
                            index: idx,
                            tool_name: exp.name.clone(),
                            path: matcher.path.clone(),
                            reason,
                        });
                    }
                }
                cursor = pos + 1;
            }
            None => {
                diffs.push(StepDiff::Missing {
                    index: idx,
                    expected_name: exp.name.clone(),
                    reason: format!(
                        "expected tool '{}' not found from position {} onward",
                        exp.name, cursor
                    ),
                });
            }
        }
    }
    // Any calls past the last matched cursor are "extras" — not failing,
    // but we note the count so a reviewer sees it.
    let extras = actual.len().saturating_sub(cursor);
    if extras > 0 {
        diffs.push(StepDiff::ExtraCalls { count: extras });
    }
    diffs
}

fn multiset_diffs(expected: &[ExpectedToolCall], actual: &[ActualToolCall]) -> Vec<StepDiff> {
    let mut diffs = Vec::new();
    let mut remaining: Vec<&ActualToolCall> = actual.iter().collect();
    for (idx, exp) in expected.iter().enumerate() {
        // Find first un-consumed actual call matching this name.
        let pos = remaining.iter().position(|a| a.name == exp.name);
        match pos {
            Some(p) => {
                for matcher in &exp.arg_matchers {
                    if let Err(reason) = apply_matcher(&remaining[p].input, matcher) {
                        diffs.push(StepDiff::ArgMismatch {
                            index: idx,
                            tool_name: exp.name.clone(),
                            path: matcher.path.clone(),
                            reason,
                        });
                    }
                }
                remaining.remove(p);
            }
            None => {
                diffs.push(StepDiff::Missing {
                    index: idx,
                    expected_name: exp.name.clone(),
                    reason: format!("no un-consumed actual call with name '{}'", exp.name),
                });
            }
        }
    }
    if !remaining.is_empty() {
        diffs.push(StepDiff::ExtraCalls {
            count: remaining.len(),
        });
    }
    diffs
}

fn apply_matcher(input: &Value, matcher: &ArgMatcher) -> std::result::Result<(), String> {
    let node = path_get(input, &matcher.path);
    match &matcher.pattern {
        ArgPattern::Present => match node {
            Some(_) => Ok(()),
            None => Err(format!("path '{}' not present", matcher.path)),
        },
        ArgPattern::NonEmpty => match node {
            Some(v) => {
                let empty = match v {
                    Value::String(s) => s.is_empty(),
                    Value::Array(a) => a.is_empty(),
                    Value::Object(o) => o.is_empty(),
                    Value::Null => true,
                    _ => false,
                };
                if empty {
                    Err(format!("path '{}' exists but is empty", matcher.path))
                } else {
                    Ok(())
                }
            }
            None => Err(format!("path '{}' not present", matcher.path)),
        },
        ArgPattern::Equals { value } => match node {
            Some(Value::String(s)) if s == value => Ok(()),
            Some(Value::Number(n)) if n.to_string() == *value => Ok(()),
            Some(Value::Bool(b)) if b.to_string() == *value => Ok(()),
            Some(other) => Err(format!(
                "path '{}' = {:?}, expected equals '{}'",
                matcher.path, other, value
            )),
            None => Err(format!("path '{}' not present", matcher.path)),
        },
        ArgPattern::Contains { value } => match node {
            Some(Value::String(s)) if s.contains(value.as_str()) => Ok(()),
            Some(Value::String(s)) => Err(format!(
                "path '{}' = {:?}, expected to contain '{}'",
                matcher.path, s, value
            )),
            Some(other) => Err(format!(
                "path '{}' is not a string ({:?}), cannot `contains`",
                matcher.path, other
            )),
            None => Err(format!("path '{}' not present", matcher.path)),
        },
    }
}

/// Dotted JSON path lookup. `a.b.c` descends objects; bare numbers index
/// arrays (`items.0.name`). Returns `None` if any segment is missing.
fn path_get<'a>(root: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = root;
    if path.is_empty() {
        return Some(cur);
    }
    for segment in path.split('.') {
        cur = match cur {
            Value::Object(o) => o.get(segment)?,
            Value::Array(a) => {
                let idx: usize = segment.parse().ok()?;
                a.get(idx)?
            }
            _ => return None,
        };
    }
    Some(cur)
}

/// Load a trajectory from a JSON file (see `tests/fixtures/golden_trajectories/`).
pub fn load_trajectory_from_file(path: &std::path::Path) -> Result<GoldenTrajectory> {
    let s = std::fs::read_to_string(path)
        .map_err(|e| anyhow!("read trajectory {}: {}", path.display(), e))?;
    let t: GoldenTrajectory = serde_json::from_str(&s)
        .map_err(|e| anyhow!("parse trajectory {}: {}", path.display(), e))?;
    if t.id.is_empty() {
        return Err(anyhow!("trajectory {} is missing `id`", path.display()));
    }
    Ok(t)
}

/// Load every `*.json` trajectory under `dir`, sorted by filename for
/// deterministic replay order.
pub fn load_trajectories_from_dir(dir: &std::path::Path) -> Result<Vec<GoldenTrajectory>> {
    let mut paths: Vec<std::path::PathBuf> = std::fs::read_dir(dir)
        .map_err(|e| anyhow!("read_dir {}: {}", dir.display(), e))?
        .filter_map(|r| r.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("json"))
        .collect();
    paths.sort();
    let mut out = Vec::new();
    for p in paths {
        out.push(load_trajectory_from_file(&p)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tc(name: &str, input: Value) -> ActualToolCall {
        ActualToolCall {
            name: name.to_string(),
            input,
        }
    }

    fn simple_traj() -> GoldenTrajectory {
        GoldenTrajectory {
            id: "t1".into(),
            description: "read then patch".into(),
            user_turns: vec!["fix it".into()],
            expected_tool_sequence: vec![
                ExpectedToolCall {
                    name: "read_file".into(),
                    arg_matchers: vec![ArgMatcher {
                        path: "path".into(),
                        pattern: ArgPattern::Contains {
                            value: "policy".into(),
                        },
                    }],
                },
                ExpectedToolCall {
                    name: "patch_file".into(),
                    arg_matchers: vec![],
                },
            ],
            forbidden_tools: vec!["git_push".into()],
            expected_properties: vec![],
            order_sensitive: true,
            min_tool_calls: Some(2),
            max_tool_calls: Some(10),
        }
    }

    #[test]
    fn exact_match_happy_path() {
        let actual = ActualRun {
            tool_calls: vec![
                tc("read_file", json!({"path": "src/policy_override.rs"})),
                tc(
                    "patch_file",
                    json!({"path": "src/policy_override.rs", "diff": "..."}),
                ),
            ],
            final_text: "Done.".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        assert!(r.matched, "happy path should match: {:?}", r);
        assert!(r.step_diffs.is_empty());
        assert!(r.forbidden_tool_violations.is_empty());
    }

    #[test]
    fn extra_reads_in_between_are_allowed() {
        // Small model sprinkled an extra read_file; expected sequence is
        // still present in order. Should still match.
        let actual = ActualRun {
            tool_calls: vec![
                tc("read_file", json!({"path": "src/policy_override.rs"})),
                tc("read_file", json!({"path": "src/main.rs"})),
                tc("patch_file", json!({"path": "src/policy_override.rs"})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        // Not a `matched=true` case because `ExtraCalls` is emitted, but
        // no `Missing` and no `ArgMismatch`.
        assert!(r
            .step_diffs
            .iter()
            .all(|d| matches!(d, StepDiff::ExtraCalls { .. })));
    }

    #[test]
    fn missing_tool_is_reported() {
        let actual = ActualRun {
            tool_calls: vec![tc("read_file", json!({"path": "src/policy_override.rs"}))],
            final_text: "".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        assert!(!r.matched);
        assert!(r
            .step_diffs
            .iter()
            .any(|d| matches!(d, StepDiff::Missing { expected_name, .. } if expected_name == "patch_file")));
    }

    #[test]
    fn arg_mismatch_reported_even_when_name_matches() {
        let actual = ActualRun {
            tool_calls: vec![
                tc("read_file", json!({"path": "src/other.rs"})),
                tc("patch_file", json!({})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        assert!(!r.matched);
        assert!(r.step_diffs.iter().any(|d| matches!(
            d,
            StepDiff::ArgMismatch { tool_name, path, .. }
            if tool_name == "read_file" && path == "path"
        )));
    }

    #[test]
    fn forbidden_tool_violation_caught() {
        let actual = ActualRun {
            tool_calls: vec![
                tc("read_file", json!({"path": "src/policy_override.rs"})),
                tc("patch_file", json!({})),
                tc("git_push", json!({})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        assert!(!r.matched);
        assert_eq!(r.forbidden_tool_violations, vec!["git_push".to_string()]);
    }

    #[test]
    fn order_violation_caught() {
        // patch_file before read_file — classic "model writes before reading" bug.
        let actual = ActualRun {
            tool_calls: vec![
                tc("patch_file", json!({})),
                tc("read_file", json!({"path": "src/policy_override.rs"})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&simple_traj(), &actual);
        assert!(
            !r.matched,
            "out-of-order tools should fail order-sensitive match"
        );
    }

    #[test]
    fn multiset_mode_ignores_order() {
        let mut traj = simple_traj();
        traj.order_sensitive = false;
        let actual = ActualRun {
            tool_calls: vec![
                tc("patch_file", json!({})),
                tc("read_file", json!({"path": "src/policy_override.rs"})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&traj, &actual);
        assert!(r.matched, "multiset mode should accept reversed order");
    }

    #[test]
    fn min_tool_calls_enforced() {
        let mut traj = simple_traj();
        traj.min_tool_calls = Some(5);
        let actual = ActualRun {
            tool_calls: vec![
                tc("read_file", json!({"path": "src/policy_override.rs"})),
                tc("patch_file", json!({})),
            ],
            final_text: "".into(),
        };
        let r = score_trajectory(&traj, &actual);
        assert!(!r.tool_count_ok);
        assert!(!r.matched);
    }

    #[test]
    fn max_tool_calls_catches_storm() {
        // The qwen3:8b regression would have tripped this: 25 patch_file calls.
        let mut traj = simple_traj();
        traj.max_tool_calls = Some(5);
        let mut calls = vec![tc("read_file", json!({"path": "src/policy_override.rs"}))];
        for _ in 0..25 {
            calls.push(tc("patch_file", json!({})));
        }
        let actual = ActualRun {
            tool_calls: calls,
            final_text: "".into(),
        };
        let r = score_trajectory(&traj, &actual);
        assert!(!r.tool_count_ok, "25 calls must trip max_tool_calls=5");
        assert!(!r.matched);
    }

    // ── Path matcher tests ─────────────────────────────────────────────

    #[test]
    fn path_get_nested_object() {
        let v = json!({"a": {"b": {"c": 7}}});
        assert_eq!(path_get(&v, "a.b.c"), Some(&json!(7)));
        assert_eq!(path_get(&v, "a.b"), Some(&json!({"c": 7})));
        assert_eq!(path_get(&v, "a.b.d"), None);
    }

    #[test]
    fn path_get_array_index() {
        let v = json!({"items": ["zero", "one", "two"]});
        assert_eq!(path_get(&v, "items.1"), Some(&json!("one")));
        assert_eq!(path_get(&v, "items.99"), None);
    }

    #[test]
    fn matcher_contains_substring() {
        let v = json!({"diff": "---\n+++\n@@ -1,3 +1,3 @@"});
        let m = ArgMatcher {
            path: "diff".into(),
            pattern: ArgPattern::Contains { value: "@@".into() },
        };
        assert!(apply_matcher(&v, &m).is_ok());
    }

    #[test]
    fn matcher_non_empty_rejects_empty() {
        let v = json!({"diff": ""});
        let m = ArgMatcher {
            path: "diff".into(),
            pattern: ArgPattern::NonEmpty,
        };
        assert!(apply_matcher(&v, &m).is_err());
    }

    #[test]
    fn matcher_equals_on_number() {
        let v = json!({"count": 42});
        let m = ArgMatcher {
            path: "count".into(),
            pattern: ArgPattern::Equals { value: "42".into() },
        };
        assert!(apply_matcher(&v, &m).is_ok());
    }

    // ── Loader round-trip ──────────────────────────────────────────────

    #[test]
    fn trajectory_json_round_trips() {
        let t = simple_traj();
        let s = serde_json::to_string(&t).unwrap();
        let back: GoldenTrajectory = serde_json::from_str(&s).unwrap();
        assert_eq!(t.id, back.id);
        assert_eq!(
            t.expected_tool_sequence.len(),
            back.expected_tool_sequence.len()
        );
    }

    #[test]
    fn load_from_missing_file_returns_err() {
        let r =
            load_trajectory_from_file(std::path::Path::new("/definitely/not/a/real/path/t.json"));
        assert!(r.is_err());
    }

    #[test]
    fn load_bundled_fixtures_if_present() {
        // Sanity check: if the fixtures directory exists at the repo root,
        // every JSON in it should parse. Fixtures may not exist in every
        // test environment (e.g. `cargo test` run from a different cwd), so
        // skip gracefully if the dir is missing.
        let dir = std::path::Path::new("tests/fixtures/golden_trajectories");
        if !dir.is_dir() {
            return;
        }
        let trajectories =
            load_trajectories_from_dir(dir).expect("bundled fixture dir must parse cleanly");
        for t in &trajectories {
            assert!(!t.id.is_empty(), "trajectory from fixtures has empty id");
            assert!(
                !t.user_turns.is_empty(),
                "trajectory {} has no user_turns",
                t.id
            );
        }
    }
}
