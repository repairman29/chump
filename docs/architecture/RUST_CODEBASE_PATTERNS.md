---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump Codebase — Rust Patterns Reference

This file teaches me how to write code that fits THIS codebase. Generic Rust knowledge isn't enough — I need to match the patterns already established here.

## How to Add a New Tool

Every tool follows this exact pattern. Don't deviate.

### 1. Create the file (e.g., `src/my_tool.rs`)

```rust
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::provider::Tool;
use chump_tool_macro::chump_tool;
use serde_json::Value;

pub struct MyTool;

#[chump_tool(
    name = "my_tool",
    description = "One sentence: what it does and when to use it.",
    schema = r#"{"type":"object","properties":{"param":{"type":"string","description":"what this param does"}},"required":["param"]}"#
)]
#[async_trait]
impl Tool for MyTool {
    async fn execute(&self, input: Value) -> Result<String> {
        let param = input.get("param")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing param"))?;
        
        // Do work here
        Ok(format!("result: {}", param))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn basic_usage() {
        let tool = MyTool;
        let result = tool.execute(json!({"param": "hello"})).await.unwrap();
        assert!(result.contains("hello"));
    }
}
```

### 2. Register in `src/main.rs`

Add `mod my_tool;` in alphabetical order with the other mod declarations.

### 3. Register in `src/tool_inventory.rs`

Add near the other `inventory::submit!` blocks:

```rust
inventory::submit! {
    ToolEntry::new(|| Box::new(my_tool::MyTool), "my_tool")
}
```

If the tool needs conditional enabling:
```rust
inventory::submit! {
    ToolEntry::new(|| Box::new(my_tool::MyTool), "my_tool")
        .when_enabled(|| std::env::var("CHUMP_MY_TOOL_ENABLED").map(|v| v == "1").unwrap_or(false))
}
```

### 4. Add to routing table in `src/tool_routing.rs`

Add a line to `routing_table()` so the system prompt tells the model when to use it.

### 5. Add to tool profile in `src/env_flags.rs`

If this tool should be in core or coding profile (not just full), add its sort_key to the appropriate const array.

## Error Handling Rules

- **Always use `anyhow::Result<T>`**. No custom error enums in this codebase.
- **Use `?` for propagation**, not `.unwrap()` in production code.
- **Use `.ok_or_else(|| anyhow!("message"))` for Option → Result conversion.**
- **Never `.unwrap()` on mutex/lock in production**. Use `.lock().map_err(|_| anyhow!("lock poisoned"))?`.
- **In Drop impls**: always use `let _ = ...` to suppress errors. Never panic in Drop.

## Database Access

All state lives in one SQLite file: `sessions/chump_memory.db`.

```rust
// Get a pooled connection
let conn = crate::db_pool::get()?;

// Query
let value: String = conn.query_row(
    "SELECT value FROM chump_state WHERE key = ?1",
    [key],
    |row| row.get(0),
)?;

// Insert/update
conn.execute(
    "INSERT OR REPLACE INTO chump_state (key, value) VALUES (?1, ?2)",
    rusqlite::params![key, value],
)?;
```

**Migration pattern** — always idempotent:
```rust
let _ = conn.execute("ALTER TABLE my_table ADD COLUMN new_col TEXT DEFAULT NULL", []);
```

**Test DB isolation** — use `#[cfg(test)]` to create isolated connections:
```rust
#[cfg(test)]
fn open_db() -> Result<rusqlite::Connection> {
    let conn = rusqlite::Connection::open_in_memory()?;
    conn.execute_batch("CREATE TABLE IF NOT EXISTS ...")?;
    Ok(conn)
}
```

## Async Patterns

**Subprocess execution:**
```rust
let output = tokio::process::Command::new("git")
    .args(["status", "--porcelain"])
    .current_dir(&repo_root)
    .output()
    .await
    .map_err(|e| anyhow!("git failed: {}", e))?;
```

**Timeouts:**
```rust
let result = tokio::time::timeout(
    Duration::from_secs(60),
    do_async_work()
).await.map_err(|_| anyhow!("timed out after 60s"))??;
```

