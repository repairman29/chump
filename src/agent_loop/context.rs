use crate::agent_loop::{AgentEvent, AgentSession, EventSender};
use std::time::Instant;

pub struct AgentLoopContext {
    pub request_id: String,
    pub turn_start: Instant,
    pub session: AgentSession,
    pub event_tx: Option<EventSender>,
    pub light: bool,
    /// INFRA-185: per-phase wall-clock accumulators for the current turn.
    /// Updated by orchestrator (compaction) and iteration_controller (LLM,
    /// tools); summed and emitted as a structured `tracing::info` event at
    /// turn end. Always present; populated only when [`phase_timing_enabled`]
    /// is true, so the cost when disabled is just `Instant::now()` deltas
    /// being thrown away.
    pub phase_timings: PhaseTimings,
}

/// INFRA-185: phase-level wall-clock counters for one agent turn.
///
/// We record total ms spent in the three coarse phases that dominate
/// real-world latency on local-model setups:
///
/// - `compaction_ms` — `session_compact::maybe_compact` pre-LLM call (can
///   itself be an LLM call summarizing old turns; was identified as a
///   silent stall in the INFRA-183 PWA-latency probe).
/// - `provider_ms` — accumulated time inside `provider.complete()`. Sum
///   across all rounds in the turn (each tool round = one more LLM call).
/// - `tools_ms` — accumulated time inside tool execution (`tool_runner`).
///   Sum across all batches in the turn.
///
/// `rounds` counts how many LLM round-trips the controller made, so the
/// emitted event lets you compute average per-round provider latency.
///
/// At end of turn, the orchestrator emits one structured `tracing::info`
/// event with all four fields plus the total turn ms, so you can attribute
/// where the time went without trawling per-span enter/exit logs.
#[derive(Default, Debug, Clone)]
pub struct PhaseTimings {
    pub compaction_ms: u128,
    pub provider_ms: u128,
    pub tools_ms: u128,
    pub rounds: u32,
}

impl PhaseTimings {
    /// Sum of all measured phases. Excludes "other" (event dispatch,
    /// session save, perception, etc.) — the un-attributed remainder is
    /// implicit in `total_ms - phases_total_ms` at log time.
    pub fn phases_total_ms(&self) -> u128 {
        self.compaction_ms + self.provider_ms + self.tools_ms
    }
}

/// INFRA-185: returns true unless `CHUMP_PHASE_TIMING=0` / `false`.
/// Default-on so phase numbers show up in logs out of the box.
pub fn phase_timing_enabled() -> bool {
    !std::env::var("CHUMP_PHASE_TIMING")
        .map(|v| v == "0" || v.eq_ignore_ascii_case("false"))
        .unwrap_or(false)
}

impl AgentLoopContext {
    pub fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
    }

    /// INFRA-185: time a phase if [`phase_timing_enabled`], otherwise just
    /// run the body. Returns whatever the closure returns. Adds the
    /// elapsed ms to the phase counter via `accum`.
    pub async fn time_phase<T, F, Fut>(&mut self, accum: fn(&mut PhaseTimings, u128), body: F) -> T
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        if !phase_timing_enabled() {
            return body().await;
        }
        let start = Instant::now();
        let out = body().await;
        accum(&mut self.phase_timings, start.elapsed().as_millis());
        out
    }
}

#[cfg(test)]
mod tests {
    //! `AgentLoopContext::send` is the hot path every tool call goes through.
    //! Two invariants worth guarding:
    //!   1. Sending with no subscriber (no `event_tx`) must not panic — the
    //!      CLI and tests both construct contexts without a channel.
    //!   2. Sending with a subscriber actually enqueues. If the channel is
    //!      full / closed, the failure is swallowed silently (we don't want
    //!      one dropped event to kill the turn), which is why we test the
    //!      success case explicitly.

    use super::*;
    use crate::agent_loop::AgentSession;
    use tokio::sync::mpsc;

    fn ctx_with(tx: Option<EventSender>) -> AgentLoopContext {
        AgentLoopContext {
            request_id: "req-1".to_string(),
            turn_start: Instant::now(),
            session: AgentSession::new("test-session".to_string()),
            event_tx: tx,
            light: false,
            phase_timings: PhaseTimings::default(),
        }
    }

