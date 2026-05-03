//! Multi-provider cascade: try cloud providers (Groq, Cerebras, Mistral, OpenRouter, Gemini,
//! GitHub Models, NVIDIA NIM, SambaNova) in priority order; on rate limit or failure fall back
//! to next, then to local (slot 0). See docs/architecture/PROVIDER_CASCADE.md.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::openai::OpenAIProvider;
use axonerai::provider::{CompletionResponse, Message, Provider, Tool};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::cost_tracker;
use crate::llm_backend_metrics;
use crate::local_openai::{self, LocalOpenAIProvider};
use crate::provider_quality;

const DEFAULT_RPM_HEADROOM_PCT: f32 = 80.0;
const MAX_SLOTS: u32 = 10;

/// Default OpenAI-compatible base for local Ollama when `OPENAI_API_BASE` is unset (matches OOTB wizard).
pub const DEFAULT_OLLAMA_API_BASE: &str = "http://127.0.0.1:11434/v1";

/// True if the key is meant for the hosted OpenAI platform (`sk-...`, including `sk-proj-...`).
pub fn looks_like_openai_platform_key(key: &str) -> bool {
    key.trim().starts_with("sk-")
}

/// Normalize `OPENAI_API_KEY` for local backends: empty and common placeholders map to `ollama`.
pub fn resolved_openai_api_key() -> String {
    let raw = std::env::var("OPENAI_API_KEY").unwrap_or_default();
    let t = raw.trim();
    if t.is_empty() || t == "token-abc123" || t.eq_ignore_ascii_case("not-needed") {
        "ollama".into()
    } else {
        t.to_string()
    }
}

fn cascade_enabled() -> bool {
    std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1")
        .unwrap_or(false)
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
/// Used with CHUMP_ROUND_PRIVACY: work/cursor_improve/doc_hygiene/battle_qa set safe so cascade skips Mistral/Gemini.
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
    /// Learn the best slot per workload from reward feedback. See
    /// [`crate::provider_bandit`] — Thompson Sampling by default, UCB1 if
    /// `CHUMP_BANDIT_STRATEGY=ucb1`.
    Bandit,
}

impl CascadeStrategy {
    pub fn label(self) -> &'static str {
        match self {
            CascadeStrategy::Priority => "priority",
            CascadeStrategy::TaskAware => "task_aware",
            CascadeStrategy::Bandit => "bandit",
        }
    }
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
        let mut start_guard = slot.minute_start.lock().unwrap_or_else(|e| e.into_inner());
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
        let mut day_guard = slot.day_start.lock().unwrap_or_else(|e| e.into_inner());
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
    /// Lazy-initialized bandit router. Only populated when `_strategy` is
    /// [`CascadeStrategy::Bandit`]; otherwise None. Kept inside the cascade
    /// (not a global) so each cascade instance has its own learning state
    /// and tests don't leak stats into production.
    bandit: std::sync::OnceLock<crate::provider_bandit::BanditRouter>,
}

impl ProviderCascade {
    /// Load slots from env. Slot 0 from OPENAI_*; slots 1..=3 from CHUMP_PROVIDER_{N}_*.
    pub fn from_env() -> Self {
        let mut slots: Vec<ProviderSlot> = Vec::new();

        if let Ok(base) = std::env::var("OPENAI_API_BASE") {
            let base = base.trim_end_matches('/').to_string();
            if !base.is_empty() {
                let api_key = resolved_openai_api_key();
                let model =
                    std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
                let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
                    .ok()
                    .filter(|s| !s.is_empty());
                let provider =
                    LocalOpenAIProvider::with_fallback(base.clone(), fallback, api_key, model);
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
        }

        for n in 1..=MAX_SLOTS {
            let enabled =
                std::env::var(format!("CHUMP_PROVIDER_{}_ENABLED", n)).unwrap_or_default();
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
                "bandit" | "learned" => CascadeStrategy::Bandit,
                _ => CascadeStrategy::Priority,
            })
            .unwrap_or(CascadeStrategy::Priority);
        Self {
            slots,
            _strategy: strategy,
            bandit: std::sync::OnceLock::new(),
        }
    }

    /// Lazy-initialize the bandit router with this cascade's current slot
    /// names. Only returns Some when strategy == Bandit.
    fn bandit(&self) -> Option<&crate::provider_bandit::BanditRouter> {
        if self._strategy != CascadeStrategy::Bandit {
            return None;
        }
        Some(self.bandit.get_or_init(|| {
            let arms: Vec<String> = self.slots.iter().map(|s| s.name.clone()).collect();
            let strategy = std::env::var("CHUMP_BANDIT_STRATEGY")
                .ok()
                .map(|s| crate::provider_bandit::BanditStrategy::from_env_str(&s))
                .unwrap_or_default();
            tracing::info!(
                target: "chump::provider_cascade",
                strategy = ?strategy,
                arms = ?arms,
                "bandit router initialized"
            );
            crate::provider_bandit::BanditRouter::new(arms, strategy)
        }))
    }

