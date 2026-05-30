//! Mission replanning policies.
//!
//! When an objective is **denied** (e.g. the HITL approval gate said no)
//! or **fails** at runtime, the orchestrator asks a [`MissionReplanner`]
//! what to do next. The replanner is a pure policy function — it returns
//! a [`ReplanStrategy`] but does not mutate the mission itself; the
//! orchestrator decides whether to honor the strategy and applies the
//! resulting state transitions through [`super::persistence::PersistentMission::checkpoint`].
//!
//! Two reasons replanning is a trait rather than a single hard-coded path:
//!
//! 1. **Per-mission policy override.** A high-stakes mission may want
//!    `HumanEscalate`; a self-healing background sweep may want
//!    `RetryWithBackoff { max_attempts: 3 }`. Both compose with the same
//!    orchestrator.
//! 2. **Testability.** A test can install a stub replanner that always
//!    returns the strategy the test cares about, without spinning up an
//!    LLM-backed reasoner.
//!
//! The default, conservative impl is [`AbortOnFailureReplanner`] — it never
//! retries and never escalates; it just aborts. Callers that want richer
//! behavior swap it out at construction time.

use serde::{Deserialize, Serialize};

use super::persistence::{Mission, Objective};

/// What the orchestrator should do for an objective that was denied or
/// failed. Replanners return one of these — they do not apply it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "strategy")]
pub enum ReplanStrategy {
    /// Stop the mission. The orchestrator should transition the failing
    /// objective to `Failed` and apply the mission-level
    /// [`super::persistence::FallbackMode`].
    Abort,
    /// Re-arm the failing objective up to `max_attempts` times. The
    /// orchestrator counts attempts by inspecting the checkpoint history
    /// for that objective.
    RetryWithBackoff { max_attempts: u32 },
    /// Replace the failing objective with a simpler, lower-cost variant
    /// (e.g. a smaller scope or a cheaper resource bucket). The
    /// orchestrator is responsible for the actual substitution.
    DegradeToSimpler,
    /// Surface the decision to a human operator via the inbox; pause the
    /// mission until the operator responds.
    HumanEscalate,
}

/// Pure policy interface — given a mission and the objective that just
/// hit trouble, what should we do?
pub trait MissionReplanner {
    /// Called when an objective was denied (HITL gate rejected, policy
    /// gate refused, etc.). The objective has not yet been executed.
    fn replan_on_denial(&self, mission: &Mission, denied: &Objective) -> ReplanStrategy;

    /// Called when an objective transitioned to `Failed` during execution.
    fn replan_on_failure(&self, mission: &Mission, failed: &Objective) -> ReplanStrategy;
}

/// Conservative default — every denial / failure aborts the mission.
///
/// This is the right impl when you have no opinion yet about what to
/// retry or escalate, because the worst it can do is stop. Richer impls
/// should be opt-in.
#[derive(Clone, Copy, Debug, Default)]
pub struct AbortOnFailureReplanner;

impl MissionReplanner for AbortOnFailureReplanner {
    fn replan_on_denial(&self, _mission: &Mission, _denied: &Objective) -> ReplanStrategy {
        ReplanStrategy::Abort
    }

    fn replan_on_failure(&self, _mission: &Mission, _failed: &Objective) -> ReplanStrategy {
        ReplanStrategy::Abort
    }
}
