//! # chump-messaging
//!
//! Two complementary surfaces:
//!
//! 1. **`MessagingAdapter`** — pre-existing surface for human-facing
//!    chat platforms (Discord, Telegram, Slack, Matrix, PWA). See
//!    [`adapter`] module.
//!
//! 2. **`Broker`** — agent-to-agent inbox messaging substrate. Mirrors
//!    Chump's `.chump-locks/inbox/<SESSION>.jsonl` semantics. INFRA-1998
//!    Phase 1 ships the trait + [`broker::FileBroker`] concrete impl
//!    plus two CLI binaries (`chump-broadcast`, `chump-inbox`) that match
//!    the legacy `scripts/coord/broadcast.sh` + `scripts/coord/chump-inbox.sh`
//!    argument surfaces. Bash callsites stay alive behind a feature flag
//!    (`CHUMP_MESSAGING_RUST=1`) during the 1-week validation window.
//!
//! ## Phase 1 scope (INFRA-1998)
//!
//! - Trait + FileBroker (file-backed, append+fsync, atomic cursor)
//! - Two binaries
//! - Smoke test for bash-vs-Rust parity
//! - No new ambient event kinds, no edits to EVENT_REGISTRY.yaml or
//!   event-registry-reserved.txt (active sibling leases).
//!
//! ## Phase 1 non-goals
//!
//! - NatsBroker impl (META-061 / INFRA-1118 path)
//! - Inbox migration to SQLite
//! - Auto-mirror to GitHub comments (INFRA-1932 follow-up)
//! - Auto-ack contract (separate slice)
//! - Cutover removing bash bodies — Phase 2

pub mod adapter;
pub mod broker;
pub mod error;

// Re-export the pre-existing adapter surface at the crate root for
// backward compatibility with downstream callers.
pub use adapter::{
    ApprovalResponse, IncomingMessage, MessagingAdapter, MessagingHub, OutgoingMessage,
};

// Re-export the new broker surface at the crate root.
pub use broker::{
    Broker, FileBroker, InboundMessage, MessageId, MessageLevel, OutboundMessage, Urgency,
};
pub use error::BrokerError;
