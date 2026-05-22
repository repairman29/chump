//! Error types for `chump-team`.
//!
//! Every fallible operation returns [`Result`] = `std::result::Result<T, ChumpTeamError>`.

use std::fmt;

#[derive(Debug)]
pub enum ChumpTeamError {
    /// A required env var was unset.
    MissingEnv(&'static str),
    /// HTTP request failed at the transport layer (DNS, TLS, connection refused).
    /// Callers that care about offline-degradation match on this.
    Transport(reqwest::Error),
    /// HTTP request returned a non-2xx response.
    Http { status: u16, body: String },
    /// JSON serialization / deserialization failed.
    Serde(serde_json::Error),
    /// Database constraint violation surfaced through PostgREST (e.g. unique
    /// index conflict on the active-claim partial unique index — this is
    /// the "you lost the CAS race" signal).
    Conflict { table: &'static str, detail: String },
    /// Auth refused (401 or 403). Either the JWT expired or RLS rejected.
    Unauthorized(String),
    /// Catch-all for anything else.
    Other(anyhow::Error),
}

pub type Result<T> = std::result::Result<T, ChumpTeamError>;

impl fmt::Display for ChumpTeamError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingEnv(name) => write!(f, "missing env var: {name}"),
            Self::Transport(e) => write!(f, "transport: {e}"),
            Self::Http { status, body } => write!(f, "http {status}: {body}"),
            Self::Serde(e) => write!(f, "serde: {e}"),
            Self::Conflict { table, detail } => {
                write!(f, "conflict on {table}: {detail}")
            }
            Self::Unauthorized(msg) => write!(f, "unauthorized: {msg}"),
            Self::Other(e) => write!(f, "other: {e}"),
        }
    }
}

impl std::error::Error for ChumpTeamError {}

impl From<reqwest::Error> for ChumpTeamError {
    fn from(e: reqwest::Error) -> Self {
        Self::Transport(e)
    }
}

impl From<serde_json::Error> for ChumpTeamError {
    fn from(e: serde_json::Error) -> Self {
        Self::Serde(e)
    }
}

impl From<anyhow::Error> for ChumpTeamError {
    fn from(e: anyhow::Error) -> Self {
        Self::Other(e)
    }
}

impl ChumpTeamError {
    /// Returns true if the error indicates the team server was unreachable
    /// (rather than reachable-but-rejecting). Callers fall back to local
    /// state.db when this is true.
    pub fn is_transport(&self) -> bool {
        matches!(self, Self::Transport(_))
    }
}
