//! EFFECTIVE-440: scaffold-and-holes primitive.
//!
//! Given a MERGED skeleton PR (traits + `todo!()` holes + failing tests),
//! mechanically locate every hole so the caller can file one tiny,
//! disjoint, mechanically-verifiable "fill this hole" leaf gap per hole
//! instead of one open-ended gap. This is the structural fix for the
//! merge-race + definition-of-ready problems that open-ended gaps create:
//! agent diffs collapse to "implement fn X at file:line, make test Y pass".

use std::path::{Path, PathBuf};

/// One `todo!()` hole discovered in a scaffold PR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TodoHole {
    /// Path to the file, relative to the scan root.
    pub file: PathBuf,
    /// 1-indexed line number of the `todo!()` call.
    pub line: usize,
    /// Enclosing `fn` name, if one could be determined.
    pub function: Option<String>,
    /// Name of a same-file test that appears to exercise `function`
    /// (matched by naming convention: `test_<fn>` / `<fn>_test`, or a
    /// `#[test]` fn whose body calls `function`).
    pub nearest_test: Option<String>,
}

/// Scan a single file's source text for `todo!()` holes.
///
/// Pure function over text so it's trivially unit-testable without
/// touching the filesystem.
pub fn find_todo_holes_in_source(src: &str) -> Vec<(usize, Option<String>, Option<String>)> {
    let lines: Vec<&str> = src.lines().collect();

    // Collect (line_idx, fn_name) for every `fn` declaration so we can find
    // the nearest preceding one for a given hole.
    let mut fn_starts: Vec<(usize, String)> = Vec::new();
    for (idx, line) in lines.iter().enumerate() {
        if let Some(name) = extract_fn_name(line) {
            fn_starts.push((idx, name));
        }
    }

    // Collect test fn names (both `#[test] fn X` pairs and any fn whose
    // name looks like a test for another fn) plus, for each test fn, the
    // set of identifiers it calls (mechanical body scan) so we can match
    // holes to tests even without naming-convention overlap.
    let mut test_fns: Vec<(String, String)> = Vec::new(); // (test_name, body_text)
    let mut idx = 0;
    while idx < lines.len() {
        if lines[idx].trim_start().starts_with("#[test]") {
            // Find the fn name on the next non-attribute line.
            let mut j = idx + 1;
            while j < lines.len() && lines[j].trim_start().starts_with('#') {
                j += 1;
            }
            if let Some(name) = j.checked_sub(0).and_then(|_| extract_fn_name(lines[j])) {
                let body: String = lines[j..lines.len().min(j + 60)].join("\n");
                test_fns.push((name, body));
            }
        }
        idx += 1;
    }

    let mut holes = Vec::new();
    for (idx, line) in lines.iter().enumerate() {
        if line.contains("todo!()") || line.contains("todo!(") {
            let function = fn_starts
                .iter()
                .rev()
                .find(|(fn_idx, _)| *fn_idx <= idx)
                .map(|(_, name)| name.clone());

            let nearest_test = function.as_ref().and_then(|f| {
                test_fns
                    .iter()
                    .find(|(test_name, body)| {
                        test_name == &format!("test_{f}")
                            || test_name == &format!("{f}_test")
                            || body.contains(&format!("{f}("))
                    })
                    .map(|(test_name, _)| test_name.clone())
            });

            holes.push((idx + 1, function, nearest_test));
        }
    }
    holes
}

fn extract_fn_name(line: &str) -> Option<String> {
    let trimmed = line.trim_start();
    let after_fn = trimmed
        .strip_prefix("pub fn ")
        .or_else(|| trimmed.strip_prefix("pub(crate) fn "))
        .or_else(|| trimmed.strip_prefix("async fn "))
        .or_else(|| trimmed.strip_prefix("pub async fn "))
        .or_else(|| trimmed.strip_prefix("fn "))?;
    let name: String = after_fn
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}

/// Walk `root` recursively for `.rs` files (skipping `target/` and
/// hidden dirs) and collect every `todo!()` hole found.
pub fn find_todo_holes_in_dir(root: &Path) -> std::io::Result<Vec<TodoHole>> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if name == "target" || name.starts_with('.') {
                    continue;
                }
                stack.push(path);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                let src = std::fs::read_to_string(&path)?;
                let rel = path.strip_prefix(root).unwrap_or(&path).to_path_buf();
                for (line, function, nearest_test) in find_todo_holes_in_source(&src) {
                    out.push(TodoHole {
                        file: rel.clone(),
                        line,
                        function,
                        nearest_test,
                    });
                }
            }
        }
    }
    out.sort_by(|a, b| a.file.cmp(&b.file).then(a.line.cmp(&b.line)));
    Ok(out)
}

