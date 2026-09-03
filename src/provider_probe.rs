//! CREDIBLE-227: verify hand-entered provider slot limits against reality.
//!
//! `.env` provider slots declare RPM/RPD by hand (copy-pasted from provider
//! docs, sometimes stale or just wrong — see CREDIBLE-227 AC #1: two slots
//! declaring the *same* model 57x apart on RPD). This module probes each
//! enabled cloud slot with a cheap `GET {base}/models` call, reads whatever
//! rate-limit headers the provider returns, and compares them against the
//! configured ceiling. Drift is reported (ambient event -> gap), never
//! auto-written back to `.env` — a bad probe must not quietly rewrite the
//! fleet's inference config (AC #3).

use crate::provider_cascade::{ProviderCascade, ProviderTier};
use serde::Serialize;

/// What we observed for one slot's live rate-limit + model-existence state.
#[derive(Debug, Clone, Serialize)]
pub struct ObservedSlotLimits {
    pub slot_name: String,
    pub configured_model: String,
    pub model_exists: Option<bool>,
    pub limit_requests: Option<u32>,
    pub remaining_requests: Option<u32>,
    pub retry_after_secs: Option<u32>,
    pub probe_ok: bool,
    pub probe_error: Option<String>,
}

/// A disagreement between configured (.env) and observed (live probe) state.
#[derive(Debug, Clone, Serialize)]
pub struct SlotDriftFinding {
    pub slot_name: String,
    pub kind: &'static str, // "model_not_found" | "rpm_mismatch" | "rpd_evidence"
    pub detail: String,
}

const DRIFT_RATIO_THRESHOLD: f64 = 1.5; // observed vs configured must disagree by >50% to flag

/// GET {base_url}/models, reading rate-limit headers and confirming the
/// configured model id is present in the returned list. Best-effort: any
/// transport/parse failure is reported in `probe_error`, never panics.
pub async fn probe_slot_models(
    base_url: &str,
    api_key: &str,
    configured_model: &str,
    slot_name: &str,
) -> ObservedSlotLimits {
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());

    let mut req = client.get(&url);
    if !api_key.is_empty() {
        req = req.bearer_auth(api_key);
    }

    match req.send().await {
        Ok(resp) => {
            let headers = resp.headers().clone();
            let limit_requests = header_u32(&headers, "x-ratelimit-limit-requests");
            let remaining_requests = header_u32(&headers, "x-ratelimit-remaining-requests");
            let retry_after_secs = header_u32(&headers, "retry-after");
            let status = resp.status();
            let status_ok = status.is_success();
            let model_exists = if status_ok {
                resp.json::<serde_json::Value>()
                    .await
                    .ok()
                    .map(|body| model_id_present(&body, configured_model))
            } else {
                None
            };
            ObservedSlotLimits {
                slot_name: slot_name.to_string(),
                configured_model: configured_model.to_string(),
                model_exists,
                limit_requests,
                remaining_requests,
                retry_after_secs,
                probe_ok: status_ok,
                probe_error: if status_ok {
                    None
                } else {
                    Some(format!("HTTP {}", status))
                },
            }
        }
        Err(e) => ObservedSlotLimits {
            slot_name: slot_name.to_string(),
            configured_model: configured_model.to_string(),
            model_exists: None,
            limit_requests: None,
            remaining_requests: None,
            retry_after_secs: None,
            probe_ok: false,
            probe_error: Some(e.to_string()),
        },
    }
}

fn header_u32(headers: &reqwest::header::HeaderMap, name: &str) -> Option<u32> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u32>().ok())
}

