//! AGT-001: Explicit `AgentState` FSM for the agent iteration loop.
//!
//! The state enum tracks which phase of the agent loop we're in. It is purely
//! bookkeeping for now — no behaviour depends on it yet. AGT-002 (cancellation)
//! will drive real interrupt logic from this state.
//!
//! Valid transitions:
//!   Idle → LlmWaiting
//!   LlmWaiting → ToolsRunning
//!   LlmWaiting → Complete          (EndTurn with no tools)
//!   ToolsRunning → LlmWaiting      (tools done, next LLM call)
//!   ToolsRunning → Complete
//!   * → Interrupted                (any state can be interrupted)
//!     Interrupted → Idle             (resume / retry)

/// Explicit state machine for one agent-loop execution.
///
/// The controller transitions through these states at each major step.
/// Invalid transitions are rejected at runtime (returning `false`) and emit
/// a `tracing::warn!` so they surface in structured logs without panicking.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentState {
    /// Loop not yet started (or reset after an `Interrupted` recovery).
    Idle,
    /// Waiting for the LLM to respond. `query` is a short human-readable
    /// description of what was sent (not the full prompt — just for logging).
    LlmWaiting { query: String },
    /// LLM returned tool-use; `pending_count` native or synthetic calls are
    /// in-flight (or about to run).
    ToolsRunning { pending_count: usize },
    /// Loop was interrupted before reaching `Complete`. `reason` describes
    /// why (e.g. "max iterations exceeded", "storm breaker tripped").
    /// `iteration` is the loop counter at the time of interruption.
    Interrupted { reason: String, iteration: u32 },
    /// Loop finished cleanly (EndTurn with no outstanding tool calls).
    Complete,
}

impl AgentState {
    /// Attempt a state transition.
    ///
    /// Returns `true` if `next` is reachable from `self` according to the
    /// defined transition table.  Returns `false` and emits a `tracing::warn!`
    /// for invalid transitions.
    pub fn transition_to(&self, next: &AgentState) -> bool {
        let valid = matches!(
            (self, next),
            // Normal forward path
            (AgentState::Idle, AgentState::LlmWaiting { .. })
            | (AgentState::LlmWaiting { .. }, AgentState::ToolsRunning { .. })
            | (AgentState::LlmWaiting { .. }, AgentState::Complete)
            | (AgentState::ToolsRunning { .. }, AgentState::LlmWaiting { .. })
            | (AgentState::ToolsRunning { .. }, AgentState::Complete)
            // Any state → Interrupted
            | (_, AgentState::Interrupted { .. })
            // Resume after interruption
            | (AgentState::Interrupted { .. }, AgentState::Idle)
        );

        if !valid {
            tracing::warn!(
                from = ?self,
                to = ?next,
                "AgentState: invalid transition attempted; ignoring"
            );
        }

        valid
    }
}

#[cfg(test)]
mod tests {
    use super::AgentState;

    fn llm() -> AgentState {
        AgentState::LlmWaiting {
            query: "test".into(),
        }
    }

    fn tools(n: usize) -> AgentState {
        AgentState::ToolsRunning { pending_count: n }
    }

    fn interrupted(iter: u32) -> AgentState {
        AgentState::Interrupted {
            reason: "test".into(),
            iteration: iter,
        }
    }

    // ── Valid transitions ──────────────────────────────────────────────────────

    #[test]
    fn idle_to_llm_waiting_is_valid() {
        assert!(AgentState::Idle.transition_to(&llm()));
    }

    #[test]
    fn llm_waiting_to_tools_running_is_valid() {
        assert!(llm().transition_to(&tools(3)));
    }

    #[test]
    fn llm_waiting_to_complete_is_valid() {
        assert!(llm().transition_to(&AgentState::Complete));
    }

    #[test]
    fn tools_running_to_llm_waiting_is_valid() {
        assert!(tools(2).transition_to(&llm()));
    }

    #[test]
    fn tools_running_to_complete_is_valid() {
        assert!(tools(1).transition_to(&AgentState::Complete));
    }

    #[test]
    fn interrupted_reachable_from_idle() {
        assert!(AgentState::Idle.transition_to(&interrupted(0)));
    }

    #[test]
    fn interrupted_reachable_from_llm_waiting() {
        assert!(llm().transition_to(&interrupted(2)));
    }

    #[test]
    fn interrupted_reachable_from_tools_running() {
        assert!(tools(5).transition_to(&interrupted(4)));
    }

    #[test]
    fn interrupted_reachable_from_complete() {
        // Unusual but permitted by "any state" rule
        assert!(AgentState::Complete.transition_to(&interrupted(99)));
    }

    #[test]
    fn interrupted_to_idle_is_valid() {
        assert!(interrupted(1).transition_to(&AgentState::Idle));
    }

    // ── Invalid transitions ────────────────────────────────────────────────────

    #[test]
    fn idle_to_complete_is_invalid() {
        assert!(!AgentState::Idle.transition_to(&AgentState::Complete));
    }

    #[test]
    fn idle_to_tools_running_is_invalid() {
        assert!(!AgentState::Idle.transition_to(&tools(1)));
    }

    #[test]
    fn complete_to_llm_waiting_is_invalid() {
        assert!(!AgentState::Complete.transition_to(&llm()));
    }

    #[test]
    fn llm_waiting_to_idle_is_invalid() {
        assert!(!llm().transition_to(&AgentState::Idle));
    }

    #[test]
    fn tools_running_to_idle_is_invalid() {
        assert!(!tools(2).transition_to(&AgentState::Idle));
    }
}
