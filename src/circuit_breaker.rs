//! RESILIENT-011: circuit-breaker pattern for cascading fleet failures
//!
//! Implements the three-state circuit breaker pattern (Closed → Open → Half-Open → Closed)
//! to protect downstream services from cascading failures in the fleet.
//!
//! States:
//!   - Closed: normal operation, all requests pass through
//!   - Open: failure threshold exceeded, requests fail fast without attempting downstream call
//!   - Half-Open: recovering, limited probing to verify if target is healthy
//!
//! The breaker can be configured per-target via environment variables:
//!   - CHUMP_CB_ERROR_THRESHOLD (default 5): failures to trigger Open state
//!   - CHUMP_CB_SUCCESS_THRESHOLD (default 2): successes in Half-Open to close the circuit
//!   - CHUMP_CB_TIMEOUT_SECS (default 30): time before transitioning from Open to Half-Open

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// Use the ambient_emit module if available in the crate; otherwise, just log.
use crate::ambient_emit::{emit, EmitArgs};

/// Configuration for a circuit breaker, settable per-target or globally via env.
#[derive(Debug, Clone)]
pub struct CircuitBreakerConfig {
    pub error_threshold: u32,
    pub success_threshold: u32,
    pub timeout: Duration,
}

impl Default for CircuitBreakerConfig {
    fn default() -> Self {
        let error_threshold = std::env::var("CHUMP_CB_ERROR_THRESHOLD")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(5);

        let success_threshold = std::env::var("CHUMP_CB_SUCCESS_THRESHOLD")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(2);

        let timeout_secs = std::env::var("CHUMP_CB_TIMEOUT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(30);

        Self {
            error_threshold,
            success_threshold,
            timeout: Duration::from_secs(timeout_secs),
        }
    }
}

/// State of the circuit breaker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    Closed,
    Open,
    HalfOpen,
}

impl std::fmt::Display for CircuitState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => write!(f, "Closed"),
            Self::Open => write!(f, "Open"),
            Self::HalfOpen => write!(f, "HalfOpen"),
        }
    }
}

/// Metrics tracked by a single circuit breaker.
#[derive(Debug, Clone)]
struct CircuitBreakerMetrics {
    consecutive_errors: u32,
    consecutive_successes_in_half_open: u32,
    last_failure_time: Option<Instant>,
    state: CircuitState,
    transitioned_to_open_at: Option<Instant>,
}

impl Default for CircuitBreakerMetrics {
    fn default() -> Self {
        Self {
            consecutive_errors: 0,
            consecutive_successes_in_half_open: 0,
            last_failure_time: None,
            state: CircuitState::Closed,
            transitioned_to_open_at: None,
        }
    }
}

/// A circuit breaker for a single target (e.g., a fleet worker endpoint).
#[derive(Debug, Clone)]
pub struct CircuitBreaker {
    target: String,
    config: CircuitBreakerConfig,
    metrics: Arc<Mutex<CircuitBreakerMetrics>>,
}

impl CircuitBreaker {
    /// Create a new circuit breaker for a target.
    pub fn new(target: String, config: CircuitBreakerConfig) -> Self {
        Self {
            target,
            config,
            metrics: Arc::new(Mutex::new(CircuitBreakerMetrics::default())),
        }
    }

    /// Create with default configuration.
    pub fn with_defaults(target: String) -> Self {
        Self::new(target, CircuitBreakerConfig::default())
    }

    /// Get current state of the circuit breaker.
    pub fn state(&self) -> CircuitState {
        let metrics = self.metrics.lock().expect("metrics lock");
        metrics.state
    }

    /// Record a successful call. May transition Half-Open → Closed.
    pub fn record_success(&self) {
        let mut metrics = self.metrics.lock().expect("metrics lock");

        match metrics.state {
            CircuitState::Closed => {
                // In Closed state, successful calls reset the error counter.
                metrics.consecutive_errors = 0;
            }
            CircuitState::HalfOpen => {
                // In Half-Open, we're testing if the target is healthy.
                metrics.consecutive_successes_in_half_open += 1;
                if metrics.consecutive_successes_in_half_open >= self.config.success_threshold {
                    // Enough successes to consider the target recovered.
                    Self::transition_to_closed(&mut metrics, &self.target);
                }
            }
            CircuitState::Open => {
                // Ignore successes while fully Open; only Half-Open probes count.
            }
        }
    }