**Concurrency limiting with semaphore:**
```rust
static SEM: OnceLock<Arc<Semaphore>> = OnceLock::new();
fn semaphore() -> &'static Arc<Semaphore> {
    SEM.get_or_init(|| Arc::new(Semaphore::new(4)))
}

// In async function:
let _permit = semaphore().clone().acquire_owned().await?;
// permit is held until _permit is dropped
```

## RAII Cleanup

When creating temporary resources (worktrees, temp files, locks), always use a Drop guard:

```rust
struct CleanupGuard {
    path: PathBuf,
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

// Usage:
let _guard = CleanupGuard { path: temp_dir.clone() };
// ... do work ...
// cleanup happens automatically, even on panic or early return
```

## Module Organization

- **All modules are flat** in `src/`. No subdirectories (except `src/routes/`).
- **Add `mod my_module;` to `main.rs`** in alphabetical order.
- **Feature-gated modules** use `#[cfg(feature = "name")]` on the mod declaration.
- **Test-only modules** use `#[cfg(test)]` on the mod declaration.

## Testing Conventions

- **Use `#[tokio::test]` for async tests** (most tool tests are async).
- **Use `#[serial_test::serial]` for tests that touch the DB** — prevents concurrent access issues.
- **Create temp dirs for test isolation**: `std::env::temp_dir().join(format!("chump_test_{}", uuid::Uuid::new_v4().simple()))`.
- **Set `CHUMP_TOOL_PROFILE=full`** in test setup if testing tools outside the core profile.
- **Mock pattern**: create a `struct FakeThing;` that implements the trait, then test against it.

## Tracing & Logging

```rust
// Info for important events
tracing::info!(task_id = %id, status = %new_status, "task status changed");

// Debug for internal state
tracing::debug!(tokens = approx_tokens, model = %self.model, "request budget");

// Warn for recoverable issues
tracing::warn!(tool = %name, failures = count, "circuit breaker tripped");
```

Use **structured fields** (`key = %value`), not format strings. The `%` sigil uses Display, `?` uses Debug.

## Environment Variable Pattern

```rust
// Simple bool flag
pub fn my_feature_enabled() -> bool {
    std::env::var("CHUMP_MY_FEATURE")
        .map(|v| matches!(v.trim(), "1" | "true" | "TRUE"))
        .unwrap_or(false)
}

// With default value
pub fn my_setting() -> u64 {
    std::env::var("CHUMP_MY_SETTING")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(10)
}
```

Always document new env vars in `.env.example` with a comment explaining what they do.

## Things I Must NOT Do

1. **Don't create subdirectories** under `src/`. Keep the flat module structure.
2. **Don't add custom error enums**. Use `anyhow`.
3. **Don't use `.unwrap()` in production code**. Use `?` or `.unwrap_or_default()`.
4. **Don't add tools without registering them** in tool_inventory.rs AND tool_routing.rs.
5. **Don't skip the `#[chump_tool(...)]` macro** — it generates name(), description(), input_schema() for you.
6. **Don't commit with failing tests**. Run `cargo test --bin chump` first.
7. **Don't use `println!`** for logging. Use `tracing::info!`/`debug!`/`warn!`.
8. **Don't forget to add the `mod` declaration** in `main.rs` when creating a new file.
9. **Don't put complex logic in the Justfile or shell scripts** — put it in Rust, call it from scripts.
10. **Don't add large dependencies** without checking if an existing dep or stdlib covers it.

## Key Files to Read Before Major Changes

| Area | Files |
|------|-------|
| Agent core | `agent_loop.rs`, `discord.rs` (system prompt), `local_openai.rs` |
| Tool system | `tool_inventory.rs`, `tool_middleware.rs`, `tool_routing.rs` |
| Autonomy | `autonomy_loop.rs`, `task_executor.rs`, `task_contract.rs` |
| Database | `db_pool.rs`, `state_db.rs`, `task_db.rs`, `memory_db.rs` |
| Web | `web_server.rs`, `src/routes/` |
| Config | `env_flags.rs`, `config_validation.rs`, `repo_path.rs` |
| Context | `context_assembly.rs`, `context_firewall.rs` |
| Consciousness | `surprise_tracker.rs`, `blackboard.rs`, `belief.rs`, `neuromodulation.rs` |
