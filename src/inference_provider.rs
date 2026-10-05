//! Provider chain: deterministic multi-model fallback executor.
//!
//! Vendored from repairman29/ai-gm-service at commit
//! ae59750d39cef0daa15a88131db9de914dfa0b4b (2026-05-23).
//!
//! Original source:
//!   src/services/aiGMMultiModelEnsembleService.js (model priority + dispatch)
//!   src/services/togetherAIService.js              (Together.ai client shape)
//!   src/services/npcAgentCostOptimized.js          (tier + iteration pattern)
//!   src/aiGMAPI.js:268-283                         (rate-limit retry helper)
//!
//! Cross-pollination brief: docs/arsenal/cross-pollination/CP-012-ai-gm-ensemble.md
//! INFRA-1844 (implementing gap).
//!
//! Rebuilt in Rust, not a JS import — see the brief for the full error-class
//! table this module implements. This is the Neocortex-tier executor for the
//! bicameral router (CP-011); intra-chain resilience only, tier selection is
//! the router's job. Also the Provider::NeuralFarm variant makes CP-001
//! neural-farm a selectable provider in the chain (see AC 9).

use std::path::Path;
use std::time::Duration;

/// Ordered, lowest-cost-first list of providers plus retry/backoff policy.
pub struct ProviderChain {
    pub providers: Vec<Provider>,
    pub retry_policy: RetryPolicy,
    pub criticality: Criticality,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Criticality {
    Critical,
    Background,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Provider {
    Anthropic {
        model: String,
        api_key_env: String,
    },
    OpenAI {
        model: String,
        api_key_env: String,
    },
    Together {
        model: String,
        api_key_env: String,
        base_url: String,
    },
    Mistral {
        model: String,
        api_key_env: String,
    },
    Ollama {
        model: String,
        base_url: String,
    },
    NeuralFarm {
        model: String,
        base_url: String,
    },
}

impl Provider {
    pub fn name(&self) -> &'static str {
        match self {
            Provider::Anthropic { .. } => "anthropic",
            Provider::OpenAI { .. } => "openai",
            Provider::Together { .. } => "together",
            Provider::Mistral { .. } => "mistral",
            Provider::Ollama { .. } => "ollama",
            Provider::NeuralFarm { .. } => "neural-farm",
        }
    }

    /// Build the default provider for a name, honoring
    /// `CHUMP_PROVIDER_<NAME>_MODEL` / `_BASE_URL` overrides.
    pub fn from_name(name: &str) -> Option<Provider> {
        let upper = name.to_ascii_uppercase().replace('-', "_");
        let model_env = format!("CHUMP_PROVIDER_{upper}_MODEL");
        let base_url_env = format!("CHUMP_PROVIDER_{upper}_BASE_URL");
        let model =
            |default: &str| std::env::var(&model_env).unwrap_or_else(|_| default.to_string());
        let base_url =
            |default: &str| std::env::var(&base_url_env).unwrap_or_else(|_| default.to_string());

        match name.trim().to_ascii_lowercase().as_str() {
            "anthropic" => Some(Provider::Anthropic {
                model: model("claude-opus-4-5-20251101"),
                api_key_env: "ANTHROPIC_API_KEY".to_string(),
            }),
            "openai" => Some(Provider::OpenAI {
                model: model("gpt-4o-mini"),
                api_key_env: "OPENAI_API_KEY".to_string(),
            }),
            "together" => Some(Provider::Together {
                model: model("Qwen/Qwen2.5-72B-Instruct-Turbo"),
                api_key_env: "TOGETHER_API_KEY".to_string(),
                base_url: base_url("https://api.together.xyz/v1"),
            }),
            "mistral" => Some(Provider::Mistral {
                model: model("mistral-large-latest"),
                api_key_env: "MISTRAL_API_KEY".to_string(),
            }),
            "ollama" => Some(Provider::Ollama {
                model: model("llama3"),
                base_url: base_url("http://localhost:11434/v1"),
            }),
            "neural-farm" | "neural_farm" => Some(Provider::NeuralFarm {
                model: model("neural-farm-default"),
                base_url: base_url("http://localhost:8080/v1"),
            }),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub rate_limit_max_retries: u8,
    pub transient_max_retries: u8,
    pub rate_limit_backoff_base: Duration,
    pub rate_limit_backoff_cap: Duration,
    pub transient_backoff_step: Duration,
    pub request_timeout: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        RetryPolicy {
            rate_limit_max_retries: 3,
            transient_max_retries: 2,
            rate_limit_backoff_base: Duration::from_secs(2),
            rate_limit_backoff_cap: Duration::from_secs(30),
            transient_backoff_step: Duration::from_secs(1),
            request_timeout: Duration::from_secs(30),
        }
    }
}

/// Classification of a single provider attempt's outcome, mirroring the
/// error-class table in CP-012-ai-gm-ensemble.md.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttemptError {
    AuthFailed,
    ModelNotFound,
    RateLimited {
        retry_after: Option<Duration>,
    },
    Transient5xx,
    Timeout,
    ContentRefusal,
    /// Fatal — do not fall back, return to caller immediately.
    InvalidPrompt(String),
}

impl AttemptError {
    fn fallback_reason(&self) -> &'static str {
        match self {
            AttemptError::AuthFailed => "auth_failed",
            AttemptError::ModelNotFound => "model_not_found",
            AttemptError::RateLimited { .. } => "rate_limit_exhausted",
            AttemptError::Transient5xx => "5xx_persistent",
            AttemptError::Timeout => "timeout",
            AttemptError::ContentRefusal => "content_refusal",
            AttemptError::InvalidPrompt(_) => "invalid_prompt",
        }
    }

