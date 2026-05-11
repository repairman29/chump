//! CREDIBLE-015: CLI help system consistency — source-level audit.
//!
//! Tests verify that `src/main.rs` has "Usage: chump <cmd>" strings for every
//! listed top-level command. Source-level tests — no binary build required.
//! Runtime verification is in `scripts/ci/test-cli-help.sh`.

use std::path::PathBuf;

fn main_rs() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let path = PathBuf::from(manifest).join("src/main.rs");
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read src/main.rs: {e}"))
}

const CMDS_WITH_USAGE: &[&str] = &[
    "claim",
    "lesson-grade",
    "fleet",
    "dispatch",
    "reflect-delta",
    "gap",
    "session-resume",
    "pr-coupling-cost",
    "health",
    "funnel",
    "mission-grade",
    "roadmap-status",
    "fleet-status",
    "fleet-velocity",
    "waste-tally",
    "health-digest",
    "ship-quality",
    "ci-summary",
    "session-export",
    "dashboard",
    "cost-watch",
];

const CMDS_IN_HELP: &[&str] = &[
    "gap",
    "claim",
    "fleet",
    "dispatch",
    "orchestrate",
    "health",
    "health-digest",
    "fleet-status",
    "fleet-velocity",
    "waste-tally",
    "ship-quality",
    "roadmap-status",
    "mission-grade",
    "lesson-grade",
    "ci-summary",
    "classify-failure",
    "cost-watch",
    "dashboard",
    "session-track",
    "session-export",
    "session-resume",
    "reflect-delta",
    "rebase-stuck",
    "funnel",
];

#[test]
fn credible015_all_commands_have_usage_string() {
    let src = main_rs();
    let missing: Vec<&str> = CMDS_WITH_USAGE
        .iter()
        .filter(|cmd| !src.contains(&format!("Usage: chump {cmd}")))
        .copied()
        .collect();
    assert!(
        missing.is_empty(),
        "Commands missing 'Usage: chump <cmd>' in src/main.rs: {missing:?}\n\
         Add --help handling per CONTRIBUTING.md §CLI help text standard."
    );
}

#[test]
fn credible015_print_help_covers_all_advertised_commands() {
    let src = main_rs();
    let missing: Vec<&str> = CMDS_IN_HELP
        .iter()
        .filter(|cmd| !src.contains(*cmd))
        .copied()
        .collect();
    assert!(
        missing.is_empty(),
        "Commands not found in src/main.rs at all: {missing:?}"
    );
}

#[test]
fn credible015_usage_lines_have_command_name_after_chump() {
    let src = main_rs();
    let malformed: Vec<String> = src
        .lines()
        .filter(|l| l.contains("Usage: chump"))
        .filter(|l| {
            // After "Usage: chump " the next char must be a letter or '-'.
            let after = l
                .find("Usage: chump ")
                .map(|i| l[i + "Usage: chump ".len()..].chars().next());
            !matches!(after, Some(Some(c)) if c.is_ascii_alphabetic() || c == '-')
        })
        .map(|l| l.trim().to_string())
        .collect();
    assert!(
        malformed.is_empty(),
        "Malformed Usage lines in src/main.rs:\n{}",
        malformed.join("\n")
    );
}

#[test]
fn credible015_help_handlers_use_println_not_eprintln() {
    // Heuristic: --help check blocks within 10 lines should not use eprintln! for Usage.
    // Error paths legitimately use eprintln — this guards our new --help blocks only.
    let src = main_rs();
    let lines: Vec<&str> = src.lines().collect();
    let mut violations: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if line.contains("--help") && line.contains("||") && line.contains("help") {
            let end = std::cmp::min(i + 10, lines.len());
            for (j, inner) in lines[i..end].iter().enumerate() {
                if inner.contains("eprintln!") && inner.contains("Usage: chump") {
                    violations.push(format!("line {}: {}", i + j + 1, inner.trim()));
                }
            }
        }
    }
    assert!(
        violations.is_empty(),
        "Help blocks using eprintln! for Usage (should be println!):\n{}",
        violations.join("\n")
    );
}