    /// Select the first slot via the bandit, restricted to slots that
    /// pass the current privacy/rate-limit/circuit filters. Returns None
    /// if no slot is available (callers fall through to the local-last-
    /// resort path same as priority-strategy does).
    fn bandit_first_available(
        &self,
        min_privacy: Option<PrivacyTier>,
        skip_cloud: u32,
    ) -> Option<usize> {
        let skip_cloud = skip_cloud as usize;
        let bandit = self.bandit()?;
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        // Build the name → index map for eligible slots.
        let eligible: Vec<(String, usize)> = self
            .slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| {
                !(has_cloud && slot.tier == ProviderTier::Local)
                    && min_privacy.is_none_or(|min| slot.privacy >= min)
                    && !local_openai::is_circuit_open(&slot.base_url)
                    && within_rate_limit(slot)
            })
            .skip(skip_cloud)
            .map(|(i, s)| (s.name.clone(), i))
            .collect();
        if eligible.is_empty() {
            return None;
        }
        let names: Vec<String> = eligible.iter().map(|(n, _)| n.clone()).collect();
        let pick_name = bandit.select_from(&names)?;
        eligible
            .into_iter()
            .find(|(n, _)| n == &pick_name)
            .map(|(_, i)| i)
    }

    /// Number of cloud slots to skip from the start for low-value rounds (TaskAware only).
    fn skip_cloud_slots_for_round_type(&self) -> u32 {
        if self._strategy != CascadeStrategy::TaskAware {
            return 0;
        }
        let round_type =
            std::env::var("CHUMP_CURRENT_ROUND_TYPE").unwrap_or_else(|_| "work".to_string());
        match round_type.trim().to_lowercase().as_str() {
            "research" | "opportunity" | "discovery" => 2,
            _ => 0,
        }
    }

    /// Returns the first slot that is within rate limits and meets min_privacy (if set).
    /// skip_cloud: when > 0 (TaskAware low-value rounds), skip this many cloud slots from the start.
    /// When CHUMP_PREFER_LARGE_CONTEXT=1, prefer slots with larger context_k first.
    fn first_available_slot(
        &self,
        min_privacy: Option<PrivacyTier>,
        skip_cloud: u32,
    ) -> Option<usize> {
        let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
        let regime = crate::precision_controller::current_regime();
        let prefer_local = regime == crate::precision_controller::PrecisionRegime::Exploit;
        let prefer_cloud = matches!(
            regime,
            crate::precision_controller::PrecisionRegime::Explore
                | crate::precision_controller::PrecisionRegime::Conservative
        );
        let mut order: Vec<usize> = (0..self.slots.len()).collect();
        order.sort_by(|&i, &j| {
            let a = &self.slots[i];
            let b = &self.slots[j];
            // Regime-based tier bias: prefer local when Exploit, cloud when Explore/Conservative
            let tier_bias_a: i32 = if (prefer_local && a.tier == ProviderTier::Local)
                || (prefer_cloud && a.tier == ProviderTier::Cloud)
            {
                -1
            } else {
                0
            };
            let tier_bias_b: i32 = if (prefer_local && b.tier == ProviderTier::Local)
                || (prefer_cloud && b.tier == ProviderTier::Cloud)
            {
                -1
            } else {
                0
            };
            let da = provider_quality::demotion_offset(&a.name);
            let db = provider_quality::demotion_offset(&b.name);
            tier_bias_a.cmp(&tier_bias_b).then_with(|| {
                da.cmp(&db).then_with(|| {
                    if prefer_large_context() {
                        let ak = a.context_k.unwrap_or(0);
                        let bk = b.context_k.unwrap_or(0);
                        bk.cmp(&ak).then_with(|| a.priority.cmp(&b.priority))
                    } else {
                        a.priority.cmp(&b.priority)
                    }
                })
            })
        });
        let mut cloud_skipped = 0u32;
        for &i in &order {
            let slot = &self.slots[i];
            if has_cloud && slot.tier == ProviderTier::Local {
                continue;
            }
            if slot.tier == ProviderTier::Cloud && cloud_skipped < skip_cloud {
                cloud_skipped += 1;
                if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                    eprintln!(
                        "[cascade] TaskAware: skipping {} (slot {})",
                        slot.name, cloud_skipped
                    );
                }
                continue;
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
                        eprintln!(
                            "[cascade] {} privacy {:?} < {:?}, skipping",
                            slot.name, slot.privacy, min
                        );
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

/// INFRA-300: classify a provider error string for cascade failover.
///
/// Returns `true` if the error indicates the *current* slot can't serve
/// THIS request but a *sibling* slot probably can — i.e. cascade onward.
/// Returns `false` for errors that should propagate (bad request, model
/// crash, etc.).
///
/// Categories that cascade:
/// - **Rate limit** (429, 413 for Groq TPM, "rate limit", "tokens per minute")
/// - **Access denied** (401, 403, "unauthorized", "forbidden", "models permission")
/// - **Billing exhausted** (402, "credit_limit", "insufficient quota",
///   "payment required", "billing") — added 2026-05-02 after Together's
///   free credits drained and a 50% silent-failure rate hit the PWA.
///   See [`is_billing_exhausted_error_string`] (extracted as a helper
///   in INFRA-302 so callers above the cascade layer can detect it
///   too).
/// - **Tool format** ("tool_use_failed", "tool call validation failed")
/// - **Tool capability** (Cerebras 400 "UnsupportedToolUse", "does not
///   support tools", ...) — INFRA-313: technically 400-status but
///   another model handles the same payload, so cascade-onward is the
///   right behavior. Symptomatically identical to `tool_use_failed`.
/// - **Transport-level errors** ("error sending request", "model HTTP
///   unreachable", "connection refused", "operation timed out", "no route
///   to host", "name resolution failed") — INFRA-348: `LocalOpenAIProvider`
///   wraps the underlying reqwest transport error with an educational hint
///   string. The wrapped error loses the typed chain so
///   `local_openai::is_transient_error` (which calls `format!("{:?}", err)`)
///   can no longer classify it. The string predicate is the correct fix
///   layer: recognise the wrapped patterns so the cascade falls over to a
///   cloud slot when the local daemon is down/unreachable.
///
/// Note: this only inspects the error *string*. The full check in `complete()`
/// also calls `local_openai::is_transient_error(&e)` for transport-level
/// errors (timeouts, connection resets) which require the typed `&Error`.
pub(crate) fn should_cascade_on_error_string(e_str: &str) -> bool {
    let lower = e_str.to_ascii_lowercase();
    let is_rate_limited = e_str.contains("429")
        || e_str.contains("413") // Groq uses 413 for TPM exceeded
        || lower.contains("too many requests")
        || lower.contains("rate limit")
        || lower.contains("tokens per minute")
        || lower.contains("request too large for model");
    let is_access_denied = e_str.contains("401")
        || e_str.contains("403")
        || lower.contains("unauthorized")
        || lower.contains("models permission")
        || lower.contains("forbidden")
        || (e_str.contains("404") && lower.contains("model"));
    let is_tool_format_failure = lower.contains("tool_use_failed")
        || lower.contains("tool call validation failed")
        || lower.contains("failed to call a function");
    // INFRA-313: model-capability-class 400 errors. Default cascade-on-400 is
    // OFF (the request is wrong → another provider won't help) but for these
    // *capability* errors the request is fine; it's just THIS model that
    // can't handle the tool-call shape (e.g. Cerebras returns 400
    // "UnsupportedToolUse: model does not support more than one tool call at
    // this time"). A model that DOES support multiple tool calls (Anthropic,
    // OpenAI, Together's larger models) will succeed on the same payload.
    let is_tool_capability_failure = lower.contains("unsupportedtooluse")
        || lower.contains("unsupported_tool_use")
        || lower.contains("does not support more than one tool")
        || lower.contains("does not support tool")
        || lower.contains("tools are not supported")
        || lower.contains("model does not support tools");
    // INFRA-348: transport-level errors wrapped by LocalOpenAIProvider.
    // `LocalOpenAIProvider::complete` appends an educational hint string
    // (e.g. "— model HTTP unreachable (daemon down, crashed, or still
    // starting). Ollama: brew services start ollama …") via
    // `Err(anyhow!("{}{}", err, hint))`. This re-wraps into a plain-string
    // anyhow error and loses the typed chain, so `is_transient_error`'s
    // `format!("{:?}", err)` chain inspection no longer fires. Match the
    // wrapped patterns here so the cascade falls over to a cloud slot when
    // the local daemon is down.
    let is_transport_error = lower.contains("error sending request")
        || lower.contains("model http unreachable")
        || lower.contains("connection refused")
        || lower.contains("operation timed out")
        || lower.contains("no route to host")
        || lower.contains("name resolution failed")
        || lower.contains("dns resolution failed")
        || lower.contains("tcp connect error")
        || lower.contains("model temporarily unavailable");
    is_rate_limited
        || is_access_denied
        || is_billing_exhausted_error_string(e_str)
        || is_tool_format_failure
        || is_tool_capability_failure
        || is_transport_error
}

/// INFRA-302 blocker (1): the billing-exhausted predicate, factored out
/// of [`should_cascade_on_error_string`] so callers above the cascade
/// layer can detect it independently. Same set INFRA-300 added the
/// per-call cascade fail-over for; reused here so `chump --execute-gap`
/// (the agent-loop entry, NOT the per-call cascade) can classify its
/// own errors without re-implementing the predicate.
///
/// Returns `true` when the error string is the 402/credit-exhausted
/// class — i.e. the operator/orchestrator should switch provider, top
/// up credits, or cascade to the next routing candidate, NOT just
/// retry the same call.
pub(crate) fn is_billing_exhausted_error_string(e_str: &str) -> bool {
    let lower = e_str.to_ascii_lowercase();
    e_str.contains("402")
        || lower.contains("credit_limit")
        || lower.contains("credit limit")
        || lower.contains("insufficient quota")
        || lower.contains("insufficient_quota")
        || lower.contains("payment required")
        || lower.contains("billing")
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
        // INFRA-COST-CEILING: enforce hard ceiling and emit soft warn before
        // any provider call is made.
        match cost_tracker::check_ceiling() {
            Err(msg) => return Err(anyhow::anyhow!("{}", msg)),
            Ok(true) => {
                let current = cost_tracker::session_cost_usd();
                let ceiling = cost_tracker::cost_ceiling_usd();
                eprintln!(
                    "COST WARNING: ${:.2} spent this session (limit: ${:.2})",
                    current, ceiling
                );
            }
            Ok(false) => {}
        }

        let min_privacy = std::env::var("CHUMP_ROUND_PRIVACY")
            .ok()
            .map(|s| parse_privacy_tier(&s));
        let skip_cloud = self.skip_cloud_slots_for_round_type();
        let mut idx = 0;
        loop {
            let has_cloud = self.slots.iter().any(|s| s.tier == ProviderTier::Cloud);
            let i = if idx == 0 {
                // Bandit strategy: learned selection among eligible slots.
                // Falls through to priority ordering if the bandit yields None
                // (no eligible slot; matches priority-strategy semantics).
                if self._strategy == CascadeStrategy::Bandit {
                    self.bandit_first_available(min_privacy, skip_cloud)
                        .or_else(|| self.first_available_slot(min_privacy, skip_cloud))
                } else {
                    self.first_available_slot(min_privacy, skip_cloud)
                }
            } else {
                self.slots
                    .iter()
                    .enumerate()
                    .skip(idx)
                    .find(|(_, slot)| {
                        // Skip local in cloud-first mode; it's the explicit last resort
                        !(has_cloud && slot.tier == ProviderTier::Local)
                            && min_privacy.is_none_or(|min| slot.privacy >= min)
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
                            let local_res = {
                                let _cascade_inner = llm_backend_metrics::CascadeInnerGuard::new();
                                local_slot
                                    .provider
                                    .complete(
                                        messages.clone(),
                                        tools.clone(),
                                        max_tokens,
                                        system_prompt.clone(),
                                    )
                                    .await
                            };
                            match local_res {
                                Ok(r) => {
                                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;
                                    local_openai::record_circuit_success(&local_slot.base_url);
                                    record_call(local_slot);
                                    set_last_used_slot(local_slot.name.clone());
                                    llm_backend_metrics::record_cascade_slot(&local_slot.name);
                                    provider_quality::record_slot_success(&local_slot.name);
                                    provider_quality::record_latency(&local_slot.name, latency_ms);
                                    let est =
                                        r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                                    cost_tracker::record_provider_call(&local_slot.name, est);
                                    cost_tracker::record_completion(1, 0, est);
                                    let tier = if local_slot.tier == ProviderTier::Cloud {
                                        crate::precision_controller::ModelTier::Capable
                                    } else {
                                        crate::precision_controller::ModelTier::Standard
                                    };
                                    crate::precision_controller::record_model_decision(tier);
                                    crate::precision_controller::record_energy_spent(est, 0);
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
                    "[cascade] strategy={} selected={} (priority={}, rpm={}/{}, rpd={}/{})",
                    self._strategy.label(),
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
            let slot_res = {
                let _cascade_inner = llm_backend_metrics::CascadeInnerGuard::new();
                slot.provider
                    .complete(
                        messages.clone(),
                        tools.clone(),
                        max_tokens,
                        system_prompt.clone(),
                    )
                    .await
            };
            match slot_res {
                Ok(r) => {
                    let latency_ms = t0.elapsed().as_secs_f64() * 1000.0;

                    // Quality gate: if response is empty and tools were provided,
                    // the model likely failed silently — try the next slot.
                    let is_empty = r.text.as_ref().map(|t| t.trim().is_empty()).unwrap_or(true)
                        && r.tool_calls.is_empty();
                    let has_malformed_tools = r.tool_calls.iter().any(|tc| {
                        tc.name.is_empty()
                            || (tc.input.is_object()
                                && tc.input.as_object().map(|o| o.is_empty()).unwrap_or(false)
                                && tools.as_ref().map(|t| !t.is_empty()).unwrap_or(false))
                    });
                    if (is_empty || has_malformed_tools) && i + 1 < self.slots.len() {
                        if std::env::var("CHUMP_LOG_TIMING").is_ok() {
                            eprintln!(
                                "[cascade] {} returned empty/malformed response, trying next slot",
                                slot.name
                            );
                        }
                        provider_quality::record_slot_failure(&slot.name);
                        if let Some(b) = self.bandit() {
                            // Empty/malformed response → reward 0 for this slot.
                            b.update(&slot.name, 0.0);
                        }
                        idx = i + 1;
                        continue;
                    }

                    local_openai::record_circuit_success(&slot.base_url);
                    record_call(slot);
                    set_last_used_slot(slot.name.clone());
                    llm_backend_metrics::record_cascade_slot(&slot.name);
                    provider_quality::record_slot_success(&slot.name);
                    provider_quality::record_latency(&slot.name, latency_ms);
                    let est = r.text.as_ref().map(|t| (t.len() / 4) as u64).unwrap_or(0);
                    cost_tracker::record_provider_call(&slot.name, est);
                    cost_tracker::record_completion(1, 0, est);
                    let tier = if slot.tier == ProviderTier::Cloud {
                        crate::precision_controller::ModelTier::Capable
                    } else {
                        crate::precision_controller::ModelTier::Standard
                    };
                    crate::precision_controller::record_model_decision(tier);
                    crate::precision_controller::record_energy_spent(est, 0);
                    // Bandit feedback: reward this slot on success. Weighted
                    // by latency + rough throughput so the policy prefers
                    // fast slots all else equal.
                    if let Some(b) = self.bandit() {
                        let latency_s = latency_ms / 1000.0;
                        let tps = if latency_s > 0.0 {
                            est as f64 / latency_s
                        } else {
                            0.0
                        };
                        let reward = crate::provider_bandit::compose_reward(true, latency_s, tps);
                        b.update(&slot.name, reward);
                    }
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
                    // INFRA-300: classify via shared predicate. Cascades on
                    // 429/413 (rate), 401/403 (access), 402/credit_limit
                    // (billing — added when Together's free credits drained
                    // and the PWA started returning empty bubbles), and
                    // tool_use_failed (model capability). Transport-level
                    // transient errors (timeout/reset) need the typed &Error,
                    // so they're checked separately.
                    if local_openai::is_transient_error(&e)
                        || should_cascade_on_error_string(&e_str)
                    {
                        local_openai::record_circuit_failure(&slot.base_url);
                        if let Some(b) = self.bandit() {
                            // Transient failure on this slot — reward 0 so the
                            // bandit learns to avoid it until it recovers.
                            b.update(&slot.name, 0.0);
                        }
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
    let _pause_llm_metrics = llm_backend_metrics::RecordingPauseGuard::new();
    let cascade = ProviderCascade::from_env();
    let msg = vec![Message {
        role: "user".to_string(),
        content: "Say OK".to_string(),
    }];
    for slot in &cascade.slots {
        let base = slot.base_url.clone();
        let name = slot.name.clone();
        let fut = slot.provider.complete(msg.clone(), None, Some(10), None);
        match tokio::time::timeout(Duration::from_secs(WARM_PROBE_TIMEOUT_SECS), fut).await {
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

/// Wraps any provider to count successful outer completions for `CHUMP_BATTLE_BENCHMARK` baselines.
struct BattleInstrumentedProvider {
    inner: Box<dyn Provider + Send + Sync>,
}

#[async_trait]
impl Provider for BattleInstrumentedProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let res = self
            .inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await;
        if res.is_ok() {
            crate::precision_controller::record_battle_benchmark_model_round();
        }
        res
    }
}

/// Build the provider: in-process mistral.rs first when configured; else cascade if
/// `CHUMP_CASCADE_ENABLED=1` and slots are non-empty; else single HTTP/OpenAI provider.
/// When cascade is used, it is stored so GET /api/cascade-status can return live slot stats.
pub fn build_provider() -> Box<dyn Provider + Send + Sync> {
    build_provider_with_mistral_stream().0
}

/// Same primary [`Provider`] as [`build_provider`], plus an [`Arc`] handle to [`crate::mistralrs_provider::MistralRsProvider`]
/// when that backend is active — used by web/RPC streaming to emit [`crate::stream_events::AgentEvent::TextDelta`].
#[cfg(feature = "mistralrs-infer")]
pub fn build_provider_with_mistral_stream() -> (
    Box<dyn Provider + Send + Sync>,
    Option<std::sync::Arc<crate::mistralrs_provider::MistralRsProvider>>,
) {
    if crate::mistralrs_provider::mistralrs_backend_configured() {
        let id = std::env::var("CHUMP_MISTRALRS_MODEL").unwrap_or_default();
        let m = std::sync::Arc::new(crate::mistralrs_provider::MistralRsProvider::new(id));
        let inner = Box::new(crate::mistralrs_provider::SharedMistralProvider(
            std::sync::Arc::clone(&m),
        ));
        let p = Box::new(BattleInstrumentedProvider { inner });
        return (p, Some(m));
    }
    (build_provider_inner_wrapped(), None)
}

#[cfg(not(feature = "mistralrs-infer"))]
pub fn build_provider_with_mistral_stream() -> (Box<dyn Provider + Send + Sync>, ()) {
    (build_provider_inner_wrapped(), ())
}

fn build_provider_inner_wrapped() -> Box<dyn Provider + Send + Sync> {
    let inner: Box<dyn Provider + Send + Sync> = if cascade_enabled() {
        let cascade = ProviderCascade::from_env();
        if !cascade.slots.is_empty() {
            let arc = Arc::new(cascade);
            let _ = CASCADE_FOR_STATUS.set(Arc::clone(&arc));
            Box::new(CascadeHolder(arc))
        } else {
            build_provider_single()
        }
    } else {
        build_provider_single()
    };
    Box::new(BattleInstrumentedProvider { inner })
}

/// Records [`llm_backend_metrics`] when completions use hosted OpenAI (no `OPENAI_API_BASE`).
struct OpenAiApiLlmRecorder {
    inner: OpenAIProvider,
}

#[async_trait]
impl Provider for OpenAiApiLlmRecorder {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let r = self
            .inner
            .complete(messages, tools, max_tokens, system_prompt)
            .await;
        if r.is_ok() {
            let label = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "default".to_string());
            llm_backend_metrics::record_openai_api(&label);
        }
        r
    }
}

fn build_provider_single() -> Box<dyn Provider + Send + Sync> {
    #[cfg(feature = "mistralrs-infer")]
    {
        if crate::mistralrs_provider::mistralrs_backend_configured() {
            let id = std::env::var("CHUMP_MISTRALRS_MODEL").unwrap_or_default();
            return Box::new(crate::mistralrs_provider::MistralRsProvider::new(id));
        }
    }
    let api_key = resolved_openai_api_key();
    let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
    if let Ok(base) = std::env::var("OPENAI_API_BASE") {
        let base = base.trim();
        if !base.is_empty() {
            let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
                .ok()
                .filter(|s| !s.is_empty());
            return Box::new(LocalOpenAIProvider::with_fallback(
                base.to_string(),
                fallback,
                api_key,
                model,
            ));
        }
    }
    if looks_like_openai_platform_key(&api_key) {
        return Box::new(OpenAiApiLlmRecorder {
            inner: OpenAIProvider::new(api_key).with_model(model),
        });
    }
    let fallback = std::env::var("CHUMP_FALLBACK_API_BASE")
        .ok()
        .filter(|s| !s.is_empty());
    Box::new(LocalOpenAIProvider::with_fallback(
        DEFAULT_OLLAMA_API_BASE.to_string(),
        fallback,
        api_key,
        model,
    ))
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

    // INFRA-300: HTTP 402 / credit_limit must cascade to the next slot.
    // Regression for the 2026-05-02 PWA empty-bubble incident.
    #[test]
    fn cascades_on_together_402_credit_limit() {
        // Real Together error string from the 2026-05-02 incident.
        let together_402 = "Local API error 402 Payment Required: {\n  \"id\": \"ohY6Cew-2kFHot-9f5af0bb2e16193a\",\n  \"error\": {\n    \"message\": \"Credit limit exceeded, please add credits.\",\n    \"type\": \"credit_limit\"\n  }\n}";
        assert!(
            should_cascade_on_error_string(together_402),
            "Together 402 credit_limit must cascade — was hanging the PWA"
        );
    }

    #[test]
    fn cascades_on_openai_insufficient_quota() {
        // OpenAI's variant of the same scenario.
        let openai_quota = "Local API error 429 {\"error\": {\"type\": \"insufficient_quota\", \"message\": \"You exceeded your current quota\"}}";
        assert!(should_cascade_on_error_string(openai_quota));
    }

    #[test]
    fn cascades_on_anthropic_billing() {
        let anthropic_billing = "Provider error: billing required";
        assert!(should_cascade_on_error_string(anthropic_billing));
    }

    #[test]
    fn cascades_on_existing_categories_still_work() {
        // Make sure the refactor didn't regress the pre-INFRA-300 categories.
        assert!(
            should_cascade_on_error_string("HTTP 429 Too Many Requests"),
            "rate limit"
        );
        assert!(
            should_cascade_on_error_string("HTTP 401 Unauthorized"),
            "access denied"
        );
        assert!(
            should_cascade_on_error_string("HTTP 403 Forbidden"),
            "forbidden"
        );
        assert!(
            should_cascade_on_error_string("HTTP 413 Request too large for model"),
            "Groq TPM via 413"
        );
        assert!(
            should_cascade_on_error_string("Error: tool_use_failed"),
            "tool format"
        );
        assert!(
            should_cascade_on_error_string("tool call validation failed: missing field"),
            "tool validation"
        );
    }

    #[test]
    fn does_not_cascade_on_bad_request_or_model_crash() {
        // 400 / 422 / 500 are NOT cascade-worthy — the request is wrong or
        // the provider crashed; another provider won't help.
        assert!(
            !should_cascade_on_error_string("HTTP 400 Bad Request: missing field"),
            "400 should propagate, not cascade"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 422 Unprocessable Entity"),
            "422 should propagate, not cascade"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 500 Internal Server Error"),
            "500 (provider crash) should propagate"
        );
    }

    // INFRA-348: transport-level errors wrapped by LocalOpenAIProvider must cascade.
    // Root cause: LocalOpenAIProvider::complete re-wraps the reqwest transport error
    // with an educational hint string via `anyhow!("{}{}", err, hint)`. This loses the
    // typed chain so `is_transient_error`'s `format!("{:?}", err)` inspection no longer
    // fires. The string predicate must cover these wrapped patterns.
    #[test]
    fn cascades_on_wrapped_transport_error_error_sending_request() {
        // Real 2026-05-02 dogfood error string from the INFRA-348 repro:
        let wrapped = "error sending request for url (http://127.0.0.1:11434/v1/chat/completions) \
            — model HTTP unreachable (daemon down, crashed, or still starting). \
            Ollama: brew services start ollama (or restart); probe: curl -s \
            http://127.0.0.1:11434/api/tags. Prefer OPENAI_API_BASE=\
            http://127.0.0.1:11434/v1 if localhost misbehaves. Backup URL: \
            CHUMP_FALLBACK_API_BASE. vLLM: :8000/:8001.";
        assert!(
            should_cascade_on_error_string(wrapped),
            "wrapped 'error sending request' must cascade — local daemon was down, \
             CHUMP_CASCADE_ENABLED=1 with 8 cloud slots did NOT fall over (INFRA-348 repro)"
        );
    }

    #[test]
    fn cascades_on_model_http_unreachable() {
        assert!(
            should_cascade_on_error_string(
                "model HTTP unreachable (daemon down, crashed, or still starting)"
            ),
            "model HTTP unreachable must cascade"
        );
    }

    #[test]
    fn cascades_on_connection_refused() {
        // Previously the comment said "handled by is_transient_error, not the string predicate"
        // but the typed-chain inspection fails for wrapped anyhow errors (INFRA-348). The string
        // predicate is now the canonical handler for transport errors at the cascade boundary.
        assert!(
            should_cascade_on_error_string("Connection refused"),
            "connection refused must cascade via string predicate (INFRA-348)"
        );
    }

    #[test]
    fn cascades_on_transport_error_variants() {
        assert!(
            should_cascade_on_error_string("operation timed out connecting to model"),
            "operation timed out"
        );
        assert!(
            should_cascade_on_error_string("no route to host (http://127.0.0.1:8000)"),
            "no route to host"
        );
        assert!(
            should_cascade_on_error_string("name resolution failed for localhost"),
            "name resolution failed"
        );
        assert!(
            should_cascade_on_error_string("model temporarily unavailable"),
            "model temporarily unavailable"
        );
    }

    #[test]
    fn case_insensitive_billing_match() {
        assert!(should_cascade_on_error_string("CREDIT_LIMIT"));
        assert!(should_cascade_on_error_string("Credit Limit Exceeded"));
        assert!(should_cascade_on_error_string("PAYMENT REQUIRED"));
    }

    // INFRA-313: model-capability tool-use failures (400-status but cascading
    // makes sense because another model handles the same payload).
    #[test]
    fn cascades_on_cerebras_unsupported_tool_use() {
        let cerebras_400 = "Local API error 400 Bad Request: {\"error\":{\"code\":\"UnsupportedToolUse\",\"message\":\"Request included unsupported tool use. This model does not support more than one tool call at this time.\"}}";
        assert!(
            should_cascade_on_error_string(cerebras_400),
            "Cerebras UnsupportedToolUse must cascade — another model handles the same payload"
        );
    }

    #[test]
    fn cascades_on_does_not_support_tool_variants() {
        assert!(should_cascade_on_error_string(
            "Error: model does not support tools"
        ));
        assert!(should_cascade_on_error_string(
            "tools are not supported by this endpoint"
        ));
        assert!(should_cascade_on_error_string(
            "{\"code\":\"unsupported_tool_use\"}"
        ));
    }

    #[test]
    fn does_not_cascade_on_400_unrelated_to_tools() {
        assert!(
            !should_cascade_on_error_string(
                "HTTP 400 Bad Request: required field 'messages' missing"
            ),
            "generic 400 should still propagate (not cascade)"
        );
        assert!(
            !should_cascade_on_error_string("HTTP 400 Bad Request: invalid model name 'gpt-99'"),
            "invalid model name should still propagate"
        );
    }

    // INFRA-302 blocker (1): the billing-exhausted predicate is now a
    // standalone helper so `chump --execute-gap` can classify its own
    // errors at the agent-loop boundary (not just the per-call cascade).
    // These tests lock the predicate's semantics independently of
    // `should_cascade_on_error_string` so a future refactor of the
    // composite predicate can't silently regress the
    // billing-exhausted-only contract.
    #[test]
    fn billing_predicate_matches_402_only_on_billing_class() {
        // Real 2026-05-02 dispatch incident string (INFRA-302):
        let dispatch_402 = "Local API error 402 Payment Required: {\n  \"id\": \"ohYGX6i-2kFHot-9f5b21e0e8bcaf3a\",\n  \"error\": {\n    \"message\": \"Credit limit exceeded, please [add credits](https://api.together.ai/settings/billing).\",\n    \"type\": \"credit_limit\"\n  }\n}";
        assert!(is_billing_exhausted_error_string(dispatch_402));

        // OpenAI quota exhaustion (returned as 429 not 402, but still
        // billing-class via the type field):
        assert!(is_billing_exhausted_error_string(
            "{\"error\": {\"type\": \"insufficient_quota\"}}"
        ));
        assert!(is_billing_exhausted_error_string("CREDIT_LIMIT"));
        assert!(is_billing_exhausted_error_string("payment required"));
        assert!(is_billing_exhausted_error_string("billing exhausted"));

        // Negative cases — must NOT misclassify rate-limit / access-denied /
        // tool-format / network as billing-class. `should_cascade_on_error_string`
        // would still cascade on these; the orchestrator-level cascade-respawn
        // (future PR) will treat billing-exhaustion specifically (e.g. don't
        // retry the same provider after a backoff — switch routing-table
        // candidate).
        assert!(!is_billing_exhausted_error_string(
            "HTTP 429 Too Many Requests"
        ));
        assert!(!is_billing_exhausted_error_string("HTTP 401 Unauthorized"));
        assert!(!is_billing_exhausted_error_string(
            "HTTP 500 Internal Server Error"
        ));
        assert!(!is_billing_exhausted_error_string("Connection refused"));
        assert!(!is_billing_exhausted_error_string("tool_use_failed"));
        // 4029 contains the substring "402" — verify we don't false-positive.
        // (The current implementation DOES match "402" as a substring, so this
        // is documenting the known sharp edge: callers that build error
        // strings from arbitrary integers should use a structured discriminator.
        // For HTTP-status-bearing strings the current substring match is
        // adequate — HTTP 4029 is not a real status code.)
        assert!(is_billing_exhausted_error_string("HTTP 4029 (synthetic)"));
    }
}
