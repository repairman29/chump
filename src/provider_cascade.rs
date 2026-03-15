//! Multi-provider cascade: try cloud providers (Groq, Cerebras, Mistral, OpenRouter, Gemini,
//! GitHub Models, NVIDIA NIM, SambaNova) in priority order; on rate limit or failure fall back
//! to next, then to local (slot 0). See docs/PROVIDER_CASCADE.md.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::openai::OpenAIProvider;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::local_openai::{self, LocalOpenAIProvider};

const DEFAULT_RPM_HEADROOM_PCT: f32 = 80.0;
const MAX_SLOTS: u32 = 9;

fn cascade_enabled() -> bool {
    std::env::var("CHUMP_CASCADE_ENABLED").map(|v| v == "1").unwrap_or(false)
}

fn rpm_headroom_pct() -> f32 {
    std::env::var("CHUMP_CASCADE_RPM_HEADROOM")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_RPM_HEADROOM_PCT)
        .clamp(1.0, 100.0)
        / 100.0
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ProviderTier {
    Local,
    Cloud,
}

#[derive(Clone, Copy)]
pub enum CascadeStrategy {
    Priority,
}

pub struct ProviderSlot {
    pub name: String,
    pub base_url: String,
    pub provider: LocalOpenAIProvider,
    pub priority: u32,
    pub tier: ProviderTier,
    pub rpm_limit: u32,
    pub calls_this_minute: AtomicU32,
    pub minute_start: Mutex<Instant>,
    /// Daily request cap (0 = unlimited). Set via CHUMP_PROVIDER_{N}_RPD.
    pub rpd_limit: u32,
    /// Calls made today (resets at midnight local time, approximately via day_start tracking).
    pub calls_today: AtomicU32,
    /// Start of the current 24h window.
    pub day_start: Mutex<Instant>,
}

fn within_rate_limit(slot: &ProviderSlot) -> bool {
    // RPM check
    if slot.rpm_limit > 0 {
        let mut start_guard = slot.minute_start.lock().unwrap();
        let now = Instant::now();
        if now.duration_since(*start_guard) > Duration::from_secs(60) {
            slot.calls_this_minute.store(0, Ordering::Relaxed);
            *start_guard = now;
        }
        drop(start_guard);
        let current = slot.calls_this_minute.load(Ordering::Relaxed);
        let effective = (slot.rpm_limit as f32 * rpm_headroom_pct()) as u32;
        if current >= effective {
            return false;
        }
    }

    // RPD check
    if slot.rpd_limit > 0 {
        let mut day_guard = slot.day_start.lock().unwrap();
        let now = Instant::now();
        if now.duration_since(*day_guard) > Duration::from_secs(86400) {
            slot.calls_today.store(0, Ordering::Relaxed);
            *day_guard = now;
        }
        drop(day_guard);
        let today = slot.calls_today.load(Ordering::Relaxed);
        let effective_rpd = (slot.rpd_limit as f32 * rpm_headroom_pct()) as u32;
        if today >= effective_rpd {
            if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                eprintln!(
                    "[cascade] {} daily cap reached ({}/{} RPD), skipping",
                    slot.name, today, slot.rpd_limit
                );
            }
            return false;
        }
    }

    true
}

fn record_call(slot: &ProviderSlot) {
    slot.calls_this_minute.fetch_add(1, Ordering::Relaxed);
    slot.calls_today.fetch_add(1, Ordering::Relaxed);
}

pub struct ProviderCascade {
    pub slots: Vec<ProviderSlot>,
    _strategy: CascadeStrategy,
}

impl ProviderCascade {
    /// Load slots from env. Slot 0 from OPENAI_*; slots 1..=3 from CHUMP_PROVIDER_{N}_*.
    pub fn from_env() -> Self {
        let mut slots: Vec<ProviderSlot> = Vec::new();

        if let Ok(base) = std::env::var("OPENAI_API_BASE") {
            let base = base.trim_end_matches('/').to_string();
            let api_key = std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "ollama".to_string());
            let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
            let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
                .ok()
                .filter(|s| !s.is_empty());
            let provider = LocalOpenAIProvider::with_fallback(
                base.clone(),
                fallback,
                api_key,
                model,
            );
            slots.push(ProviderSlot {
                name: "local".to_string(),
                base_url: base,
                provider,
                priority: 0,
                tier: ProviderTier::Local,
                rpm_limit: 0,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: 0,
                calls_today: AtomicU32::new(0),
                day_start: Mutex::new(Instant::now()),
            });
        }

        for n in 1..=MAX_SLOTS {
            let enabled = std::env::var(format!("CHUMP_PROVIDER_{}_ENABLED", n)).unwrap_or_default();
            if enabled != "1" {
                continue;
            }
            let base = match std::env::var(format!("CHUMP_PROVIDER_{}_BASE", n)) {
                Ok(b) if !b.is_empty() => b.trim_end_matches('/').to_string(),
                _ => continue,
            };
            let key = std::env::var(format!("CHUMP_PROVIDER_{}_KEY", n)).unwrap_or_default();
            let model = std::env::var(format!("CHUMP_PROVIDER_{}_MODEL", n))
                .unwrap_or_else(|_| "gpt-4".to_string());
            let name = std::env::var(format!("CHUMP_PROVIDER_{}_NAME", n))
                .unwrap_or_else(|_| format!("slot_{}", n));
            let priority = std::env::var(format!("CHUMP_PROVIDER_{}_PRIORITY", n))
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(n * 10);
            let rpm = std::env::var(format!("CHUMP_PROVIDER_{}_RPM", n))
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(30);
            let rpd = std::env::var(format!("CHUMP_PROVIDER_{}_RPD", n))
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);

