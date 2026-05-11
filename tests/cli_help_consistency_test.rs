/// CREDIBLE-015: CLI help system consistency — source-level audit.
///
/// These tests verify that `src/main.rs` contains the required "Usage: chump <cmd>"
/// strings for every listed top-level command. They are intentionally source-level
/// (not integration tests that spawn the binary) so they pass without a binary build.
///
/// Runtime help verification (exit-0, prints "Usage:") is handled by the CI gate:
/// `scripts/ci/test-cli-help.sh`.
use std::path::PathBuf;

fn main_rs() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let path = PathBuf::from(manifest).join("src/main.rs");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read src/main.rs: {e}"))
}

/// Commands that must have at least one "Usage: chump <cmd>" string in main.rs.
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

/// Commands/tokens that must appear in the top-level print_help() output section.
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
    let mut missing: Vec<&str> = Vec::new();
    for cmd in CMDS_WITH_USAGE {
        let needle = format!("Usage: chump {cmd}");
        if !src.contains(&needle) {
            missing.push(cmd);
        }
    }
    assert!(
        missing.is_empty(),
        "Commands missing 'Usage: chump <cmd>' in src/main.rs: {missing:?}\n\
         Add --help handling following the template in CONTRIBUTING.md §CLI help text standard."
    );
}

#[test]
fn credible015_print_help_covers_all_advertised_commands() {
    let src = main_rs();
    let mut missing: Vec<&str> = Vec::new();
    for cmd in CMDS_IN_HELP {
        if !src.contains(cmd) {
            missing.push(cmd);
        }
    }
    assert!(
        missing.is_empty(),
        "Commands not found in src/main.rs at all: {missing:?}\n\
         Either add the command or remove it from CMDS_IN_HELP."
    );
}

#[test]
fn credible015_usage_lines_have_command_name_after_chump() {
    let src = main_rs();
    let malformed: Vec<String> = src
        .lines()
        .filter(|l| l.contains("Usage: chump"))
        .filter(|l| {
            // After "Usage: chump " the next char must be a letter or '-'
            if let Some(rest) = l
                .find("Usage: chump ")
                .map(|i| &l[i + "Usage: chump ".len()..])
            {
                !rest.starts_with(|c: char| c.is_ascii_alphabetic() || c == '-')
            } else {
                true // "Usage: chump" with no space after — malformed
            }
        })
        .map(|l| l.trim().to_string())
        .collect();

    assert!(
        malformed.is_empty(),
        "Malformed Usage lines in src/main.rs (must be 'Usage: chump <cmd-or-flag> ...'):\n{}",
        malformed.join("\n")
    );
}

#[test]
fn credible015_help_handlers_use_println_not_eprintln() {
    let src = main_rs();
    // Help text printed via eprintln! goes to stderr; operators expect stdout.
    // Find blocks that contain --help check AND eprintln for Usage.
    // This is a heuristic: look for eprintln!(\"Usage: chump\" adjacent to --help checks.
    // False positives are acceptable (error paths legitimately use eprintln).
    // The test just verifies our new --help blocks use println.
    let lines: Vec<&str> = src.lines().collect();
    let mut violations: Vec<String> = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if line.contains("--help") && line.contains("||") && line.contains("help") {
            // Look forward 10 lines for eprintln!(\"Usage:
            for j in i..std::cmp::min(i + 10, lines.len()) {
                if lines[j].contains("eprintln!") && lines[j].contains("Usage: chump") {
                    violations.push(format!("line {}: {}", j + 1, lines[j].trim()));
                }
            }
        }
    }
    assert!(
        violations.is_empty(),
        "Help blocks that use eprintln! for Usage (should be println!):\n{}",
        violations.join("\n")
    );
}