    fn is_fatal(&self) -> bool {
        matches!(self, AttemptError::InvalidPrompt(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChainError {
    InvalidPrompt(String),
    AllProvidersFailed { attempts: usize },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    pub provider: String,
    pub model: String,
    pub text: String,
}

/// Single attempt against one provider. Implementations decide how to
/// actually reach the provider (HTTP call, local process, etc); the chain
/// only needs `Ok(Completion)` or a classified `AttemptError`.
pub trait ProviderClient {
    fn call(&self, provider: &Provider, prompt: &str) -> Result<Completion, AttemptError>;
}

impl ProviderChain {
    /// Parse `CHUMP_PROVIDER_CHAIN` (comma-separated provider names).
    /// Unknown names are dropped with a `provider_chain_unknown` ambient
    /// emission (not fatal). Empty/unset falls back to the compile-time
    /// default `[anthropic, openai, ollama]`.
    pub fn from_env(repo_root: &Path) -> ProviderChain {
        let raw = std::env::var("CHUMP_PROVIDER_CHAIN").unwrap_or_default();
        let mut providers: Vec<Provider> = Vec::new();
        for name in raw.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()) {
            match Provider::from_name(name) {
                Some(p) => providers.push(p),
                None => emit_unknown(repo_root, name),
            }
        }
        if providers.is_empty() {
            providers = vec![
                Provider::from_name("anthropic").unwrap(),
                Provider::from_name("openai").unwrap(),
                Provider::from_name("ollama").unwrap(),
            ];
        }

        let criticality = match std::env::var("CHUMP_PROVIDER_CALL_CRITICALITY").as_deref() {
            Ok("background") => Criticality::Background,
            _ => Criticality::Critical,
        };

        ProviderChain {
            providers,
            retry_policy: RetryPolicy::default(),
            criticality,
        }
    }

    /// Walk the chain, retrying transient/rate-limit errors on the same
    /// provider before falling back to the next one. Emits
    /// `kind=provider_fallback` on every non-fatal hop and
    /// `kind=provider_chain_exhausted` if every provider is exhausted.
    pub fn execute(
        &self,
        client: &dyn ProviderClient,
        prompt: &str,
        repo_root: &Path,
    ) -> Result<Completion, ChainError> {
        let mut tried = Vec::new();
        for (idx, provider) in self.providers.iter().enumerate() {
            tried.push(provider.name().to_string());
            match self.try_provider(client, provider, prompt) {
                Ok(completion) => return Ok(completion),
                Err(e) if e.is_fatal() => {
                    return Err(match e {
                        AttemptError::InvalidPrompt(msg) => ChainError::InvalidPrompt(msg),
                        _ => unreachable!(),
                    });
                }
                Err(e) => {
                    let to = self.providers.get(idx + 1).map(|p| p.name());
                    emit_fallback(repo_root, provider.name(), to, e.fallback_reason(), idx + 1);
                    continue;
                }
            }
        }
        emit_exhausted(repo_root, &tried);
        Err(ChainError::AllProvidersFailed {
            attempts: self.providers.len(),
        })
    }

    /// Retry a single provider per `retry_policy`, returning the final
    /// classified error if every retry is exhausted.
    fn try_provider(
        &self,
        client: &dyn ProviderClient,
        provider: &Provider,
        prompt: &str,
    ) -> Result<Completion, AttemptError> {
        let mut rate_limit_attempts = 0u8;
        let mut transient_attempts = 0u8;
        loop {
            match client.call(provider, prompt) {
                Ok(c) => return Ok(c),
                Err(e) if e.is_fatal() => return Err(e),
                Err(AttemptError::RateLimited { retry_after }) => {
                    let ceiling = self.retry_policy.rate_limit_backoff_cap;
                    let exceeds_ceiling = retry_after.map(|d| d > ceiling).unwrap_or(false);
                    if exceeds_ceiling
                        || rate_limit_attempts >= self.retry_policy.rate_limit_max_retries
                    {
                        return Err(AttemptError::RateLimited { retry_after });
                    }
                    rate_limit_attempts += 1;
                    continue;
                }
                Err(AttemptError::Transient5xx) => {
                    if transient_attempts >= self.retry_policy.transient_max_retries {
                        return Err(AttemptError::Transient5xx);
                    }
                    transient_attempts += 1;
                    continue;
                }
                Err(e) => return Err(e),
            }
        }
    }
}

/// Bicameral-router tier (CP-011, INFRA-1843). `ProviderChain` is the
/// intra-tier resilience executor; `Tier` is the forward-compatible knob the
/// CP-011 router will select once it lands — see docs/arsenal/
/// cross-pollination/CP-011-bicameral-mind.md "Convergence with CP-012".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Reflexive,
    Neocortex,
    Emergency,
}

impl Tier {
    /// Default chain-order env var name for this tier, honoring an explicit
    /// override per tier (`CHUMP_PROVIDER_CHAIN_REFLEXIVE` etc.) before
    /// falling back to the shared `CHUMP_PROVIDER_CHAIN`.
    pub fn env_var(&self) -> &'static str {
        match self {
            Tier::Reflexive => "CHUMP_PROVIDER_CHAIN_REFLEXIVE",
            Tier::Neocortex => "CHUMP_PROVIDER_CHAIN",
            Tier::Emergency => "CHUMP_PROVIDER_CHAIN_EMERGENCY",
        }
    }

    pub fn default_names(&self) -> &'static [&'static str] {
        match self {
            Tier::Reflexive => &["ollama", "neural-farm"],
            Tier::Neocortex => &["anthropic", "openai", "together"],
            Tier::Emergency => &["ollama"],
        }
    }