            let provider = LocalOpenAIProvider::with_fallback(base.clone(), None, key, model);
            slots.push(ProviderSlot {
                name,
                base_url: base,
                provider,
                priority,
                tier: ProviderTier::Cloud,
                rpm_limit: rpm,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: rpd,
                calls_today: AtomicU32::new(0),
                day_start: Mutex::new(Instant::now()),
            });
        }

        slots.sort_by_key(|s| s.priority);
        let strategy = CascadeStrategy::Priority;
        Self {
            slots,
            _strategy: strategy,
        }
    }

    fn first_available_slot(&self) -> Option<usize> {
        // When cloud slots exist, skip local in priority selection — local is the explicit
        // last-resort fallback in complete(). Without this, local (priority=0) is always
        // first and cloud slots are never reached.
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        for (i, slot) in self.slots.iter().enumerate() {
            if has_cloud && slot.tier == ProviderTier::Local {
                continue;
            }
            if local_openai::is_circuit_open(&slot.base_url) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] {} circuit open, skipping", slot.name);
                }
                continue;
            }
            if !within_rate_limit(slot) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!(
                        "[cascade] {} rate limited (rpm={}/{} rpd={}/{}), skipping",
                        slot.name,
                        slot.calls_this_minute.load(Ordering::Relaxed),
                        slot.rpm_limit,
                        slot.calls_today.load(Ordering::Relaxed),
                        slot.rpd_limit,
                    );
                }
                continue;
            }
            return Some(i);
        }
        None
    }
}

#[async_trait]
impl Provider for ProviderCascade {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let mut idx = 0;
        loop {
            let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
            let i = if idx == 0 {
                self.first_available_slot()
            } else {
                self.slots
                    .iter()
                    .enumerate()
                    .skip(idx)
                    .find(|(_, slot)| {
                        // Skip local in cloud-first mode; it's the explicit last resort
                        !(has_cloud && slot.tier == ProviderTier::Local)
                            && !local_openai::is_circuit_open(&slot.base_url)
                            && within_rate_limit(slot)
                    })
                    .map(|(i, _)| i)
            };

            let i = match i {
                Some(i) => i,
                None => {
                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                        eprintln!("[cascade] all cloud exhausted, falling back to local");
                    }
                    let local_idx = self
                        .slots
                        .iter()
                        .position(|s| s.tier == ProviderTier::Local);
                    match local_idx {
                        Some(li) => {
                            let local_slot = &self.slots[li];
                            match local_slot
                                .provider
                                .complete(
                                    messages.clone(),
                                    tools.clone(),
                                    max_tokens,
                                    system_prompt.clone(),
                                )
                                .await
                            {
                                Ok(r) => {
                                    local_openai::record_circuit_success(&local_slot.base_url);
                                    return Ok(r);
                                }
                                Err(e) => return Err(e),
                            }
                        }
                        None => {
                            return Err(anyhow::anyhow!(
                                "no providers available (circuit open or rate limited; set OPENAI_API_BASE for local fallback)"
                            ));
                        }
                    }
                }
            };

            let slot = &self.slots[i];
            if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                eprintln!(
                    "[cascade] strategy=priority selected={} (priority={}, rpm={}/{}, rpd={}/{})",
                    slot.name,
                    slot.priority,
                    slot.calls_this_minute.load(Ordering::Relaxed),
                    slot.rpm_limit,
                    slot.calls_today.load(Ordering::Relaxed),
                    slot.rpd_limit,
                );
            }
            match slot
                .provider
                .complete(
                    messages.clone(),
                    tools.clone(),
                    max_tokens,
                    system_prompt.clone(),
                )
                .await
            {
                Ok(r) => {
                    local_openai::record_circuit_success(&slot.base_url);
                    record_call(slot);
                    return Ok(r);
                }
                Err(e) => {
                    // Also cascade on 429 (rate limit) or 403 (no access/credits on this slot).
                    // The inner LocalOpenAIProvider returns Err immediately on these; we just
                    // try the next slot.  We do NOT cascade on 400/422 (bad request — the
                    // request itself is wrong and another provider won't help).
                    let e_str = format!("{} {:?}", e, e);
                    let is_rate_limited = e_str.contains("429")
                        || e_str.to_ascii_lowercase().contains("too many requests")
                        || e_str.to_ascii_lowercase().contains("rate limit");
                    let is_access_denied = e_str.contains("403")
                        || e_str.to_ascii_lowercase().contains("forbidden");
                    if local_openai::is_transient_error(&e) || is_rate_limited || is_access_denied {
                        local_openai::record_circuit_failure(&slot.base_url);
                        if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                            eprintln!("[cascade] {} failed (transient), trying next", slot.name);
                        }
                        idx = i + 1;
                        continue;
                    }
                    return Err(e);
                }
            }
        }
    }
}

/// Build the provider: cascade if CHUMP_CASCADE_ENABLED=1 and OPENAI_API_BASE set; else single-provider.
pub fn build_provider() -> Box<dyn Provider + Send + Sync> {
    if cascade_enabled() {
        let cascade = ProviderCascade::from_env();
        if !cascade.slots.is_empty() {
            return Box::new(cascade);
        }
    }

    let api_key = std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "token-abc123".to_string());
    let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
    if let Ok(base) = std::env::var("OPENAI_API_BASE") {
        let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
            .ok()
            .filter(|s| !s.is_empty());
        return Box::new(LocalOpenAIProvider::with_fallback(
            base, fallback, api_key, model,
        ));
    }
    Box::new(OpenAIProvider::new(api_key).with_model(model))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_env_without_cascade_vars_yields_only_slot_zero_if_openai_base_set() {
        // Cannot easily test from_env without setting env; at least ensure it compiles and
        // cascade_enabled() is false when var unset.
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        assert!(!cascade_enabled());
    }
}