    // ── INFRA-185: PhaseTimings tests ─────────────────────────────────

    #[test]
    fn phase_timings_default_is_zero() {
        let t = PhaseTimings::default();
        assert_eq!(t.compaction_ms, 0);
        assert_eq!(t.provider_ms, 0);
        assert_eq!(t.tools_ms, 0);
        assert_eq!(t.rounds, 0);
        assert_eq!(t.phases_total_ms(), 0);
    }

    #[test]
    fn phase_timings_total_sums_three_phases() {
        let t = PhaseTimings {
            compaction_ms: 150,
            provider_ms: 2500,
            tools_ms: 700,
            rounds: 3,
        };
        assert_eq!(t.phases_total_ms(), 3350);
    }

    // ENV-coupled tests are racy under cargo's default test parallelism
    // (env vars are process-global). Use #[serial] so the enabled and
    // disabled cases never overlap.
    #[tokio::test]
    #[serial_test::serial]
    async fn time_phase_accumulates_into_provider_when_enabled() {
        // Make sure no leftover CHUMP_PHASE_TIMING=0 from a previous test.
        std::env::remove_var("CHUMP_PHASE_TIMING");
        let mut ctx = ctx_with(None);
        let result = ctx
            .time_phase(
                |t, ms| t.provider_ms += ms,
                || async {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    "ok"
                },
            )
            .await;
        assert_eq!(result, "ok");
        // At least the 10 ms we slept; allow up to 500 ms for CI scheduler noise.
        assert!(
            (8..=500).contains(&(ctx.phase_timings.provider_ms as u64)),
            "expected ~10 ms provider time, got {}",
            ctx.phase_timings.provider_ms
        );
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn time_phase_skips_accumulation_when_disabled() {
        let prev = std::env::var("CHUMP_PHASE_TIMING").ok();
        std::env::set_var("CHUMP_PHASE_TIMING", "0");
        let mut ctx = ctx_with(None);
        let _ = ctx
            .time_phase(
                |t, ms| t.compaction_ms += ms,
                || async {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                },
            )
            .await;
        assert_eq!(
            ctx.phase_timings.compaction_ms, 0,
            "phase timing was disabled but compaction_ms accumulated anyway"
        );
        match prev {
            Some(v) => std::env::set_var("CHUMP_PHASE_TIMING", v),
            None => std::env::remove_var("CHUMP_PHASE_TIMING"),
        }
    }

    #[tokio::test]
    async fn send_with_no_channel_does_not_panic() {
        let ctx = ctx_with(None);
        // Any event — a text delta is the simplest.
        ctx.send(AgentEvent::TextDelta {
            delta: "hello".into(),
        });
        // If we got here without unwinding, the invariant holds.
    }

    #[tokio::test]
    async fn send_with_channel_enqueues_event() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let ctx = ctx_with(Some(tx));
        ctx.send(AgentEvent::TextDelta {
            delta: "first".into(),
        });
        ctx.send(AgentEvent::TextDelta {
            delta: "second".into(),
        });

        // Collect what was enqueued.
        let first = rx.recv().await.expect("first event delivered");
        let second = rx.recv().await.expect("second event delivered");
        match first {
            AgentEvent::TextDelta { delta } => assert_eq!(delta, "first"),
            e => panic!("unexpected first event: {:?}", e),
        }
        match second {
            AgentEvent::TextDelta { delta } => assert_eq!(delta, "second"),
            e => panic!("unexpected second event: {:?}", e),
        }
    }

    #[tokio::test]
    async fn send_swallows_closed_channel_errors() {
        let (tx, rx) = mpsc::unbounded_channel();
        drop(rx); // channel closed; next send will return Err.
        let ctx = ctx_with(Some(tx));
        // Must not panic even though the receiver is gone. The agent loop
        // can't recover from a dropped SSE consumer mid-turn, but a panic
        // would kill the turn entirely.
        ctx.send(AgentEvent::TextDelta {
            delta: "into the void".into(),
        });
    }
}