/// True if `configured_model` appears as an `id` in a `{"data": [{"id": ...}, ...]}`
/// OpenAI-shaped models list. Providers that return a different shape simply
/// yield `false` (treated as "can't confirm", not "definitely missing" — the
/// caller only alarms when `probe_ok` is also true).
fn model_id_present(body: &serde_json::Value, configured_model: &str) -> bool {
    body.get("data")
        .and_then(|d| d.as_array())
        .map(|arr| {
            arr.iter().any(|m| {
                m.get("id")
                    .and_then(|id| id.as_str())
                    .map(|id| id == configured_model)
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// Compare one observed probe against its slot's configured RPM/RPD. Returns
/// drift findings only — never mutates anything (AC #3).
pub fn compare_observed_to_configured(
    observed: &ObservedSlotLimits,
    configured_rpm: u32,
    configured_rpd: u32,
) -> Vec<SlotDriftFinding> {
    let mut findings = Vec::new();

    if observed.probe_ok {
        if let Some(false) = observed.model_exists {
            findings.push(SlotDriftFinding {
                slot_name: observed.slot_name.clone(),
                kind: "model_not_found",
                detail: format!(
                    "configured MODEL={} not found in {}'s live /models list — likely deprecated or renamed",
                    observed.configured_model, observed.slot_name
                ),
            });
        }
    }

    if let Some(observed_limit) = observed.limit_requests {
        if observed_limit > 0 && configured_rpm > 0 {
            let ratio = observed_limit as f64 / configured_rpm as f64;
            if !(1.0 / DRIFT_RATIO_THRESHOLD..=DRIFT_RATIO_THRESHOLD).contains(&ratio) {
                findings.push(SlotDriftFinding {
                    slot_name: observed.slot_name.clone(),
                    kind: "rpm_mismatch",
                    detail: format!(
                        "configured RPM={} disagrees with observed x-ratelimit-limit-requests={} for {} (ratio {:.2}x)",
                        configured_rpm, observed_limit, observed.slot_name, ratio
                    ),
                });
            }
        }
    }

    if let Some(evidence) =
        crate::provider_quality::declared_rpd_evidence(&observed.slot_name, configured_rpd)
    {
        findings.push(SlotDriftFinding {
            slot_name: observed.slot_name.clone(),
            kind: "rpd_evidence",
            detail: evidence,
        });
    }

    findings
}

/// Probe every enabled cloud slot and return (observed, findings) pairs.
/// Local slots are skipped — rate limits are a cloud-provider concept.
pub async fn probe_all_slots() -> Vec<(ObservedSlotLimits, Vec<SlotDriftFinding>)> {
    let cascade = ProviderCascade::from_env();
    let mut results = Vec::new();
    for slot in &cascade.slots {
        if slot.tier != ProviderTier::Cloud {
            continue;
        }
        let observed = probe_slot_models(
            &slot.base_url,
            slot.provider.api_key(),
            slot.provider.model(),
            &slot.name,
        )
        .await;
        let findings = compare_observed_to_configured(&observed, slot.rpm_limit, slot.rpd_limit);
        results.push((observed, findings));
    }
    results
}

/// Emit a `kind=provider_slot_drift` ambient event per finding — the "holler"
/// side of AC #3. Never edits `.env`; downstream gap-filing tooling reads
/// this ambient event the same way it does for every other drift class.
pub fn holler_findings(findings: &[SlotDriftFinding]) {
    for f in findings {
        crate::tool_policy::emit_ambient_json(
            "provider_slot_drift",
            serde_json::json!({
                "slot": f.slot_name,
                "drift_kind": f.kind,
                "detail": f.detail,
            }),
        );
    }
}

/// Run a full probe pass, hollering any drift found. Returns a human-readable
/// summary for CLI/log output.
pub async fn run_probe_and_report() -> String {
    let results = probe_all_slots().await;
    let mut lines = Vec::new();
    let mut total_findings = 0usize;
    for (observed, findings) in &results {
        if !observed.probe_ok {
            lines.push(format!(
                "  {} — probe failed: {}",
                observed.slot_name,
                observed.probe_error.as_deref().unwrap_or("unknown error")
            ));
            continue;
        }
        lines.push(format!(
            "  {} — model={} limit_requests={:?} remaining={:?} findings={}",
            observed.slot_name,
            observed.configured_model,
            observed.limit_requests,
            observed.remaining_requests,
            findings.len()
        ));
        total_findings += findings.len();
        holler_findings(findings);
    }
    format!(
        "provider probe: {} slot(s) checked, {} drift finding(s) hollered\n{}",
        results.len(),
        total_findings,
        lines.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_id_present_matches_openai_shape() {
        let body = serde_json::json!({
            "data": [
                {"id": "gemini-2.5-flash"},
                {"id": "gemini-3.0-pro"},
            ]
        });
        assert!(model_id_present(&body, "gemini-2.5-flash"));
        assert!(!model_id_present(&body, "gemini-9000"));
    }

    #[test]
    fn model_id_present_handles_missing_data() {
        let body = serde_json::json!({"unexpected": "shape"});
        assert!(!model_id_present(&body, "anything"));
    }

    #[test]
    fn compare_observed_flags_missing_model() {
        let observed = ObservedSlotLimits {
            slot_name: "gemini".to_string(),
            configured_model: "gemini-2.5-flash".to_string(),
            model_exists: Some(false),
            limit_requests: None,
            remaining_requests: None,
            retry_after_secs: None,
            probe_ok: true,
            probe_error: None,
        };
        let findings = compare_observed_to_configured(&observed, 0, 0);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].kind, "model_not_found");
    }

    #[test]
    fn compare_observed_flags_rpm_mismatch() {
        // CREDIBLE-227 AC #1 scenario: configured 360, observed provider says 10.
        let observed = ObservedSlotLimits {
            slot_name: "gemini".to_string(),
            configured_model: "gemini-2.5-flash".to_string(),
            model_exists: Some(true),
            limit_requests: Some(10),
            remaining_requests: Some(9),
            retry_after_secs: None,
            probe_ok: true,
            probe_error: None,
        };
        let findings = compare_observed_to_configured(&observed, 360, 0);
        assert!(findings.iter().any(|f| f.kind == "rpm_mismatch"));
    }

    #[test]
    fn compare_observed_no_findings_when_within_tolerance() {
        let observed = ObservedSlotLimits {
            slot_name: "gemini".to_string(),
            configured_model: "gemini-2.5-flash".to_string(),
            model_exists: Some(true),
            limit_requests: Some(350),
            remaining_requests: Some(300),
            retry_after_secs: None,
            probe_ok: true,
            probe_error: None,
        };
        let findings = compare_observed_to_configured(&observed, 360, 0);
        assert!(findings.is_empty());
    }
}
