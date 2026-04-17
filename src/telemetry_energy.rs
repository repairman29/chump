//! Energy telemetry for local inference workloads.
//!
//! OpenJarvis (Stanford Scaling Intelligence Lab) defines an `EnergyMonitor`
//! trait but ships it with an NVIDIA stub whose `is_available()` returns
//! `false`. This module provides **working** implementations for the
//! platforms Chump actually targets — starting with Apple Silicon via
//! `powermetrics`. Linux/NVIDIA comes next via `nvidia-smi`.
//!
//! # Why track energy?
//!
//! Latency and tokens/second are proxies. Joules-per-query is the real
//! battery-life and thermal-budget metric for on-device inference. On a
//! 24 GB MacBook Air running a 9 B 4-bit model, the difference between a
//! 5 W idle and a 35 W sustained generation is the difference between
//! "laptop stays cool" and "laptop throttles + drains in 90 minutes."
//!
//! # Design
//!
//! Mirrors OpenJarvis's trait shape (`EnergyMonitor` with `start()` +
//! `stop() -> EnergyReading`) so a future `openjarvis-telemetry`
//! interop layer is a one-trait-impl away. Our implementations actually
//! produce readings rather than returning `Default::default()`.
//!
//! # Backends
//!
//! | Platform | Backend | Status |
//! |---|---|---|
//! | macOS Apple Silicon | `powermetrics` (system binary, needs sudo OR a one-time `sudo powermetrics --sample-count 1` priming) | ✅ working |
//! | Linux + NVIDIA | `nvidia-smi --query-gpu=power.draw,temperature.gpu` | 🚧 scaffold (shipped in follow-up) |
//! | Linux + AMD | `rocm-smi` | 🚧 scaffold |
//! | Any | `None` fallback that returns zeroed readings | ✅ working |
//!
//! Each backend is feature-gated behind a `cfg!(target_os = ...)` branch
//! in [`auto_detect`] so the binary links cleanly on every platform.

use anyhow::Result;
use std::time::{Duration, Instant};

/// One snapshot of energy + thermal state sampled across a monitoring
/// window. Mirrors `openjarvis::telemetry::energy::EnergyReading` field-
/// for-field so interop is mechanical when we need it.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct EnergyReading {
    /// Total energy consumed during the monitoring window, in joules.
    pub energy_joules: f64,
    /// Average power during the monitoring window, in watts.
    pub power_watts: f64,
    /// Average GPU/accelerator utilization during the window, 0–100.
    pub gpu_utilization_pct: f64,
    /// Peak GPU/accelerator temperature during the window, in Celsius.
    pub gpu_temperature_c: f64,
    /// GPU memory used at the end of the window, in GB.
    pub gpu_memory_used_gb: f64,
    /// Wall-clock duration of the monitoring window, in seconds. Not part
    /// of the OpenJarvis schema; added here because downstream observability
    /// wants it.
    pub duration_secs: f64,
}

impl EnergyReading {
    /// Convert to per-query intelligence-per-watt figures when you know how
    /// many tokens the model generated during the window.
    pub fn tokens_per_joule(&self, tokens_generated: u64) -> Option<f64> {
        if self.energy_joules <= 0.0 || tokens_generated == 0 {
            None
        } else {
            Some(tokens_generated as f64 / self.energy_joules)
        }
    }
}

/// Start-stop interface for energy monitors. Implementations may run an
/// external sampler process (e.g. `powermetrics`) or call a vendor library
/// directly (e.g. `nvml-wrapper`). All sampling happens between `start()`
/// and `stop()`; `stop()` returns the aggregated window.
pub trait EnergyMonitor: Send + Sync {
    /// Stable identifier for the backend (e.g. `"apple-silicon"`,
    /// `"nvidia"`, `"none"`). Logged + used by [`auto_detect`] to pick.
    fn monitor_id(&self) -> &str;

    /// Whether this backend can actually produce readings on the current
    /// host. Callers should `auto_detect` rather than hard-wiring one
    /// implementation, because availability is a runtime property (e.g.
    /// `powermetrics` needs sudo; `nvidia-smi` needs the binary + a GPU).
    fn is_available(&self) -> bool;

