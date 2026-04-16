//! Event hooks — lifecycle integration points for plugins and external tools.
//!
//! Hooks are fire-and-forget callbacks invoked at well-defined points in the agent loop.
//! They run in spawned tokio tasks by default (non-blocking). Declare `sync: true` for
//! critical hooks that must complete before the lifecycle continues (e.g. approval gates).
//!
//! Usage:
//!   let handle = register_hook("my-plugin:turn-logger", HookEvent::TurnStart, |ctx| {
//!       Box::pin(async move { tracing::info!("turn started: {:?}", ctx.request_id); })
//!   });
//!   // ...
//!   unregister_hook(handle);

use serde::Serialize;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// Lifecycle events at which hooks can fire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HookEvent {
    TurnStart,
    TurnEnd,
    ToolCallStart,
    ToolCallResult,
    ApprovalRequested,
    ApprovalResolved,
    SessionStart,
    SessionEnd,
    SkillCreated,
    SkillUpdated,
    SkillApplied,
    RegimeChanged,
    HighSurprise,
}

impl HookEvent {
    /// Snake-case label for the event, included in `HookContext.event`.
    pub fn as_str(&self) -> &'static str {
        match self {
            HookEvent::TurnStart => "turn_start",
            HookEvent::TurnEnd => "turn_end",
            HookEvent::ToolCallStart => "tool_call_start",
            HookEvent::ToolCallResult => "tool_call_result",
            HookEvent::ApprovalRequested => "approval_requested",
            HookEvent::ApprovalResolved => "approval_resolved",
            HookEvent::SessionStart => "session_start",
            HookEvent::SessionEnd => "session_end",
            HookEvent::SkillCreated => "skill_created",
            HookEvent::SkillUpdated => "skill_updated",
            HookEvent::SkillApplied => "skill_applied",
            HookEvent::RegimeChanged => "regime_changed",
            HookEvent::HighSurprise => "high_surprise",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HookContext {
    pub event: String, // e.g. "turn_start"
    pub request_id: Option<String>,
    pub session_id: Option<String>,
    pub tool_name: Option<String>,
    pub payload_json: serde_json::Value,
    pub timestamp_unix: u64,
}

impl HookContext {
    /// Build a minimal context for `event` with current unix timestamp and an empty payload.
    pub fn new(event: HookEvent) -> Self {
        Self {
            event: event.as_str().to_string(),
            request_id: None,
            session_id: None,
            tool_name: None,
            payload_json: serde_json::Value::Null,
            timestamp_unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        }
    }

    pub fn with_request_id(mut self, id: impl Into<String>) -> Self {
        self.request_id = Some(id.into());
        self
    }

    pub fn with_session_id(mut self, id: impl Into<String>) -> Self {
        self.session_id = Some(id.into());
        self
    }

    pub fn with_tool_name(mut self, name: impl Into<String>) -> Self {
        self.tool_name = Some(name.into());
        self
    }

    pub fn with_payload(mut self, payload: serde_json::Value) -> Self {
        self.payload_json = payload;
        self
    }
}

pub type HookHandle = u64;
pub type HookFuture = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;
pub type HookCallback = Arc<dyn Fn(HookContext) -> HookFuture + Send + Sync + 'static>;

struct HookEntry {
    handle: HookHandle,
    #[allow(dead_code)]
    name: String,
    event: HookEvent,
    callback: HookCallback,
    sync: bool,
}

#[derive(Default)]
struct HookRegistry {
    hooks: Vec<HookEntry>,
}

static REGISTRY: OnceLock<Mutex<HookRegistry>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static Mutex<HookRegistry> {
    REGISTRY.get_or_init(|| Mutex::new(HookRegistry::default()))
}

/// Register an asynchronous (spawned) hook for `event`. Returns a unique handle that can
/// be passed to [`unregister_hook`].
pub fn register_hook<F>(name: impl Into<String>, event: HookEvent, callback: F) -> HookHandle
where
    F: Fn(HookContext) -> HookFuture + Send + Sync + 'static,
{
    register_hook_inner(name.into(), event, Arc::new(callback), false)
}

/// Register a synchronous hook for `event`. When fired via [`fire_sync`], all matching
/// sync hooks are awaited inline before the call returns.
pub fn register_sync_hook<F>(name: impl Into<String>, event: HookEvent, callback: F) -> HookHandle
where
    F: Fn(HookContext) -> HookFuture + Send + Sync + 'static,
{
    register_hook_inner(name.into(), event, Arc::new(callback), true)
}

fn register_hook_inner(
    name: String,
    event: HookEvent,
    callback: HookCallback,
    sync: bool,
) -> HookHandle {
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    let mut reg = registry().lock().expect("hook registry poisoned");
    reg.hooks.push(HookEntry {
        handle,
        name,
        event,
        callback,
        sync,
    });
    handle
}

/// Remove a previously-registered hook. Returns true if a hook with `handle` was found.
pub fn unregister_hook(handle: HookHandle) -> bool {
    let mut reg = registry().lock().expect("hook registry poisoned");
    let before = reg.hooks.len();
    reg.hooks.retain(|h| h.handle != handle);
    reg.hooks.len() != before
}

/// Number of currently registered hooks (any event). Useful for tests and diagnostics.
pub fn hook_count() -> usize {
    registry()
        .lock()
        .map(|r| r.hooks.len())
        .unwrap_or(0)
}

/// Remove all registered hooks. Test helper.
#[cfg(test)]
fn clear_hooks() {
    if let Ok(mut reg) = registry().lock() {
        reg.hooks.clear();
    }
}

/// Snapshot the (callback, sync) pairs matching `event`. Holding the lock only for the
/// snapshot avoids invoking user callbacks while the registry mutex is held.
fn snapshot_for(event: HookEvent) -> Vec<(HookCallback, bool)> {
    registry()
        .lock()
        .map(|r| {
            r.hooks
                .iter()
                .filter(|h| h.event == event)
                .map(|h| (h.callback.clone(), h.sync))
                .collect()
        })
        .unwrap_or_default()
}

/// Fire `event` with `context` to all matching hooks. Async hooks are spawned onto the
/// current tokio runtime; sync hooks are awaited inline. Hook panics are caught and
/// logged via `tracing::warn!` so they never crash the agent loop.
pub async fn fire(event: HookEvent, context: HookContext) {
    let hooks = snapshot_for(event);
    for (cb, sync) in hooks {
        let ctx = context.clone();
        let event_label = event.as_str();
        if sync {
            run_one(cb, ctx, event_label).await;
        } else {
            tokio::spawn(async move {
                run_one(cb, ctx, event_label).await;
            });
        }
    }
}

/// Like [`fire`] but awaits *every* matching hook (sync or async) before returning. Use
/// for approval/validation paths that must complete before the lifecycle continues.
pub async fn fire_sync(event: HookEvent, context: HookContext) {
    let hooks = snapshot_for(event);
    for (cb, _sync) in hooks {
        let ctx = context.clone();
        run_one(cb, ctx, event.as_str()).await;
    }
}

async fn run_one(cb: HookCallback, ctx: HookContext, event_label: &'static str) {
    use futures_util::FutureExt;
    let fut = cb(ctx);
    match std::panic::AssertUnwindSafe(fut).catch_unwind().await {
        Ok(()) => {}
        Err(panic) => {
            let msg = if let Some(s) = panic.downcast_ref::<&'static str>() {
                (*s).to_string()
            } else if let Some(s) = panic.downcast_ref::<String>() {
                s.clone()
            } else {
                "<non-string panic payload>".to_string()
            };
            tracing::warn!(event = event_label, panic = %msg, "hook callback panicked");
        }
    }
}

/// Convenience: list events that currently have at least one registered hook.
#[allow(dead_code)]
pub fn registered_events() -> HashMap<&'static str, usize> {
    let mut out = HashMap::new();
    if let Ok(reg) = registry().lock() {
        for h in &reg.hooks {
            *out.entry(h.event.as_str()).or_insert(0) += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Mutex as StdMutex;
    use std::time::Duration;

    /// Tests share global state; serialize them.
    static TEST_LOCK: StdMutex<()> = StdMutex::new(());

    fn lock_and_clear() -> std::sync::MutexGuard<'static, ()> {
        let g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_hooks();
        g
    }

    #[tokio::test]
    async fn register_and_fire_basic_hook() {
        let _g = lock_and_clear();
        let flag = Arc::new(AtomicBool::new(false));
        let f = flag.clone();
        let handle = register_sync_hook("test:basic", HookEvent::TurnStart, move |_ctx| {
            let f = f.clone();
            Box::pin(async move {
                f.store(true, Ordering::SeqCst);
            })
        });

        fire_sync(HookEvent::TurnStart, HookContext::new(HookEvent::TurnStart)).await;
        assert!(flag.load(Ordering::SeqCst), "sync hook callback did not run");
        assert!(unregister_hook(handle));
    }

    #[tokio::test]
    async fn multiple_hooks_on_same_event_all_fire() {
        let _g = lock_and_clear();
        let count = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for i in 0..3 {
            let c = count.clone();
            handles.push(register_sync_hook(
                format!("test:multi:{}", i),
                HookEvent::ToolCallStart,
                move |_ctx| {
                    let c = c.clone();
                    Box::pin(async move {
                        c.fetch_add(1, Ordering::SeqCst);
                    })
                },
            ));
        }
        fire_sync(
            HookEvent::ToolCallStart,
            HookContext::new(HookEvent::ToolCallStart),
        )
        .await;
        assert_eq!(count.load(Ordering::SeqCst), 3);
        for h in handles {
            assert!(unregister_hook(h));
        }
    }

    #[tokio::test]
    async fn unregister_removes_hook() {
        let _g = lock_and_clear();
        let flag = Arc::new(AtomicBool::new(false));
        let f = flag.clone();
        let handle = register_sync_hook("test:unreg", HookEvent::SessionEnd, move |_ctx| {
            let f = f.clone();
            Box::pin(async move {
                f.store(true, Ordering::SeqCst);
            })
        });
        assert!(unregister_hook(handle));
        fire_sync(
            HookEvent::SessionEnd,
            HookContext::new(HookEvent::SessionEnd),
        )
        .await;
        assert!(
            !flag.load(Ordering::SeqCst),
            "callback ran after unregister"
        );
        // Second unregister returns false.
        assert!(!unregister_hook(handle));
    }

    #[tokio::test]
    async fn unknown_event_has_no_effect() {
        let _g = lock_and_clear();
        let flag = Arc::new(AtomicBool::new(false));
        let f = flag.clone();
        let _h = register_sync_hook("test:other", HookEvent::TurnStart, move |_ctx| {
            let f = f.clone();
            Box::pin(async move {
                f.store(true, Ordering::SeqCst);
            })
        });
        // Fire a different event — no matching hooks, no callback should run.
        fire_sync(HookEvent::TurnEnd, HookContext::new(HookEvent::TurnEnd)).await;
        assert!(!flag.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn sync_blocks_async_spawns() {
        let _g = lock_and_clear();
        // Sync hook flips before fire() returns.
        let sync_flag = Arc::new(AtomicBool::new(false));
        let sf = sync_flag.clone();
        let h_sync = register_sync_hook("test:sync", HookEvent::ApprovalRequested, move |_ctx| {
            let sf = sf.clone();
            Box::pin(async move {
                sf.store(true, Ordering::SeqCst);
            })
        });

        // Async hook signals via channel — observable after spawn completes.
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
        let h_async = register_hook("test:async", HookEvent::ApprovalRequested, move |_ctx| {
            let tx = tx.clone();
            Box::pin(async move {
                let _ = tx.send(());
            })
        });

        fire(
            HookEvent::ApprovalRequested,
            HookContext::new(HookEvent::ApprovalRequested),
        )
        .await;

        // Sync must have run inline.
        assert!(
            sync_flag.load(Ordering::SeqCst),
            "sync hook did not run inline"
        );

        // Async runs on a spawned task — wait briefly for it.
        let recv = tokio::time::timeout(Duration::from_secs(1), rx.recv())
            .await
            .expect("timed out waiting for async hook")
            .expect("async hook channel closed without sending");
        let _ = recv;

        assert!(unregister_hook(h_sync));
        assert!(unregister_hook(h_async));
    }

    #[tokio::test]
    async fn panicking_hook_does_not_crash() {
        let _g = lock_and_clear();
        let after = Arc::new(AtomicBool::new(false));
        let a = after.clone();
        let h_panic = register_sync_hook("test:panic", HookEvent::HighSurprise, |_ctx| {
            Box::pin(async move {
                panic!("boom");
            })
        });
        let h_ok = register_sync_hook("test:ok", HookEvent::HighSurprise, move |_ctx| {
            let a = a.clone();
            Box::pin(async move {
                a.store(true, Ordering::SeqCst);
            })
        });
        fire_sync(
            HookEvent::HighSurprise,
            HookContext::new(HookEvent::HighSurprise),
        )
        .await;
        assert!(
            after.load(Ordering::SeqCst),
            "subsequent hook did not run after panic"
        );
        assert!(unregister_hook(h_panic));
        assert!(unregister_hook(h_ok));
    }
}
