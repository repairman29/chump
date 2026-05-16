//! INFRA-1439: Source-level plumbing audit for `chump claim --force-recover`.
//!
//! Verifies that the force-recover path is wired correctly:
//!   - ClaimArgs struct has `force_recover` field
//!   - `--force-recover` flag is parsed in `from_argv`
//!   - Help text documents the flag
//!   - `emit_force_recover_event` emitter is present in atomic_claim.rs
//!   - `chump_claim_force_recover` is registered in EVENT_REGISTRY.yaml
//!
//! Runtime integration smoke tests live in scripts/ci/test-claim-force-recover.sh.

use std::path::PathBuf;

fn atomic_claim_rs() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("src/atomic_claim.rs"))
        .unwrap_or_else(|e| panic!("cannot read src/atomic_claim.rs: {e}"))
}

fn event_registry_yaml() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    std::fs::read_to_string(PathBuf::from(manifest).join("docs/observability/EVENT_REGISTRY.yaml"))
        .unwrap_or_else(|e| panic!("cannot read docs/observability/EVENT_REGISTRY.yaml: {e}"))
}

// ── 1. ClaimArgs struct has force_recover field ────────────────────────────

#[test]
fn claim_args_has_force_recover_field() {
    let src = atomic_claim_rs();
    assert!(
        src.contains("force_recover: bool"),
        "ClaimArgs.force_recover not declared in atomic_claim.rs"
    );
}

// ── 2. --force-recover flag is parsed ─────────────────────────────────────

#[test]
fn force_recover_flag_parsed() {
    let src = atomic_claim_rs();
    assert!(
        src.contains("\"--force-recover\""),
        "--force-recover not parsed in from_argv in atomic_claim.rs"
    );
}

// ── 3. Help text documents --force-recover ─────────────────────────────────

#[test]
fn force_recover_in_help_text() {
    let src = atomic_claim_rs();
    assert!(
        src.contains("--force-recover"),
        "--force-recover not in help string in atomic_claim.rs"
    );
}

// ── 4. emit_force_recover_event is present ─────────────────────────────────

#[test]
fn emit_force_recover_event_defined() {
    let src = atomic_claim_rs();
    assert!(
        src.contains("fn emit_force_recover_event"),
        "emit_force_recover_event not defined in atomic_claim.rs"
    );
}

// ── 5. chump_claim_force_recover in EVENT_REGISTRY.yaml ───────────────────

#[test]
fn force_recover_event_registered() {
    let yaml = event_registry_yaml();
    assert!(
        yaml.contains("chump_claim_force_recover"),
        "chump_claim_force_recover not registered in docs/observability/EVENT_REGISTRY.yaml"
    );
}

// ── 6. force_recover propagated into ClaimArgs at call site ───────────────

#[test]
fn force_recover_propagated_in_struct_init() {
    let src = atomic_claim_rs();
    // The Ok(Self { ... force_recover, ... }) pattern in from_argv
    assert!(
        src.contains("force_recover,"),
        "force_recover not propagated in ClaimArgs struct init in from_argv"
    );
}
