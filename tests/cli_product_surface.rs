//! CREDIBLE-036: Source-level plumbing audit for product-surface CLI commands.
//!
//! Verifies that chump gen, mcp list/install, session-track, waste-tally, and
//! lesson-grade are wired correctly in src/main.rs and the relevant modules.
//! Following the CREDIBLE-035 pattern — no binary build required.
//!
//! Runtime shell smoke tests live in scripts/ci/test-cli-product-surface.sh.

use std::path::PathBuf;

fn main_rs() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("src/main.rs"))
        .unwrap_or_else(|e| panic!("cannot read src/main.rs: {e}"))
}

fn read_src(name: &str) -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("src").join(name))
        .unwrap_or_else(|e| panic!("cannot read src/{name}: {e}"))
}

// ── 1. Module declarations ─────────────────────────────────────────────────

#[test]
fn product_modules_declared_in_main_rs() {
    let src = main_rs();
    for module in &["gen", "mcp_discovery", "waste_tally"] {
        assert!(
            src.contains(&format!("mod {};", module)),
            "mod {module}; not declared in main.rs"
        );
    }
}

// ── 2. `chump gen` subcommand ─────────────────────────────────────────────

#[test]
fn gen_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("gen")"#),
        "gen subcommand not dispatched in main.rs"
    );
}

#[test]
fn gen_module_exports_run_fn() {
    let src = read_src("gen.rs");
    assert!(
        src.contains("pub fn run") || src.contains("pub async fn run"),
        "gen.rs does not export a run fn"
    );
}

#[test]
fn gen_local_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("\"--local\"") || src.contains("--local"),
        "--local flag not handled for chump gen in main.rs"
    );
}

// ── 3. `chump mcp` subcommand ─────────────────────────────────────────────

#[test]
fn mcp_list_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"s == "mcp""#) && src.contains(r#"s == "list""#),
        "mcp list subcommand not dispatched in main.rs"
    );
}

#[test]
fn mcp_install_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"s == "mcp""#) && src.contains(r#"s == "install""#),
        "mcp install subcommand not dispatched in main.rs"
    );
}

#[test]
fn mcp_list_installed_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("\"--installed\"") || src.contains("--installed"),
        "--installed flag not handled for chump mcp list in main.rs"
    );
}

#[test]
fn mcp_list_json_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("\"--json\""),
        "--json flag not handled for chump mcp list in main.rs"
    );
}

#[test]
fn mcp_discovery_exports_discover_fn() {
    let src = read_src("mcp_discovery.rs");
    assert!(
        src.contains("pub fn discover_mcp_servers"),
        "mcp_discovery.rs does not export discover_mcp_servers"
    );
}

// ── 4. `chump waste-tally` subcommand ────────────────────────────────────

#[test]
fn waste_tally_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("waste-tally")"#),
        "waste-tally subcommand not dispatched in main.rs"
    );
}

#[test]
fn waste_tally_window_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("\"--window\"") || src.contains("--window"),
        "--window flag not handled for chump waste-tally in main.rs"
    );
}

#[test]
fn waste_tally_module_exports_build_report() {
    let src = read_src("waste_tally.rs");
    assert!(
        src.contains("pub fn build_report"),
        "waste_tally.rs does not export build_report"
    );
}

// ── 5. `chump lesson-grade` subcommand ───────────────────────────────────

#[test]
fn lesson_grade_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("lesson-grade")"#),
        "lesson-grade subcommand not dispatched in main.rs"
    );
}

#[test]
fn lesson_grade_pr_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("\"--pr\""),
        "--pr flag not handled for chump lesson-grade in main.rs"
    );
}

#[test]
fn lesson_grade_gap_arg_required() {
    let src = main_rs();
    // lesson-grade requires a GAP-ID positional arg
    assert!(
        src.contains("lesson-grade <GAP-ID>"),
        "lesson-grade does not require GAP-ID positional arg per usage message"
    );
}

// ── 6. `chump session-track` subcommand ──────────────────────────────────

#[test]
fn session_track_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("session-track")"#),
        "session-track subcommand not dispatched in main.rs"
    );
}