    /// Record a failed call. May transition Closed → Open or Open → Half-Open if timeout expired.
    pub fn record_failure(&self) {
        let mut metrics = self.metrics.lock().expect("metrics lock");

        match metrics.state {
            CircuitState::Closed => {
                metrics.consecutive_errors += 1;
                metrics.last_failure_time = Some(Instant::now());

                if metrics.consecutive_errors >= self.config.error_threshold {
                    // Error threshold exceeded, open the circuit.
                    Self::transition_to_open(&mut metrics, &self.target);
                }
            }
            CircuitState::Open => {
                // Already open; check if we should transition to Half-Open.
                if let Some(opened_at) = metrics.transitioned_to_open_at {
                    if opened_at.elapsed() >= self.config.timeout {
                        // Timeout expired, move to Half-Open for testing.
                        Self::transition_to_half_open(&mut metrics, &self.target);
                    }
                }
            }
            CircuitState::HalfOpen => {
                // In Half-Open, a failure resets us back to Open.
                Self::transition_to_open(&mut metrics, &self.target);
                metrics.consecutive_successes_in_half_open = 0;
            }
        }
    }

    /// Check if a call should be allowed. Returns true if Closed or Half-Open;
    /// false if Open (fail-fast). May auto-transition Open → Half-Open if timeout expired.
    pub fn allow_call(&self) -> bool {
        let mut metrics = self.metrics.lock().expect("metrics lock");

        match metrics.state {
            CircuitState::Closed | CircuitState::HalfOpen => true,
            CircuitState::Open => {
                // Check if timeout has elapsed.
                if let Some(opened_at) = metrics.transitioned_to_open_at {
                    if opened_at.elapsed() >= self.config.timeout {
                        Self::transition_to_half_open(&mut metrics, &self.target);
                        return true; // Allow the probing call.
                    }
                }
                false // Fail fast.
            }
        }
    }

    /// Emit an ambient event for state transition.
    fn emit_state_change_event(
        target: &str,
        from_state: CircuitState,
        to_state: CircuitState,
        reason: &str,
    ) {
        // Determine the event kind based on the transition.
        let kind = match (from_state, to_state) {
            (CircuitState::Closed, CircuitState::Open) => "circuit_breaker_opened",
            (CircuitState::HalfOpen, CircuitState::Closed) => "circuit_breaker_closed",
            _ => "circuit_breaker_state_change",
        };

        // Build the emit args for the ambient event.
        let mut fields = vec![
            ("target".to_string(), target.to_string()),
            ("reason".to_string(), reason.to_string()),
        ];

        // For general state_change events, include both states.
        if kind == "circuit_breaker_state_change" {
            fields.push(("from_state".to_string(), from_state.to_string()));
            fields.push(("to_state".to_string(), to_state.to_string()));
        }

        let args = EmitArgs {
            kind: kind.to_string(),
            fields,
            ..Default::default()
        };

        // Emit the event; if it fails, just log it (don't panic).
        if let Err(e) = emit(&args) {
            eprintln!(
                "[CircuitBreaker] failed to emit event: {} → {}: {}",
                from_state, to_state, e
            );
        }
    }

    fn transition_to_open(metrics: &mut CircuitBreakerMetrics, target: &str) {
        metrics.state = CircuitState::Open;
        metrics.transitioned_to_open_at = Some(Instant::now());
        metrics.consecutive_errors = 0;
        metrics.consecutive_successes_in_half_open = 0;
        Self::emit_state_change_event(
            target,
            CircuitState::Closed,
            CircuitState::Open,
            "error threshold exceeded",
        );
    }

    fn transition_to_half_open(metrics: &mut CircuitBreakerMetrics, target: &str) {
        metrics.state = CircuitState::HalfOpen;
        metrics.consecutive_errors = 0;
        metrics.consecutive_successes_in_half_open = 0;
        Self::emit_state_change_event(
            target,
            CircuitState::Open,
            CircuitState::HalfOpen,
            "timeout expired, probing target",
        );
    }

    fn transition_to_closed(metrics: &mut CircuitBreakerMetrics, target: &str) {
        metrics.state = CircuitState::Closed;
        metrics.consecutive_errors = 0;
        metrics.consecutive_successes_in_half_open = 0;
        metrics.transitioned_to_open_at = None;
        Self::emit_state_change_event(
            target,
            CircuitState::HalfOpen,
            CircuitState::Closed,
            "target recovered",
        );
    }
}