    /// Build the `ProviderChain` for this tier: explicit per-tier env var if
    /// set, else the tier's compiled default (not the global fallback used
    /// by `ProviderChain::from_env`, since Reflexive/Emergency chains must
    /// never silently default to cloud providers).
    pub fn chain(&self, repo_root: &Path) -> ProviderChain {
        let raw = std::env::var(self.env_var()).unwrap_or_default();
        let names: Vec<&str> = raw
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        let names: Vec<&str> = if names.is_empty() {
            self.default_names().to_vec()
        } else {
            names
        };
        let mut providers = Vec::new();
        for name in names {
            match Provider::from_name(name) {
                Some(p) => providers.push(p),
                None => emit_unknown(repo_root, name),
            }
        }
        ProviderChain {
            providers,
            retry_policy: RetryPolicy::default(),
            criticality: Criticality::Critical,
        }
    }
}

/// Scenario-scripted `ProviderClient` for the CLI smoke-test entry point
/// (`chump provider-chain simulate`) and `scripts/ci/test-provider-chain.sh`.
/// Not `#[cfg(test)]` — the CLI subcommand needs it in release builds too.
pub mod testing {
    use super::*;

    pub struct ScenarioClient {
        scenario: String,
    }

    impl ScenarioClient {
        pub fn new(scenario: &str) -> Self {
            ScenarioClient {
                scenario: scenario.to_string(),
            }
        }
    }

    fn ok_completion(provider: &Provider) -> Completion {
        Completion {
            provider: provider.name().to_string(),
            model: "mock-model".to_string(),
            text: "mock completion".to_string(),
        }
    }