/// Deterministically render one `TodoHole` into a leaf-gap title +
/// acceptance-criteria pair, ready to hand to `chump gap reserve`.
/// One hole -> one tiny, disjoint, mechanically-verifiable gap.
pub fn hole_to_gap_spec(hole: &TodoHole, parent_gap: &str) -> (String, String) {
    let fn_label = hole.function.as_deref().unwrap_or("<unknown fn>");
    let title = format!(
        "fill-hole: implement {} at {}:{}",
        fn_label,
        hole.file.display(),
        hole.line
    );
    let ac = match &hole.nearest_test {
        Some(test) => format!(
            "Replace the todo!() at {}:{} (fn {}) with a real implementation. \
             Test `{}` must pass. Parent scaffold: {}.",
            hole.file.display(),
            hole.line,
            fn_label,
            test,
            parent_gap
        ),
        None => format!(
            "Replace the todo!() at {}:{} (fn {}) with a real implementation. \
             Parent scaffold: {}.",
            hole.file.display(),
            hole.line,
            fn_label,
            parent_gap
        ),
    };
    (title, ac)
}

/// One completed gap's inputs to the scaffold-vs-open-ended comparison:
/// how long it took to ship (proxy for CI/round-trip cost) and which
/// files its shipping PR touched (input to collision-rate).
#[derive(Debug, Clone)]
pub struct GapMetric {
    pub id: String,
    /// Wall-clock seconds from `created_at` to `closed_at`. `None` if the
    /// gap isn't closed yet or timestamps are missing.
    pub cycle_time_secs: Option<i64>,
    /// Files touched by the gap's shipping PR (from `git show --stat`, or
    /// empty if unknown).
    pub files_touched: Vec<String>,
}

/// Fraction of `gaps` that share at least one touched file with another
/// gap in the same slice — a mechanical proxy for "these two agents would
/// have collided if worked concurrently". 0.0 for fewer than 2 gaps.
pub fn collision_rate(gaps: &[GapMetric]) -> f64 {
    if gaps.len() < 2 {
        return 0.0;
    }
    let collided = gaps
        .iter()
        .filter(|g| {
            gaps.iter().any(|other| {
                other.id != g.id
                    && g.files_touched
                        .iter()
                        .any(|f| other.files_touched.contains(f))
            })
        })
        .count();
    collided as f64 / gaps.len() as f64
}

/// Mean cycle time in seconds across `gaps`, ignoring gaps with no
/// recorded cycle time. `None` if none have one.
pub fn mean_cycle_secs(gaps: &[GapMetric]) -> Option<f64> {
    let vals: Vec<f64> = gaps
        .iter()
        .filter_map(|g| g.cycle_time_secs)
        .map(|s| s as f64)
        .collect();
    if vals.is_empty() {
        None
    } else {
        Some(vals.iter().sum::<f64>() / vals.len() as f64)
    }
}

/// Head-to-head comparison of scaffold-and-holes leaf gaps against
/// open-ended gaps: mean ship cycle-time and collision rate for each
/// group. This is the mechanical measurement the EFFECTIVE-440 hypothesis
/// ("tiny disjoint leaf gaps ship faster with fewer collisions than
/// open-ended gaps") lives or dies by.
#[derive(Debug, Clone, PartialEq)]
pub struct ScaffoldMetricsReport {
    pub scaffold_leaf_count: usize,
    pub open_ended_count: usize,
    pub scaffold_leaf_mean_cycle_secs: Option<f64>,
    pub open_ended_mean_cycle_secs: Option<f64>,
    pub scaffold_leaf_collision_rate: f64,
    pub open_ended_collision_rate: f64,
}

