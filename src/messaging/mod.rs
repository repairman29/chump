//! Re-export shim for the [`chump_messaging`] crate (extracted 2026-04-18).
//!
//! Pre-extraction this module owned the full implementation. The trait,
//! types, and MessagingHub now live in the standalone `chump-messaging`
//! crate (re-exported below). The bin-local `DiscordShim` stays here
//! because it references chump's internal `crate::discord_dm`.
//!
//! See `crates/chump-messaging/` for the implementation +
//! COMP-004 multi-platform-gateway design notes.
pub use chump_messaging::*;

pub mod discord_shim;