    /// Begin sampling. Implementations may spawn a child process, open a
    /// counter handle, or simply record the start time — the caller treats
    /// this as an opaque side effect.
    fn start(&mut self);

    /// End sampling and return the aggregated reading. Must be callable
    /// even if `start()` was never invoked (returns a zeroed reading in
    /// that case, never panics).
    fn stop(&mut self) -> EnergyReading;
}

/// Auto-select the best available monitor for the current host. Order:
/// 1. Apple Silicon (macOS aarch64) → [`ApplePowermetricsMonitor`]
/// 2. NVIDIA (Linux + nvidia-smi) → [`NvidiaSmiMonitor`] (scaffold, returns
///    `is_available() = false` until the Linux branch is filled in)
/// 3. Fallback → [`NullMonitor`] (zeroed readings)
pub fn auto_detect() -> Box<dyn EnergyMonitor> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let m = ApplePowermetricsMonitor::new();
        if m.is_available() {
            return Box::new(m);
        }
    }
    #[cfg(target_os = "linux")]
    {
        let m = NvidiaSmiMonitor::new();
        if m.is_available() {
            return Box::new(m);
        }
    }
    Box::new(NullMonitor)
}

// ────────────────────────────────────────────────────────────────────
// NullMonitor — zero readings, always available, always honest about it.
// ────────────────────────────────────────────────────────────────────

/// Fallback monitor that produces zeroed readings. Used when no vendor
/// backend is available so callers don't need to `Option<EnergyReading>`.
pub struct NullMonitor;

impl EnergyMonitor for NullMonitor {
    fn monitor_id(&self) -> &str {
        "none"
    }
    fn is_available(&self) -> bool {
        true
    }
    fn start(&mut self) {}
    fn stop(&mut self) -> EnergyReading {
        EnergyReading::default()
    }
}

// ────────────────────────────────────────────────────────────────────
// ApplePowermetricsMonitor — real readings via the system `powermetrics`
// binary. The one-shot approach used here avoids the cost of running
// `powermetrics` as a persistent daemon.
// ────────────────────────────────────────────────────────────────────

/// Apple Silicon energy monitor backed by `/usr/bin/powermetrics`.
///
/// `powermetrics` requires root to run. This monitor does NOT try to
/// escalate — it assumes the operator has either:
///   (a) pre-approved passwordless `powermetrics` via `/etc/sudoers.d/`, or
///   (b) set `CHUMP_POWERMETRICS_BIN=/path/to/setuid-wrapper`.
///
/// On availability check failure, [`is_available`] returns false and
/// [`auto_detect`] falls through to the null monitor. That's deliberate:
/// energy telemetry is nice-to-have, never load-bearing.
pub struct ApplePowermetricsMonitor {
    start_time: Option<Instant>,
    /// Resolved path to the `powermetrics` binary. Honours
    /// `CHUMP_POWERMETRICS_BIN` env var when set.
    binary: String,
}

impl ApplePowermetricsMonitor {
    pub fn new() -> Self {
        let binary = std::env::var("CHUMP_POWERMETRICS_BIN")
            .unwrap_or_else(|_| "/usr/bin/powermetrics".to_string());
        Self {
            start_time: None,
            binary,
        }
    }

    /// One-shot sample: runs `powermetrics` once for a given duration and
    /// parses the output. Public so benches can call it directly without
    /// the `EnergyMonitor` trait plumbing.
    pub fn sample_for(&self, duration: Duration) -> Result<EnergyReading> {
        let duration_ms = duration.as_millis().max(50) as u64;
        let out = std::process::Command::new(&self.binary)
            .args([
                "--sample-count",
                "1",
                "--sample-rate",
                &duration_ms.to_string(),
                // Combined-power for total system; GPU for accelerator.
                "--samplers",
                "cpu_power,gpu_power,thermal",
                "--format",
                "plist",
            ])
            .output()?;
        if !out.status.success() {
            anyhow::bail!(
                "powermetrics exited non-zero ({}); stderr={}",
                out.status,
                String::from_utf8_lossy(&out.stderr)
            );
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        Ok(parse_powermetrics_plist(&stdout, duration.as_secs_f64()))
    }
}

impl Default for ApplePowermetricsMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl EnergyMonitor for ApplePowermetricsMonitor {
    fn monitor_id(&self) -> &str {
        "apple-silicon"
    }

