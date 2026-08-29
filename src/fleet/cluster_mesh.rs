//! Cluster / inference-mesh probes and runtime fallback. See `scripts/ci/check-inference-mesh.sh`.
//! When `CHUMP_CLUSTER_MODE=1`, we optionally verify mesh HTTP endpoints before enabling
//! worker/delegate routing; on failure we fall back to local-primary behavior for the process.

use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;
use tokio::sync::OnceCell;

/// Before [`ensure_probed_once`] finishes with cluster on, stay on the local path.
const MESH_PENDING: u8 = 0;
const MESH_UP: u8 = 1;
const MESH_DOWN: u8 = 2;

static MESH_STATE: AtomicU8 = AtomicU8::new(MESH_PENDING);
static PROBE_ONCE: OnceCell<()> = OnceCell::const_new();

/// True when `CHUMP_CLUSTER_MODE=1` (operator asked for swarm-style routing).
#[inline]
pub fn cluster_mode_requested() -> bool {
    crate::env_flags::chump_cluster_mode()
}

/// Local-primary only: cluster off, probe pending/failed, or mesh unreachable.
#[inline]
pub fn force_local_primary_execution() -> bool {
    if !cluster_mode_requested() {
        return true;
    }
    match MESH_STATE.load(Ordering::Relaxed) {
        MESH_UP => false,
        MESH_PENDING | MESH_DOWN => true,
        _ => true,
    }
}

/// Only probe iPhone URL when false (default: probe Mac + iPhone like `check-inference-mesh.sh`).
fn skip_iphone_mesh_probe() -> bool {
    crate::env_flags::env_trim_eq("CHUMP_CLUSTER_MESH_SKIP_IPHONE", "1")
}

fn mac_models_url() -> String {
    std::env::var("INFERENCE_MESH_MAC_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:8000/v1/models".to_string())
}

fn iphone_models_url() -> String {
    std::env::var("INFERENCE_MESH_IPHONE_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "http://10.1.10.175:8889/v1/models".to_string())
}

async fn http_models_ok(client: &reqwest::Client, url: &str) -> bool {
    match client.get(url).send().await {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

async fn probe_inference_mesh() -> bool {
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
    else {
        return false;
    };
    let mac_ok = http_models_ok(&client, &mac_models_url()).await;
    if !mac_ok {
        return false;
    }
    if skip_iphone_mesh_probe() {
        return true;
    }
    http_models_ok(&client, &iphone_models_url()).await
}

/// Run mesh probe once per process when cluster mode is on; sets fallback flag on failure.
pub async fn ensure_probed_once() {
    let _ = PROBE_ONCE
        .get_or_init(|| async {
            if !cluster_mode_requested() {
                return;
            }
            if probe_inference_mesh().await {
                MESH_STATE.store(MESH_UP, Ordering::Relaxed);
                tracing::info!(
                    mac_url = %mac_models_url(),
                    iphone_skipped = skip_iphone_mesh_probe(),
                    "inference mesh probe succeeded"
                );
            } else {
                MESH_STATE.store(MESH_DOWN, Ordering::Relaxed);
                tracing::warn!(
                    "Mesh offline, falling back to LocalExecutor (M4-only routing); \
                     ignoring CHUMP_WORKER_API_BASE / CHUMP_DELEGATE for this process"
                );
            }
        })
        .await;
}

#[cfg(test)]
mod tests {
    use super::{cluster_mode_requested, force_local_primary_execution};
    use serial_test::serial;

    #[test]
    #[serial]
    fn cluster_mode_reads_env() {
        std::env::remove_var("CHUMP_CLUSTER_MODE");
        assert!(!cluster_mode_requested());
        std::env::set_var("CHUMP_CLUSTER_MODE", "1");
        assert!(cluster_mode_requested());
        std::env::remove_var("CHUMP_CLUSTER_MODE");
    }

    #[test]
    #[serial]
    fn local_primary_when_cluster_off() {
        std::env::remove_var("CHUMP_CLUSTER_MODE");
        assert!(force_local_primary_execution());
    }
}