    impl ProviderClient for ScenarioClient {
        /// Position-in-chain is inferred from `provider`; the first
        /// provider in each scenario is treated as "primary", any other as
        /// "fallback" (which always succeeds, so a scenario's expected
        /// outcome is always reachable within one hop).
        fn call(&self, provider: &Provider, _prompt: &str) -> Result<Completion, AttemptError> {
            let is_primary = provider.name() != "openai" && provider.name() != "ollama-fallback";
            match self.scenario.as_str() {
                "happy" => Ok(ok_completion(provider)),
                "auth_fail" => {
                    if is_primary {
                        Err(AttemptError::AuthFailed)
                    } else {
                        Ok(ok_completion(provider))
                    }
                }
                "rate_limit_exhausted" => {
                    if is_primary {
                        Err(AttemptError::RateLimited {
                            retry_after: Some(Duration::from_secs(600)),
                        })
                    } else {
                        Ok(ok_completion(provider))
                    }
                }
                "transient_5xx" => {
                    if is_primary {
                        Err(AttemptError::Transient5xx)
                    } else {
                        Ok(ok_completion(provider))
                    }
                }
                "timeout" => {
                    if is_primary {
                        Err(AttemptError::Timeout)
                    } else {
                        Ok(ok_completion(provider))
                    }
                }
                "content_refusal" => {
                    if is_primary {
                        Err(AttemptError::ContentRefusal)
                    } else {
                        Ok(ok_completion(provider))
                    }
                }
                "invalid_prompt" => Err(AttemptError::InvalidPrompt(
                    "mock invalid prompt".to_string(),
                )),
                "chain_exhausted" => Err(AttemptError::Transient5xx),
                _ => Ok(ok_completion(provider)),
            }
        }
    }
}

fn ambient_path(repo_root: &Path) -> std::path::PathBuf {
    repo_root.join(".chump-locks/ambient.jsonl")
}

