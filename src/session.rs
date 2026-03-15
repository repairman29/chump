//! Typestate session lifecycle: Uninitialized → Ready → Running → Closed.
//! Only Session<Ready> can start() → Running; only Session<Running> can close() → Closed.
//! Prevents double-close and tools-before-assemble at compile time.

use crate::context_assembly;

/// Marker trait for valid session states.
pub trait SessionState: private::Sealed {}

/// Session has not yet assembled context.
pub struct Uninitialized;
impl SessionState for Uninitialized {}

/// Context assembled; ready to start the run.
pub struct Ready;
impl SessionState for Ready {}

/// Run in progress; can execute tools, then close.
pub struct Running;
impl SessionState for Running {}

/// Session closed; no further operations.
pub struct Closed;
impl SessionState for Closed {}

mod private {
    use super::{Closed, Ready, Running, Uninitialized};
    pub trait Sealed {}
    impl Sealed for Uninitialized {}
    impl Sealed for Ready {}
    impl Sealed for Running {}
    impl Sealed for Closed {}
}

/// Typed session; state is encoded in the type parameter.
pub struct Session<S: SessionState> {
    _state: std::marker::PhantomData<S>,
    /// Stored when transitioning to Ready; used to build system prompt.
    context: Option<String>,
}

impl Session<Uninitialized> {
    /// Create a new session (uninitialized).
    pub fn new() -> Self {
        Session {
            _state: std::marker::PhantomData,
            context: None,
        }
    }

    /// Assemble context and transition to Ready. Call once before building the agent prompt.
    pub fn assemble(self) -> Session<Ready> {
        let context = context_assembly::assemble_context();
        Session {
            _state: std::marker::PhantomData,
            context: Some(context),
        }
    }
}

impl Default for Session<Uninitialized> {
    fn default() -> Self {
        Self::new()
    }
}

impl Session<Ready> {
    /// Return the assembled context string for the system prompt.
    pub fn context_str(&self) -> &str {
        self.context.as_deref().unwrap_or("")
    }

    /// Start the run; transition to Running. Call when entering the agent loop.
    pub fn start(self) -> Session<Running> {
        Session {
            _state: std::marker::PhantomData,
            context: self.context,
        }
    }
}

impl Session<Running> {
    /// Close the session (increment session_count, commit brain, log). Call once at end of run.
    /// Consumes self so close() cannot be called twice.
    pub fn close(self) -> Session<Closed> {
        context_assembly::close_session();
        Session {
            _state: std::marker::PhantomData,
            context: None,
        }
    }
}

impl Session<Closed> {
    /// No-op; closed session cannot do anything. Exists so callers can drop or ignore.
    #[allow(dead_code)]
    pub fn closed(&self) {}
}