pub fn compare_scaffold_vs_open_ended(
    scaffold_leaves: &[GapMetric],
    open_ended: &[GapMetric],
) -> ScaffoldMetricsReport {
    ScaffoldMetricsReport {
        scaffold_leaf_count: scaffold_leaves.len(),
        open_ended_count: open_ended.len(),
        scaffold_leaf_mean_cycle_secs: mean_cycle_secs(scaffold_leaves),
        open_ended_mean_cycle_secs: mean_cycle_secs(open_ended),
        scaffold_leaf_collision_rate: collision_rate(scaffold_leaves),
        open_ended_collision_rate: collision_rate(open_ended),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_single_hole_with_enclosing_fn_and_matching_test() {
        let src = r#"
pub fn add(a: i32, b: i32) -> i32 {
    todo!()
}

#[test]
fn test_add() {
    assert_eq!(add(1, 1), 2);
}
"#;
        let holes = find_todo_holes_in_source(src);
        assert_eq!(holes.len(), 1);
        let (line, function, nearest_test) = &holes[0];
        assert_eq!(*line, 3);
        assert_eq!(function.as_deref(), Some("add"));
        assert_eq!(nearest_test.as_deref(), Some("test_add"));
    }

    #[test]
    fn finds_multiple_disjoint_holes_independently() {
        let src = r#"
fn foo() {
    todo!()
}

fn bar() {
    todo!()
}
"#;
        let holes = find_todo_holes_in_source(src);
        assert_eq!(holes.len(), 2);
        assert_eq!(holes[0].1.as_deref(), Some("foo"));
        assert_eq!(holes[1].1.as_deref(), Some("bar"));
    }

    #[test]
    fn no_holes_in_fully_implemented_source() {
        let src = r#"
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"#;
        let holes = find_todo_holes_in_source(src);
        assert!(holes.is_empty());
    }

    #[test]
    fn gap_spec_cites_exact_hole_location_and_test() {
        let hole = TodoHole {
            file: PathBuf::from("src/lib.rs"),
            line: 42,
            function: Some("compute".to_string()),
            nearest_test: Some("test_compute".to_string()),
        };
        let (title, ac) = hole_to_gap_spec(&hole, "EFFECTIVE-440");
        assert!(title.contains("compute"));
        assert!(title.contains("src/lib.rs:42"));
        assert!(ac.contains("test_compute"));
        assert!(ac.contains("EFFECTIVE-440"));
    }

    #[test]
    fn scan_dir_finds_holes_across_files_and_skips_target() {
        let tmp = std::env::temp_dir().join(format!("scaffold_holes_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("target")).unwrap();
        std::fs::create_dir_all(tmp.join("src")).unwrap();
        std::fs::write(tmp.join("src/a.rs"), "fn a() {\n    todo!()\n}\n").unwrap();
        std::fs::write(
            tmp.join("target/generated.rs"),
            "fn ignored() {\n    todo!()\n}\n",
        )
        .unwrap();

        let holes = find_todo_holes_in_dir(&tmp).unwrap();
        assert_eq!(holes.len(), 1);
        assert_eq!(holes[0].function.as_deref(), Some("a"));

        std::fs::remove_dir_all(&tmp).unwrap();
    }

    fn metric(id: &str, cycle_secs: Option<i64>, files: &[&str]) -> GapMetric {
        GapMetric {
            id: id.to_string(),
            cycle_time_secs: cycle_secs,
            files_touched: files.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn collision_rate_is_zero_when_no_files_overlap() {
        let gaps = vec![
            metric("A", Some(60), &["src/a.rs"]),
            metric("B", Some(60), &["src/b.rs"]),
        ];
        assert_eq!(collision_rate(&gaps), 0.0);
    }

    #[test]
    fn collision_rate_counts_gaps_sharing_a_touched_file() {
        let gaps = vec![
            metric("A", Some(60), &["src/shared.rs"]),
            metric("B", Some(60), &["src/shared.rs"]),
            metric("C", Some(60), &["src/other.rs"]),
        ];
        // A and B collide (2/3); C is disjoint.
        assert!((collision_rate(&gaps) - (2.0 / 3.0)).abs() < 1e-9);
    }

    #[test]
    fn collision_rate_is_zero_for_fewer_than_two_gaps() {
        assert_eq!(collision_rate(&[]), 0.0);
        assert_eq!(collision_rate(&[metric("A", Some(60), &["src/a.rs"])]), 0.0);
    }

    #[test]
    fn mean_cycle_secs_averages_only_known_values() {
        let gaps = vec![
            metric("A", Some(100), &[]),
            metric("B", None, &[]),
            metric("C", Some(300), &[]),
        ];
        assert_eq!(mean_cycle_secs(&gaps), Some(200.0));
    }

    #[test]
    fn mean_cycle_secs_is_none_when_nothing_is_known() {
        let gaps = vec![metric("A", None, &[])];
        assert_eq!(mean_cycle_secs(&gaps), None);
    }

    #[test]
    fn scaffold_leaves_beat_open_ended_gaps_on_both_axes() {
        // The EFFECTIVE-440 hypothesis: tiny disjoint leaf gaps (one
        // todo!() + its test each) ship faster and collide less often
        // than open-ended gaps that roam across many files.
        let scaffold_leaves = vec![
            metric("EFFECTIVE-441", Some(600), &["src/foo.rs"]),
            metric("EFFECTIVE-442", Some(700), &["src/bar.rs"]),
        ];
        let open_ended = vec![
            metric("EFFECTIVE-100", Some(5000), &["src/foo.rs", "src/bar.rs"]),
            metric("EFFECTIVE-101", Some(6000), &["src/bar.rs", "src/baz.rs"]),
        ];

        let report = compare_scaffold_vs_open_ended(&scaffold_leaves, &open_ended);

        assert_eq!(report.scaffold_leaf_count, 2);
        assert_eq!(report.open_ended_count, 2);
        assert_eq!(report.scaffold_leaf_mean_cycle_secs, Some(650.0));
        assert_eq!(report.open_ended_mean_cycle_secs, Some(5500.0));
        assert_eq!(report.scaffold_leaf_collision_rate, 0.0);
        assert_eq!(report.open_ended_collision_rate, 1.0);
        assert!(report.scaffold_leaf_mean_cycle_secs < report.open_ended_mean_cycle_secs);
        assert!(report.scaffold_leaf_collision_rate < report.open_ended_collision_rate);
    }
}