/// Global registry of circuit breakers, one per target.
#[derive(Debug)]
pub struct CircuitBreakerRegistry {
    breakers: Arc<Mutex<HashMap<String, CircuitBreaker>>>,
    default_config: CircuitBreakerConfig,
}

impl CircuitBreakerRegistry {
    pub fn new() -> Self {
        Self {
            breakers: Arc::new(Mutex::new(HashMap::new())),
            default_config: CircuitBreakerConfig::default(),
        }
    }

    /// Get or create a circuit breaker for a target.
    pub fn get_or_create(&self, target: String) -> CircuitBreaker {
        let mut breakers = self.breakers.lock().expect("breakers lock");
        breakers
            .entry(target.clone())
            .or_insert_with(|| CircuitBreaker::new(target, self.default_config.clone()))
            .clone()
    }

    /// Get all breakers and their current states (for monitoring/dashboards).
    pub fn snapshot(&self) -> Vec<(String, CircuitState)> {
        let breakers = self.breakers.lock().expect("breakers lock");
        breakers
            .iter()
            .map(|(target, breaker)| (target.clone(), breaker.state()))
            .collect()
    }
}

impl Default for CircuitBreakerRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_closed_state_pass_through() {
        let breaker = CircuitBreaker::with_defaults("test-target".to_string());
        assert_eq!(breaker.state(), CircuitState::Closed);
        assert!(breaker.allow_call());
    }

    #[test]
    fn test_error_threshold_transition_to_open() {
        let config = CircuitBreakerConfig {
            error_threshold: 3,
            ..Default::default()
        };
        let breaker = CircuitBreaker::new("test-target".to_string(), config);

        // Record 2 failures (below threshold).
        breaker.record_failure();
        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Closed);

        // Record 3rd failure (at threshold).
        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Open);
        assert!(!breaker.allow_call());
    }

    #[test]
    fn test_open_fails_fast() {
        let config = CircuitBreakerConfig {
            error_threshold: 1,
            timeout: Duration::from_secs(1),
            ..Default::default()
        };
        let breaker = CircuitBreaker::new("test-target".to_string(), config);

        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Open);
        assert!(!breaker.allow_call());
        assert!(!breaker.allow_call());
    }

    #[test]
    fn test_half_open_transition_and_recovery() {
        let config = CircuitBreakerConfig {
            error_threshold: 1,
            success_threshold: 2,
            timeout: Duration::from_millis(100),
        };
        let breaker = CircuitBreaker::new("test-target".to_string(), config);

        // Move to Open.
        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Open);

        // Wait for timeout.
        std::thread::sleep(Duration::from_millis(150));

        // Check allow_call triggers transition to Half-Open.
        assert!(breaker.allow_call());
        assert_eq!(breaker.state(), CircuitState::HalfOpen);

        // Record successes to recover.
        breaker.record_success();
        assert_eq!(breaker.state(), CircuitState::HalfOpen);
        breaker.record_success();
        assert_eq!(breaker.state(), CircuitState::Closed);
    }

    #[test]
    fn test_half_open_failure_reopens() {
        let config = CircuitBreakerConfig {
            error_threshold: 1,
            success_threshold: 2,
            timeout: Duration::from_millis(100),
        };
        let breaker = CircuitBreaker::new("test-target".to_string(), config);

        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Open);

        std::thread::sleep(Duration::from_millis(150));

        // Move to Half-Open.
        breaker.allow_call();
        assert_eq!(breaker.state(), CircuitState::HalfOpen);

        // Failure while Half-Open goes back to Open.
        breaker.record_failure();
        assert_eq!(breaker.state(), CircuitState::Open);
    }

    #[test]
    fn test_registry_per_target() {
        let registry = CircuitBreakerRegistry::new();

        let breaker1 = registry.get_or_create("target1".to_string());
        let breaker2 = registry.get_or_create("target2".to_string());

        breaker1.record_failure();
        breaker1.record_failure();
        breaker1.record_failure();
        breaker1.record_failure();
        breaker1.record_failure();

        assert_eq!(breaker1.state(), CircuitState::Open);
        assert_eq!(breaker2.state(), CircuitState::Closed);

        let snapshot = registry.snapshot();
        assert_eq!(snapshot.len(), 2);
    }
}