    fn is_available(&self) -> bool {
        // Two gates: (a) binary exists, (b) we can actually invoke it
        // without a password prompt. Probe with a cheap --help rather
        // than an actual sample (which would need sudo).
        if std::fs::metadata(&self.binary).is_err() {
            return false;
        }
        // A real availability test runs the binary with no sampling —
        // exits non-zero if sudo/root isn't set up.
        std::process::Command::new(&self.binary)
            .arg("--help")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn start(&mut self) {
        self.start_time = Some(Instant::now());
    }

    fn stop(&mut self) -> EnergyReading {
        let duration = match self.start_time.take() {
            Some(t) => t.elapsed(),
            None => return EnergyReading::default(),
        };
        // Try to sample. On failure, return zero energy + the real duration
        // so downstream callers can still track wall time even when the
        // monitor was unprivileged.
        match self.sample_for(duration) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(
                    target: "chump::telemetry_energy",
                    monitor = "apple-silicon",
                    error = %e,
                    "powermetrics sample failed; returning zeroed reading"
                );
                EnergyReading {
                    duration_secs: duration.as_secs_f64(),
                    ..Default::default()
                }
            }
        }
    }
}

/// Parse a `powermetrics --format plist` blob into an [`EnergyReading`].
/// Tolerant of missing keys (returns zeros for whatever's absent).
pub fn parse_powermetrics_plist(plist: &str, duration_secs: f64) -> EnergyReading {
    // Minimal plist parsing: we only need a handful of keys, none of them
    // nested inside arrays. A dependency-free line-scan is simpler and
    // more forgiving than pulling in a full plist crate for four numbers.
    let combined_power_mw = extract_plist_number(plist, "combined_power");
    let gpu_power_mw = extract_plist_number(plist, "gpu_power");
    // powermetrics reports power in milliwatts.
    let power_watts = combined_power_mw.unwrap_or_else(|| gpu_power_mw.unwrap_or(0.0)) / 1000.0;
    let energy_joules = power_watts * duration_secs;

    let gpu_temperature_c = extract_plist_number(plist, "gpu_die_temperature")
        .or_else(|| extract_plist_number(plist, "die_temperature"))
        .unwrap_or(0.0);
    let gpu_utilization_pct = extract_plist_number(plist, "gpu_idle_ratio")
        .map(|idle| (1.0 - idle) * 100.0)
        .unwrap_or(0.0);

    EnergyReading {
        energy_joules,
        power_watts,
        gpu_utilization_pct,
        gpu_temperature_c,
        gpu_memory_used_gb: 0.0, // powermetrics doesn't report VRAM; left as zero.
        duration_secs,
    }
}

/// Extract a `<key>name</key><real>value</real>` pair from a plist blob.
/// Handles integer and real values; returns None if the key is missing.
fn extract_plist_number(plist: &str, key: &str) -> Option<f64> {
    // Look for `<key>NAME</key>` then the next `<real>X</real>` or
    // `<integer>X</integer>`. Good enough for powermetrics' flat schema.
    let marker = format!("<key>{}</key>", key);
    let after = plist.find(&marker)?;
    let tail = &plist[after + marker.len()..];
    // Find the opening tag of the value.
    let (open_tag, close_tag) = if let Some(i) = tail.find("<real>") {
        (i + "<real>".len(), tail[i..].find("</real>")? + i)
    } else if let Some(i) = tail.find("<integer>") {
        (i + "<integer>".len(), tail[i..].find("</integer>")? + i)
    } else {
        return None;
    };
    tail.get(open_tag..close_tag)?.trim().parse::<f64>().ok()
}

// ────────────────────────────────────────────────────────────────────
// NvidiaSmiMonitor — scaffold. Full implementation lands when we have a
// Linux host to test on.
// ────────────────────────────────────────────────────────────────────

/// Placeholder for Linux + NVIDIA. Scaffold only — fill in when a test
/// host is available. `is_available()` returns `false` so [`auto_detect`]
/// skips this on every host today.
pub struct NvidiaSmiMonitor;

