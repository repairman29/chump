//! Test-only guard: tests that build a throwaway store under a temp dir must
//! not be redirected by an exported `CHUMP_STATE_DB` (ZERO-WASTE-152).

use std::sync::{Mutex, MutexGuard};

static ENV_LOCK: Mutex<()> = Mutex::new(());

pub struct StateDbIsolation {
    prev: Option<std::ffi::OsString>,
    _lock: MutexGuard<'static, ()>,
}

impl Drop for StateDbIsolation {
    fn drop(&mut self) {
        match self.prev.take() {
            Some(v) => unsafe { std::env::set_var("CHUMP_STATE_DB", v) },
            None => unsafe { std::env::remove_var("CHUMP_STATE_DB") },
        }
    }
}

/// Unset `CHUMP_STATE_DB` for the guard's lifetime so the store resolves under
/// the test's own temp dir.
pub fn isolate_state_db() -> StateDbIsolation {
    let lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let prev = std::env::var_os("CHUMP_STATE_DB");
    unsafe { std::env::remove_var("CHUMP_STATE_DB") };
    StateDbIsolation { prev, _lock: lock }
}
