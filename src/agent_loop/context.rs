use crate::agent_loop::{AgentEvent, AgentSession, EventSender};
use std::time::Instant;

pub struct AgentLoopContext {
    pub request_id: String,
    pub turn_start: Instant,
    pub session: AgentSession,
    pub event_tx: Option<EventSender>,
    pub light: bool,
}

impl AgentLoopContext {
    pub fn send(&self, event: AgentEvent) {
        if let Some(ref tx) = self.event_tx {
            let _ = tx.send(event);
        }
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
