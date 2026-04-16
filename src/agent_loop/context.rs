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