fn append_ambient(repo_root: &Path, line: &str) {
    let path = ambient_path(repo_root);
    let _ = std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

fn utc_now_iso8601() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// `kind=provider_fallback`. Fields: from_provider, to_provider, reason,
/// attempt_count.
fn emit_fallback(
    repo_root: &Path,
    from: &str,
    to: Option<&str>,
    reason: &str,
    attempt_count: usize,
) {
    let ts = utc_now_iso8601();
    let to_json = match to {
        Some(t) => format!("\"{t}\""),
        None => "null".to_string(),
    };
    let line = format!(
        r#"{{"ts":"{ts}","kind":"provider_fallback","from_provider":"{from}","to_provider":{to_json},"reason":"{reason}","attempt_count":{attempt_count}}}"#,
    );
    append_ambient(repo_root, &line);
}

/// `kind=provider_chain_exhausted`. Fields: providers_tried.
fn emit_exhausted(repo_root: &Path, tried: &[String]) {
    let ts = utc_now_iso8601();
    let list = tried
        .iter()
        .map(|p| format!("\"{p}\""))
        .collect::<Vec<_>>()
        .join(",");
    let line =
        format!(r#"{{"ts":"{ts}","kind":"provider_chain_exhausted","providers_tried":[{list}]}}"#,);
    append_ambient(repo_root, &line);
}

/// `kind=provider_chain_unknown`. Fields: name.
fn emit_unknown(repo_root: &Path, name: &str) {
    let ts = utc_now_iso8601();
    let line = format!(r#"{{"ts":"{ts}","kind":"provider_chain_unknown","name":"{name}"}}"#);
    append_ambient(repo_root, &line);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// Scripted client: each provider name maps to a queue of outcomes,
    /// popped in order on successive calls.
    struct ScriptedClient {
        scripts: RefCell<HashMap<&'static str, Vec<Result<Completion, AttemptError>>>>,
    }

    impl ScriptedClient {
        fn new(scripts: Vec<(&'static str, Vec<Result<Completion, AttemptError>>)>) -> Self {
            ScriptedClient {
                scripts: RefCell::new(scripts.into_iter().collect()),
            }
        }
    }

    impl ProviderClient for ScriptedClient {
        fn call(&self, provider: &Provider, _prompt: &str) -> Result<Completion, AttemptError> {
            let mut scripts = self.scripts.borrow_mut();
            let queue = scripts
                .get_mut(provider.name())
                .expect("no script for provider");
            queue.remove(0)
        }
    }

    fn ok(provider: &str) -> Result<Completion, AttemptError> {
        Ok(Completion {
            provider: provider.to_string(),
            model: "mock-model".to_string(),
            text: "hi".to_string(),
        })
    }

    fn chain(names: &[&str]) -> ProviderChain {
        ProviderChain {
            providers: names
                .iter()
                .map(|n| Provider::from_name(n).unwrap())
                .collect(),
            retry_policy: RetryPolicy::default(),
            criticality: Criticality::Critical,
        }
    }

    fn tmp_repo() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn happy_path_first_provider() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![("anthropic", vec![ok("anthropic")])]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "anthropic");
    }

    #[test]
    fn auth_fail_falls_back_immediately() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            ("anthropic", vec![Err(AttemptError::AuthFailed)]),
            ("openai", vec![ok("openai")]),
        ]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "openai");
        let ambient =
            std::fs::read_to_string(repo.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"kind\":\"provider_fallback\""));
        assert!(ambient.contains("\"reason\":\"auth_failed\""));
        assert!(ambient.contains("\"from_provider\":\"anthropic\""));
        assert!(ambient.contains("\"to_provider\":\"openai\""));
    }

    #[test]
    fn rate_limit_retries_then_recovers_same_provider() {
        let repo = tmp_repo();
        let c = chain(&["anthropic"]);
        let client = ScriptedClient::new(vec![(
            "anthropic",
            vec![
                Err(AttemptError::RateLimited {
                    retry_after: Some(Duration::from_secs(1)),
                }),
                Err(AttemptError::RateLimited {
                    retry_after: Some(Duration::from_secs(1)),
                }),
                ok("anthropic"),
            ],
        )]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "anthropic");
        let ambient_path = repo.path().join(".chump-locks/ambient.jsonl");
        assert!(
            !ambient_path.exists() || std::fs::read_to_string(&ambient_path).unwrap().is_empty()
        );
    }

    #[test]
    fn rate_limit_exhausted_falls_back() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            (
                "anthropic",
                vec![
                    Err(AttemptError::RateLimited {
                        retry_after: Some(Duration::from_secs(1)),
                    });
                    4
                ],
            ),
            ("openai", vec![ok("openai")]),
        ]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "openai");
        let ambient =
            std::fs::read_to_string(repo.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"reason\":\"rate_limit_exhausted\""));
    }

    #[test]
    fn transient_5xx_persistent_falls_back() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            ("anthropic", vec![Err(AttemptError::Transient5xx); 3]),
            ("openai", vec![ok("openai")]),
        ]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "openai");
        let ambient =
            std::fs::read_to_string(repo.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"reason\":\"5xx_persistent\""));
    }

    #[test]
    fn timeout_falls_back() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            ("anthropic", vec![Err(AttemptError::Timeout)]),
            ("openai", vec![ok("openai")]),
        ]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "openai");
    }

    #[test]
    fn content_refusal_falls_back() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            ("anthropic", vec![Err(AttemptError::ContentRefusal)]),
            ("openai", vec![ok("openai")]),
        ]);
        let result = c.execute(&client, "hi", repo.path()).unwrap();
        assert_eq!(result.provider, "openai");
    }

    #[test]
    fn invalid_prompt_is_fatal_no_fallback() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![(
            "anthropic",
            vec![Err(AttemptError::InvalidPrompt("bad".to_string()))],
        )]);
        let err = c.execute(&client, "hi", repo.path()).unwrap_err();
        assert_eq!(err, ChainError::InvalidPrompt("bad".to_string()));
    }

    #[test]
    fn all_providers_exhausted() {
        let repo = tmp_repo();
        let c = chain(&["anthropic", "openai"]);
        let client = ScriptedClient::new(vec![
            ("anthropic", vec![Err(AttemptError::AuthFailed)]),
            ("openai", vec![Err(AttemptError::AuthFailed)]),
        ]);
        let err = c.execute(&client, "hi", repo.path()).unwrap_err();
        assert_eq!(err, ChainError::AllProvidersFailed { attempts: 2 });
        let ambient =
            std::fs::read_to_string(repo.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"kind\":\"provider_chain_exhausted\""));
        let fallback_count = ambient.matches("\"kind\":\"provider_fallback\"").count();
        assert_eq!(fallback_count, 2);
    }

    // CHUMP_PROVIDER_CHAIN is process-global; guard the two tests that
    // mutate it so they can't interleave under cargo test's default
    // multi-threaded runner.
    static ENV_GUARD: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn unknown_provider_name_dropped_not_fatal() {
        let _guard = ENV_GUARD.lock().unwrap();
        let repo = tmp_repo();
        std::env::set_var("CHUMP_PROVIDER_CHAIN", "anthropic,bogus,openai");
        let c = ProviderChain::from_env(repo.path());
        std::env::remove_var("CHUMP_PROVIDER_CHAIN");
        assert_eq!(c.providers.len(), 2);
        let ambient =
            std::fs::read_to_string(repo.path().join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(ambient.contains("\"kind\":\"provider_chain_unknown\""));
        assert!(ambient.contains("\"name\":\"bogus\""));
    }

    #[test]
    fn empty_chain_env_falls_back_to_default() {
        let _guard = ENV_GUARD.lock().unwrap();
        let repo = tmp_repo();
        std::env::remove_var("CHUMP_PROVIDER_CHAIN");
        let c = ProviderChain::from_env(repo.path());
        assert_eq!(c.providers.len(), 3);
        assert_eq!(c.providers[0].name(), "anthropic");
    }
}