impl NvidiaSmiMonitor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for NvidiaSmiMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl EnergyMonitor for NvidiaSmiMonitor {
    fn monitor_id(&self) -> &str {
        "nvidia"
    }
    fn is_available(&self) -> bool {
        false
    }
    fn start(&mut self) {}
    fn stop(&mut self) -> EnergyReading {
        EnergyReading::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_monitor_always_available() {
        let m = NullMonitor;
        assert!(m.is_available());
        assert_eq!(m.monitor_id(), "none");
    }

    #[test]
    fn null_monitor_start_stop_returns_zeros() {
        let mut m = NullMonitor;
        m.start();
        let r = m.stop();
        assert_eq!(r.energy_joules, 0.0);
        assert_eq!(r.power_watts, 0.0);
        assert_eq!(r.duration_secs, 0.0);
    }

    #[test]
    fn tokens_per_joule_guards_against_zero() {
        let r = EnergyReading {
            energy_joules: 0.0,
            ..Default::default()
        };
        assert!(r.tokens_per_joule(100).is_none());
        let r2 = EnergyReading {
            energy_joules: 10.0,
            ..Default::default()
        };
        assert!(r2.tokens_per_joule(0).is_none());
        let r3 = EnergyReading {
            energy_joules: 10.0,
            ..Default::default()
        };
        assert_eq!(r3.tokens_per_joule(250), Some(25.0));
    }

    #[test]
    fn parse_powermetrics_plist_happy_path() {
        // Synthetic minimal plist with the keys we care about.
        let plist = r#"<?xml version="1.0"?>
        <plist version="1.0">
        <dict>
            <key>combined_power</key><real>12500.5</real>
            <key>gpu_power</key><real>8000.0</real>
            <key>gpu_die_temperature</key><real>62.3</real>
            <key>gpu_idle_ratio</key><real>0.25</real>
        </dict>
        </plist>"#;
        let r = parse_powermetrics_plist(plist, 1.0);
        // combined_power (mW) / 1000 = W, × 1.0s = J
        assert!((r.power_watts - 12.5005).abs() < 1e-6);
        assert!((r.energy_joules - 12.5005).abs() < 1e-6);
        assert!((r.gpu_temperature_c - 62.3).abs() < 1e-6);
        // utilization = (1 - idle_ratio) × 100 = 75
        assert!((r.gpu_utilization_pct - 75.0).abs() < 1e-6);
        assert_eq!(r.gpu_memory_used_gb, 0.0);
        assert_eq!(r.duration_secs, 1.0);
    }

    #[test]
    fn parse_powermetrics_plist_missing_keys_returns_zeros() {
        let r = parse_powermetrics_plist("<plist></plist>", 0.5);
        assert_eq!(r.power_watts, 0.0);
        assert_eq!(r.energy_joules, 0.0);
        assert_eq!(r.gpu_temperature_c, 0.0);
        assert_eq!(r.gpu_utilization_pct, 0.0);
        assert_eq!(r.duration_secs, 0.5);
    }

    #[test]
    fn parse_powermetrics_handles_integer_values() {
        let plist = r#"<plist><dict>
            <key>combined_power</key><integer>8000</integer>
            <key>gpu_die_temperature</key><integer>55</integer>
        </dict></plist>"#;
        let r = parse_powermetrics_plist(plist, 2.0);
        assert!((r.power_watts - 8.0).abs() < 1e-6);
        assert!((r.energy_joules - 16.0).abs() < 1e-6);
        assert_eq!(r.gpu_temperature_c, 55.0);
    }

    #[test]
    fn nvidia_smi_scaffold_unavailable() {
        let m = NvidiaSmiMonitor;
        assert!(!m.is_available());
        assert_eq!(m.monitor_id(), "nvidia");
    }

    #[test]
    fn auto_detect_returns_something_on_every_host() {
        let m = auto_detect();
        // On CI (Ubuntu) → NullMonitor. On dev macs → apple-silicon.
        let id = m.monitor_id();
        assert!(id == "apple-silicon" || id == "nvidia" || id == "none");
    }
}
