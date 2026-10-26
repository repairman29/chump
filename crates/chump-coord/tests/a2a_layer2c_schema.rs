// crates/chump-coord/tests/a2a_layer2c_schema.rs — INFRA-1760
//
// Integration test for the CapabilityManifest schema (foundation slice 1/4
// of META-061 Layer 2c). Validates the wire-format contract:
//   - schema_version constant is the documented chump-capability-v1
//   - serde round-trip preserves all fields losslessly
//   - hardware fields stay None without CHUMP_PUBLISH_HARDWARE=1 opt-in
//   - is_alive() correctly bounds against the TTL window

use chrono::{Duration, Utc};
use chump_coord::capability::{
    current_manifest, CapabilityManifest, CAPABILITY_SCHEMA_VERSION, DEFAULT_TTL_SECONDS,
};

#[test]
fn schema_version_pinned_at_v2() {
    // INFRA-1805 bumped CAPABILITY_SCHEMA_VERSION to chump-capability-v2 while
    // keeping v1 forward-compatible via #[serde(default)].
    assert_eq!(CAPABILITY_SCHEMA_VERSION, "chump-capability-v2");
}

#[test]
fn json_round_trip_full_fields() {
    let now = Utc::now();
    let m = CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: "curator-opus-ci-audit-2026-05-23".to_string(),
        harness: "claude".to_string(),
        model_tier: "opus".to_string(),
        skills: vec![
            "rust".to_string(),
            "ci-mirror".to_string(),
            "decomposition".to_string(),
        ],
        machine: Some("macbook-test".to_string()),
        gpu: Some("M4-pro-test".to_string()),
        ip: Some("10.0.0.1".to_string()),
        started_at: now,
        heartbeat_at: now,
        ttl_seconds: DEFAULT_TTL_SECONDS,
        external_repo_enabled: false,
        token_budget_remaining: Some(120_000),
        compute_available_pct: Some(75),
        bandwidth_kbps: Some(50_000),
        healthy: true,
    };

    let json = serde_json::to_string(&m).expect("serialize");
    // Sanity-check key fields are present in the wire form.
    assert!(json.contains("\"schema_version\":\"chump-capability-v2\""));
    assert!(json.contains("\"session_id\":\"curator-opus-ci-audit-2026-05-23\""));
    assert!(json.contains("\"harness\":\"claude\""));
    assert!(json.contains("\"ttl_seconds\":300"));

    let back: CapabilityManifest = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(m, back, "round-trip should be lossless");
}

#[test]
fn json_round_trip_minimal_fields() {
    // The minimal valid manifest: no machine, no gpu, no ip, empty skills.
    let now = Utc::now();
    let m = CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: "anon".to_string(),
        harness: "manual".to_string(),
        model_tier: "unknown".to_string(),
        skills: vec![],
        machine: None,
        gpu: None,
        ip: None,
        started_at: now,
        heartbeat_at: now,
        ttl_seconds: 60,
        external_repo_enabled: false,
        token_budget_remaining: None,
        compute_available_pct: None,
        bandwidth_kbps: None,
        healthy: true,
    };
    let json = serde_json::to_string(&m).expect("serialize");
    let back: CapabilityManifest = serde_json::from_str(&json).expect("deserialize");
    assert_eq!(m, back);
    assert!(!back.has_hardware_fields());
}

#[test]
fn hardware_fields_gated_by_env() {
    // serde_test would be nicer but we don't have it; use a process-wide
    // env mutation guarded by serial test isolation via the env-var name
    // we own.
    let original = std::env::var("CHUMP_PUBLISH_HARDWARE").ok();
    let _gpu_orig = std::env::var("CHUMP_GPU_LABEL").ok();
    let _ip_orig = std::env::var("CHUMP_IP_LABEL").ok();

    // Default off
    std::env::remove_var("CHUMP_PUBLISH_HARDWARE");
    std::env::set_var("CHUMP_GPU_LABEL", "fake-gpu");
    std::env::set_var("CHUMP_IP_LABEL", "10.0.0.99");
    let m = current_manifest(vec!["test".to_string()]);
    assert_eq!(
        m.gpu, None,
        "gpu must be absent without CHUMP_PUBLISH_HARDWARE=1"
    );
    assert_eq!(
        m.ip, None,
        "ip must be absent without CHUMP_PUBLISH_HARDWARE=1"
    );

    // Opt-in
    std::env::set_var("CHUMP_PUBLISH_HARDWARE", "1");
    let m2 = current_manifest(vec!["test".to_string()]);
    assert_eq!(m2.gpu.as_deref(), Some("fake-gpu"));
    assert_eq!(m2.ip.as_deref(), Some("10.0.0.99"));

    // Cleanup
    match original {
        Some(v) => std::env::set_var("CHUMP_PUBLISH_HARDWARE", v),
        None => std::env::remove_var("CHUMP_PUBLISH_HARDWARE"),
    }
    std::env::remove_var("CHUMP_GPU_LABEL");
    std::env::remove_var("CHUMP_IP_LABEL");
}

#[test]
fn is_alive_respects_ttl() {
    let t0 = Utc::now();
    let m = CapabilityManifest {
        schema_version: CAPABILITY_SCHEMA_VERSION.to_string(),
        session_id: "ttl-test".to_string(),
        harness: "manual".to_string(),
        model_tier: "unknown".to_string(),
        skills: vec![],
        machine: None,
        gpu: None,
        ip: None,
        started_at: t0,
        heartbeat_at: t0,
        ttl_seconds: 300,
        external_repo_enabled: false,
        token_budget_remaining: None,
        compute_available_pct: None,
        bandwidth_kbps: None,
        healthy: true,
    };
    assert!(m.is_alive(t0));
    assert!(m.is_alive(t0 + Duration::seconds(299)));
    assert!(m.is_alive(t0 + Duration::seconds(300)));
    assert!(!m.is_alive(t0 + Duration::seconds(301)));
    assert!(!m.is_alive(t0 + Duration::hours(1)));
}

#[test]
fn v1_to_v2_forward_compatibility() {
    // INFRA-1805: a v1 JSON payload without v2 fields must deserialize cleanly
    // with None for optional resource fields and healthy=true.
    let v1_json = r#"{
        "schema_version": "chump-capability-v1",
        "session_id": "legacy-v1-worker",
        "harness": "claude",
        "model_tier": "sonnet",
        "skills": ["rust", "shell"],
        "machine": "macbook",
        "gpu": null,
        "ip": null,
        "started_at": "2026-05-23T05:00:00Z",
        "heartbeat_at": "2026-05-23T05:30:00Z",
        "ttl_seconds": 300
    }"#;
    let parsed: CapabilityManifest =
        serde_json::from_str(v1_json).expect("v1 payload must deserialize into v2 struct");
    assert_eq!(parsed.schema_version, "chump-capability-v1");
    assert_eq!(parsed.session_id, "legacy-v1-worker");
    assert_eq!(parsed.token_budget_remaining, None);
    assert_eq!(parsed.compute_available_pct, None);
    assert_eq!(parsed.bandwidth_kbps, None);
    assert!(parsed.healthy, "v1 payload must default healthy to true");
}
