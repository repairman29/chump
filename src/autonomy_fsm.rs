//! COG-009: Typestate FSM — compile-time-provable autonomy lifecycle.
//!
//! States: Planning → Executing → Verifying → Done | Failed
//!
//! Evidence tokens gate each transition. Because the token types are distinct,
//! the compiler rejects Planning→Verifying shortcuts at zero runtime cost —
//! all state values are PhantomData and optimised away by the backend.
//!
//!   let fsm = AutonomyState::<Planning>::new();
//!   // ... validate contract ...
//!   let fsm = fsm.begin_execution(PlanningComplete { .. });  // consumed
//!   // ... run executor ...
//!   let fsm = fsm.begin_verification(ExecutionReceipt { .. });
//!   // ... run verifier ...
//!   let _final = fsm.complete(VerificationOutcome { .. });   // or .fail(...)

use std::marker::PhantomData;

// ── State marker types ────────────────────────────────────────────────────────

pub struct Planning;
pub struct Executing;
pub struct Verifying;
pub struct Done;
pub struct Failed;

// ── Evidence tokens ───────────────────────────────────────────────────────────

/// Produced after task contract has been parsed and validated.
pub struct PlanningComplete {
    pub task_id: i64,
    pub has_acceptance: bool,
    pub has_verify: bool,
}

/// Produced after the executor returns a summary.
pub struct ExecutionReceipt {
    pub task_id: i64,
    pub summary: String,
}

/// Produced after the verifier runs.
pub struct VerificationOutcome {
    pub task_id: i64,
    pub status: String,
    pub detail: String,
}

// ── FSM carrier ──────────────────────────────────────────────────────────────

/// Zero-cost lifecycle wrapper: `S` is a marker type; the struct holds no data.
pub struct AutonomyState<S> {
    _state: PhantomData<S>,
}

impl Default for AutonomyState<Planning> {
    fn default() -> Self {
        Self::new()
    }
}

impl AutonomyState<Planning> {
    pub fn new() -> Self {
        AutonomyState {
            _state: PhantomData,
        }
    }

    /// Advance to Executing. Requires `PlanningComplete` evidence; no path to
    /// skip directly to `Verifying` because no such method exists.
    pub fn begin_execution(self, _evidence: PlanningComplete) -> AutonomyState<Executing> {
        AutonomyState {
            _state: PhantomData,
        }
    }

    /// Short-circuit to Failed (e.g., contract validation failed).
    pub fn fail(self) -> AutonomyState<Failed> {
        AutonomyState {
            _state: PhantomData,
        }
    }
}

impl AutonomyState<Executing> {
    /// Advance to Verifying. Requires `ExecutionReceipt`; cannot re-enter Planning.
    pub fn begin_verification(self, _receipt: ExecutionReceipt) -> AutonomyState<Verifying> {
        AutonomyState {
            _state: PhantomData,
        }
    }
}

impl AutonomyState<Verifying> {
    /// Advance to Done.
    pub fn complete(self, _outcome: VerificationOutcome) -> AutonomyState<Done> {
        AutonomyState {
            _state: PhantomData,
        }
    }

    /// Advance to Failed (verification rejected).
    pub fn fail(self, _outcome: VerificationOutcome) -> AutonomyState<Failed> {
        AutonomyState {
            _state: PhantomData,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path_compiles_and_runs() {
        let fsm = AutonomyState::<Planning>::new();
        let fsm = fsm.begin_execution(PlanningComplete {
            task_id: 1,
            has_acceptance: true,
            has_verify: true,
        });
        let fsm = fsm.begin_verification(ExecutionReceipt {
            task_id: 1,
            summary: "done".to_string(),
        });
        let _done = fsm.complete(VerificationOutcome {
            task_id: 1,
            status: "done".to_string(),
            detail: "all checks pass".to_string(),
        });
    }

    #[test]
    fn fail_path_from_planning() {
        let fsm = AutonomyState::<Planning>::new();
        let _failed = fsm.fail();
    }

    #[test]
    fn fail_path_from_verifying() {
        let fsm = AutonomyState::<Planning>::new();
        let fsm = fsm.begin_execution(PlanningComplete {
            task_id: 2,
            has_acceptance: true,
            has_verify: false,
        });
        let fsm = fsm.begin_verification(ExecutionReceipt {
            task_id: 2,
            summary: "partial".to_string(),
        });
        let _failed = fsm.fail(VerificationOutcome {
            task_id: 2,
            status: "blocked".to_string(),
            detail: "missing verify commands".to_string(),
        });
    }

    // This test would fail to compile if someone tried to shortcut Planning→Verifying:
    //
    //   fn planning_to_verifying_shortcut_rejected() {
    //       let fsm = AutonomyState::<Planning>::new();
    //       let _ = fsm.begin_verification(...);  // ERROR: no method `begin_verification`
    //   }
    //
    // The compile error IS the test.

    #[test]
    fn fsm_is_zero_sized() {
        assert_eq!(std::mem::size_of::<AutonomyState<Planning>>(), 0);
        assert_eq!(std::mem::size_of::<AutonomyState<Executing>>(), 0);
        assert_eq!(std::mem::size_of::<AutonomyState<Verifying>>(), 0);
        assert_eq!(std::mem::size_of::<AutonomyState<Done>>(), 0);
        assert_eq!(std::mem::size_of::<AutonomyState<Failed>>(), 0);
    }
}
