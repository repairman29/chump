//! Multi-provider cascade: try cloud providers (Groq, Cerebras, Mistral, OpenRouter, Gemini,
//! GitHub Models, NVIDIA NIM, SambaNova) in priority order; on rate limit or failure fall back
//! to next, then to local (slot 0). See docs/PROVIDER_CASCADE.md.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::openai::OpenAIProvider;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::cost_tracker;
use crate::local_openai::{self, LocalOpenAIProvider};
use crate::provider_quality;

const DEFAULT_RPM_HEADROOM_PCT: f32 = 80.0;
const MAX_SLOTS: u32 = 10;

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

fn parse_privacy_tier(s: &str) -> PrivacyTier {
    match s.trim().to_lowercase().as_str() {
        "trains" => PrivacyTier::Trains,
        "caution" => PrivacyTier::Caution,
        _ => PrivacyTier::Safe,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ProviderTier {
    Local,
    Cloud,
}

/// Privacy tier for provider slots. Safe = no training on data; Trains = provider trains on free-tier data.
/// Used with CHUMP_ROUND_PRIVACY: work/cursor_improve/battle_qa set safe so cascade skips Mistral/Gemini.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PrivacyTier {
    /// Provider may train on free-tier data (Mistral, Gemini).
    Trains = 0,
    Caution = 1,
    /// No training; safe for proprietary code.
    Safe = 2,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum CascadeStrategy {
    Priority,
    /// Skip first N cloud slots for low-value round types (research, opportunity, discovery).
    TaskAware,
}

pub struct ProviderSlot {
    pub name: String,
    pub base_url: String,
    pub provider: LocalOpenAIProvider,
    pub priority: u32,
    pub tier: ProviderTier,
    /// Privacy tier: Safe (no training), Caution, Trains (provider trains on free data). From CHUMP_PROVIDER_{N}_PRIVACY.
    pub privacy: PrivacyTier,
    /// Context window in thousands of tokens (e.g. 1000 = 1M). From CHUMP_PROVIDER_{N}_CONTEXT_K. Used when CHUMP_PREFER_LARGE_CONTEXT=1.
    pub context_k: Option<u32>,
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
                privacy: PrivacyTier::Safe,
                context_k: None,
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
            let privacy = std::env::var(format!("CHUMP_PROVIDER_{}_PRIVACY", n))
                .map(|s| parse_privacy_tier(&s))
                .unwrap_or(PrivacyTier::Safe);
            let context_k = std::env::var(format!("CHUMP_PROVIDER_{}_CONTEXT_K", n))
                .ok()
                .and_then(|v| v.trim().parse::<u32>().ok());

            let provider = LocalOpenAIProvider::with_fallback(base.clone(), None, key, model);
            slots.push(ProviderSlot {
                name,
                base_url: base,
                provider,
                priority,
                tier: ProviderTier::Cloud,
                privacy,
                context_k,
                rpm_limit: rpm,
                calls_this_minute: AtomicU32::new(0),
                minute_start: Mutex::new(Instant::now()),
                rpd_limit: rpd,
                calls_today: AtomicU32::new(0),
                day_start: Mutex::new(Instant::now()),
            });
        }

        slots.sort_by_key(|s| s.priority);
        let strategy = std::env::var("CHUMP_CASCADE_STRATEGY")
            .ok()
            .map(|s| match s.trim().to_lowercase().as_str() {
                "task_aware" | "taskaware" => CascadeStrategy::TaskAware,
                _ => CascadeStrategy::Priority,
            })
            .unwrap_or(CascadeStrategy::Priority);
        Self {
            slots,
            _strategy: strategy,
        }
    }

    /// Number of cloud slots to skip from the start for low-value rounds (TaskAware only).
    fn skip_cloud_slots_for_round_type(&self) -> u32 {
        if self._strategy != CascadeStrategy::TaskAware {
            return 0;
        }
        let round_type = std::env::var("CHUMP_CURRENT_ROUND_TYPE")
            .unwrap_or_else(|_| "work".to_string());
        match round_type.trim().to_lowercase().as_str() {
            "research" | "opportunity" | "discovery" => 2,
            _ => 0,
        }
    }

    /// Returns the first slot that is within rate limits and meets min_privacy (if set).
    /// skip_cloud: when > 0 (TaskAware low-value rounds), skip this many cloud slots from the start.
    /// When CHUMP_PREFER_LARGE_CONTEXT=1, prefer slots with larger context_k first.
    fn first_available_slot(&self, min_privacy: Option<PrivacyTier>, skip_cloud: u32) -> Option<usize> {
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        let mut order: Vec<usize> = (0..self.slots.len()).collect();
        order.sort_by(|&i, &j| {
            let a = &self.slots[i];
            let b = &self.slots[j];
            let da = provider_quality::demotion_offset(&a.name);
            let db = provider_quality::demotion_offset(&b.name);
            da.cmp(&db).then_with(|| {
                if prefer_large_context() {
                    let ak = a.context_k.unwrap_or(0);
                    let bk = b.context_k.unwrap_or(0);
                    bk.cmp(&ak).then_with(|| a.priority.cmp(&b.priority))
                } else {
                    a.priority.cmp(&b.priority)
                }
            })
        });
        let mut cloud_skipped = 0u32;
        for &i in &order {
            let slot = &self.slots[i];
            if has_cloud && slot.tier == ProviderTier::Local {
                continue;
            }
            if slot.tier == ProviderTier::Cloud {
                if cloud_skipped < skip_cloud {
                    cloud_skipped += 1;
                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                        eprintln!("[cascade] TaskAware: skipping {} (slot {})", slot.name, cloud_skipped);
                    }
                    continue;
                }
            }
            if provider_quality::should_skip_slot(&slot.name) {
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] {} sanity-fail rate >10%, skipping", slot.name);
                }
                continue;
            }
            if let Some(min) = min_privacy {
                if slot.privacy < min {
                    if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                        eprintln!("[cascade] {} privacy {:?} < {:?}, skipping", slot.name, slot.privacy, min);
                    }
                    continue;
                }
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

