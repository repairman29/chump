//! CREDIBLE-035: Source-level plumbing audit for fleet + health + coord CLI commands.
//!
//! Verifies that the required modules, structs, and subcommand dispatch are wired
//! correctly in src/main.rs and the relevant modules.  These tests run at
//! `cargo test --tests` time (no binary build required).
//!
//! Runtime binary smoke tests live in scripts/ci/test-cli-fleet-coord.sh.

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
fn modules_declared_in_main_rs() {
    let src = main_rs();
    for module in &["fleet_health", "briefing", "doctor", "auth"] {
        assert!(
            src.contains(&format!("mod {};", module)),
            "mod {module}; not declared in main.rs"
        );
    }
}

// ── 2. `chump health` subcommand ──────────────────────────────────────────

#[test]
fn health_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("health")"#),
        "health subcommand not dispatched in main.rs"
    );
}

#[test]
fn health_slo_check_flag_handled() {
    let src = main_rs();
    assert!(
        src.contains("--slo-check"),
        "--slo-check flag not handled in main.rs"
    );
}

#[test]
fn fleet_health_exports_check_slos() {
    let src = read_src("fleet_health.rs");
    assert!(
        src.contains("pub fn check_slos"),
        "fleet_health::check_slos not exported"
    );
}

#[test]
fn fleet_health_exports_render_slo_json() {
    let src = read_src("fleet_health.rs");
    assert!(
        src.contains("pub fn render_slo_json"),
        "fleet_health::render_slo_json not exported"
    );
}

#[test]
fn slo_result_has_id_and_breached_fields() {
    let src = read_src("fleet_health.rs");
    assert!(
        src.contains("pub struct SloResult"),
        "SloResult struct missing"
    );
    assert!(
        src.contains("pub id:") && src.contains("pub breached:"),
        "SloResult missing id or breached fields"
    );
}

// ── 3. `chump --doctor` (fleet doctor) ────────────────────────────────────

#[test]
fn doctor_flag_dispatched_in_main_rs() {
    let src = main_rs();
    assert!(
        src.contains(r#""--doctor""#),
        "--doctor flag not dispatched in main.rs"
    );
}

#[test]
fn doctor_run_all_checks_exported() {
    let src = read_src("doctor.rs");
    assert!(
        src.contains("pub async fn run_all_checks"),
        "doctor::run_all_checks not exported"
    );
}

#[test]
fn doctor_print_human_report_returns_exit_code() {
    let src = read_src("doctor.rs");
    // Confirm the function signature returns i32
    assert!(
        src.contains("pub fn print_human_report(report: &DoctorReport) -> i32"),
        "doctor::print_human_report does not return i32 exit code"
    );
}

// ── 4. `chump fleet status` ───────────────────────────────────────────────

#[test]
fn fleet_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("fleet")"#),
        "fleet subcommand not dispatched in main.rs"
    );
}

#[test]
fn fleet_status_subcmd_wired() {
    let src = main_rs();
    // `chump fleet status` is handled as a `match subcmd { "status" => ... }` arm.
    assert!(
        src.contains(r#""status""#),
        "fleet status sub-command not in fleet match block"
    );
}

// ── 5. `chump claim` / `chump release` ────────────────────────────────────

#[test]
fn claim_subcommand_wired() {
    let src = main_rs();
    assert!(
        src.contains(r#"Some("claim")"#),
        "claim subcommand not dispatched in main.rs"
    );
}

#[test]
fn release_subcommand_wired() {
    // `chump release` or `chump --release` — accept either form.
    let src = main_rs();
    let has_release = src.contains(r#"Some("release")"#) || src.contains(r#""--release""#);
    assert!(has_release, "release/--release not dispatched in main.rs");
}

// ── 6. `chump --briefing <ID>` ────────────────────────────────────────────

#[test]
fn briefing_flag_dispatched_in_main_rs() {
    let src = main_rs();
    assert!(
        src.contains(r#""--briefing""#),
        "--briefing flag not dispatched in main.rs"
    );
}

#[test]
fn briefing_build_briefing_exported() {
    let src = read_src("briefing.rs");
    assert!(
        src.contains("pub fn build_briefing"),
        "briefing::build_briefing not exported"
    );
}

#[test]
fn briefing_render_markdown_exported() {
    let src = read_src("briefing.rs");
    assert!(
        src.contains("pub fn render_markdown"),
        "briefing::render_markdown not exported"
    );
}

// ── 7. Auth module (INFRA-622 dual-mode) ─────────────────────────────────

#[test]
fn auth_module_exports_auth_mode_enum() {
    let src = read_src("auth.rs");
    assert!(
        src.contains("pub enum AuthMode"),
        "AuthMode enum not exported"
    );
    assert!(
        src.contains("ApiKey") && src.contains("OAuth") && src.contains("Auto"),
        "AuthMode variants ApiKey/OAuth/Auto missing"
    );
}

#[test]
fn auth_module_exports_auth_credentials() {
    let src = read_src("auth.rs");
    assert!(
        src.contains("pub struct AuthCredentials"),
        "AuthCredentials struct not exported"
    );
}

#[test]
fn auth_module_reads_chump_auth_mode_env() {
    let src = read_src("auth.rs");
    assert!(
        src.contains("CHUMP_AUTH_MODE"),
        "auth.rs does not read CHUMP_AUTH_MODE env var"
    );
}

// ── 8. `chump health --slo-check` SLO registry coverage ──────────────────

#[test]
fn slo_registry_covers_required_ids() {
    let src = read_src("fleet_health.rs");
    for id in &[
        "L1-SLO-1", "L1-SLO-2", "L1-SLO-3", "L2-SLO-1", "L2-SLO-2", "L2-SLO-3",
    ] {
        assert!(
            src.contains(id),
            "SLO ID {id} not found in fleet_health.rs check_slos()"
        );
    }
}

// ── 9. CI script exists ───────────────────────────────────────────────────

#[test]
fn ci_script_exists_and_executable() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let script = PathBuf::from(manifest).join("scripts/ci/test-cli-fleet-coord.sh");
    assert!(
        script.exists(),
        "scripts/ci/test-cli-fleet-coord.sh not found"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::metadata(&script).unwrap().permissions();
        assert!(
            perms.mode() & 0o111 != 0,
            "scripts/ci/test-cli-fleet-coord.sh is not executable"
        );
    }
}
