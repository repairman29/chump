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
}