fn prefer_large_context() -> bool {
    std::env::var("CHUMP_PREFER_LARGE_CONTEXT")
        .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
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
        let min_privacy = std::env::var("CHUMP_ROUND_PRIVACY")
            .ok()
            .map(|s| parse_privacy_tier(&s));
        let skip_cloud = self.skip_cloud_slots_for_round_type();
        let mut idx = 0;
        loop {
            let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
            let i = if idx == 0 {
                self.first_available_slot(min_privacy, skip_cloud)
            } else {
                self.slots
                    .iter()
                    .enumerate()
                    .skip(idx)
                    .find(|(_, slot)| {
                        // Skip local in cloud-first mode; it's the explicit last resort
                        !(has_cloud && slot.tier == ProviderTier::Local)
                            && min_privacy.map_or(true, |min| slot.privacy >= min)
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
                    std::env::remove_var("CHUMP_CURRENT_SLOT_CONTEXT_K");
                    let t0 = std::time::Instant::now();
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
                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;
                    local_openai::record_circuit_success(&local_slot.base_url);
                    set_last_used_slot(local_slot.name.clone());
                    provider_quality::record_slot_success(&local_slot.name);
                    provider_quality::record_latency(&local_slot.name, latency_ms);
                    let est = r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                    cost_tracker::record_provider_call(&local_slot.name, est);
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
            if let Some(k) = slot.context_k {
                std::env::set_var("CHUMP_CURRENT_SLOT_CONTEXT_K", k.to_string());
            } else {
                std::env::remove_var("CHUMP_CURRENT_SLOT_CONTEXT_K");
            }
            let t0 = std::time::Instant::now();
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
                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;
                    local_openai::record_circuit_success(&slot.base_url);
                    record_call(slot);
                    set_last_used_slot(slot.name.clone());
                    provider_quality::record_slot_success(&slot.name);
                    provider_quality::record_latency(&slot.name, latency_ms);
                    let est = r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                    cost_tracker::record_provider_call(&slot.name, est);
                    return Ok(r);
                }
                Err(e) => {
                    // Also cascade on 429 (rate limit) or 403 (no access/credits on this slot).
                    // The inner LocalOpenAIProvider returns Err immediately on these; we just
                    // try the next slot.  We do NOT cascade on 400/422 (bad request — the
                    // request itself is wrong and another provider won't help).
                    // EXCEPTION: tool_use_failed / tool call validation failed are model-capability
                    // errors (e.g. Llama generating hermes-format calls); another provider may work.
                    let e_str = format!("{} {:?}", e, e);
                    let is_rate_limited = e_str.contains("429")
                        || e_str.contains("413") // Groq uses 413 for TPM exceeded
                        || e_str.to_ascii_lowercase().contains("too many requests")
                        || e_str.to_ascii_lowercase().contains("rate limit")
                        || e_str.to_ascii_lowercase().contains("tokens per minute")
                        || e_str.to_ascii_lowercase().contains("request too large for model");
                    let is_access_denied = e_str.contains("403")
                        || e_str.to_ascii_lowercase().contains("forbidden")
                        || (e_str.contains("404") && e_str.to_ascii_lowercase().contains("model"));
                    let is_tool_format_failure = e_str.to_ascii_lowercase().contains("tool_use_failed")
                        || e_str.to_ascii_lowercase().contains("tool call validation failed")
                        || e_str.to_ascii_lowercase().contains("failed to call a function");
                    if local_openai::is_transient_error(&e) || is_rate_limited || is_access_denied || is_tool_format_failure {
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

static CASCADE_FOR_STATUS: OnceLock<Arc<ProviderCascade>> = OnceLock::new();

static LAST_USED_SLOT: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn last_used_slot_cell() -> &'static Mutex<Option<String>> {
    LAST_USED_SLOT.get_or_init(|| Mutex::new(None))
}

pub fn set_last_used_slot(name: String) {
    if let Ok(mut g) = last_used_slot_cell().lock() {
        *g = Some(name);
    }
}

pub fn get_last_used_slot() -> Option<String> {
    last_used_slot_cell().lock().ok().and_then(|g| g.clone())
}

/// Record sanity-check failure for the given slot (call when sanity_check_reply fails after a completion).
pub fn record_slot_failure(slot_name: &str) {
    provider_quality::record_slot_failure(slot_name);
}

/// Wrapper so the same cascade instance is reused and GET /api/cascade-status can read live counters.
struct CascadeHolder(Arc<ProviderCascade>);

#[async_trait]
impl Provider for CascadeHolder {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        self.0
            .complete(messages, tools, max_tokens, system_prompt)
            .await
    }
}

/// Returns the shared cascade instance if one has been built (for GET /api/cascade-status).
pub fn cascade_for_status() -> Option<Arc<ProviderCascade>> {
    CASCADE_FOR_STATUS.get().cloned()
}

/// Remaining RPD budget: (total across slots, per-slot (name, remaining)). Uses same headroom as rate limit. For orchestrator to decide worker count.
pub fn cascade_budget_remaining() -> Option<(u64, Vec<(String, u32)>)> {
    let cascade = cascade_for_status().or_else(|| {
        if cascade_enabled() {
            let c = ProviderCascade::from_env();
            if c.slots.is_empty() {
                None
            } else {
                Some(Arc::new(c))
            }
        } else {
            None
        }
    })?;
    let headroom = rpm_headroom_pct();
    let mut total: u64 = 0;
    let per_slot: Vec<(String, u32)> = cascade
        .slots
        .iter()
        .map(|s| {
            let remaining = if s.rpd_limit == 0 {
                u32::MAX
            } else {
                let today = s.calls_today.load(Ordering::Relaxed);
                let effective = (s.rpd_limit as f32 * headroom) as u32;
                effective.saturating_sub(today)
            };
            if remaining != u32::MAX {
                total = total.saturating_add(remaining as u64);
            }
            (s.name.clone(), remaining)
        })
        .collect();
    Some((total, per_slot))
}

const WARM_PROBE_TIMEOUT_SECS: u64 = 15;

/// Probe each enabled slot with "Say OK"; mark circuit failure on non-200/timeout. Call at heartbeat start or every 30 min.
pub async fn warm_probe_all() {
    if !cascade_enabled() {
        return;
    }
    let cascade = ProviderCascade::from_env();
    let msg = vec![Message {
        role: "user".to_string(),
        content: "Say OK".to_string(),
    }];
    for slot in &cascade.slots {
        let base = slot.base_url.clone();
        let name = slot.name.clone();
        let fut = slot.provider.complete(msg.clone(), None, Some(10), None);
        match tokio::time::timeout(
            Duration::from_secs(WARM_PROBE_TIMEOUT_SECS),
            fut,
        )
        .await
        {
            Ok(Ok(_)) => {
                local_openai::record_circuit_success(&base);
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] warm_probe {} ok", name);
                }
            }
            Ok(Err(_)) | Err(_) => {
                local_openai::record_circuit_failure(&base);
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!("[cascade] warm_probe {} failed", name);
                }
            }
        }
    }
}

/// Build the provider: cascade if CHUMP_CASCADE_ENABLED=1 and OPENAI_API_BASE set; else single-provider.
/// When cascade is used, it is stored so GET /api/cascade-status can return live slot stats.
pub fn build_provider() -> Box<dyn Provider + Send + Sync> {
    if cascade_enabled() {
        let cascade = ProviderCascade::from_env();
        if !cascade.slots.is_empty() {
            let arc = Arc::new(cascade);
            let _ = CASCADE_FOR_STATUS.set(Arc::clone(&arc));
            return Box::new(CascadeHolder(arc));
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
