---
doc_tag: decision-record
owner_gap:
last_audited: 2026-04-25
---

# Sandbox tool-routing policy (INFRA-001c)

When `CHUMP_SANDBOX_SPECULATION=1` and the agent runs a tool inside a
speculative branch, this policy decides whether the tool's invocation
should be routed through `sandbox_run` (filesystem worktree isolation)
so that rollback can throw away its side effects.

| classification | semantics |
|---|---|
| **safe** | Read-only or in-process only. Never sandboxed. Rollback restores in-memory state via the existing speculative path. |
| **sandboxed** | Mutates the working directory or external command env. Routed through `sandbox_run` when `CHUMP_SANDBOX_SPECULATION=1`. Rollback tears down the worktree; commit copies changes back. |
| **never** | Network, scheduling, notifications, or anything talking to a real external system. Sandbox can't roll these back. They're always allowed but counted by `INFRA-001a` so we know how often speculative branches leak side effects. |

## Tool inventory

Source: `ls src/*_tool.rs` plus tools in `src/git_tools.rs`, `src/repo_tools.rs`.
Last reviewed 2026-04-17.

### safe (no sandbox needed; in-process rollback handles state)

| tool | reason |
|---|---|
| `calc` | pure arithmetic |
| `wasm_calc` | sandboxed wasm interpreter, no FS I/O |
| `wasm_text` | wasm text processing, no FS I/O |
| `read_file` | read-only |
| `read_url` | read-only HTTP GET |
| `list_dir` | read-only |
| `codebase_digest` | read-only summary |
| `session_search` | read-only DB query |
| `introspect` | read-only metrics view |
| `episode` | append-only DB log; idempotent within speculation; rollback drops log via DB transaction |
| `memory` (read paths) | read-only retrieval |
| `memory_brain` (read paths) | read-only retrieval |
| `memory_graph` | read-only graph query |
| `gh_pr_list_comments` | read-only GitHub query |
| `task` (list / status read) | read-only DB query |
| `toolkit_status` | read-only env probe |
| `diff_review` | read-only |
| `screen_vision` | read-only screen capture (no FS write besides one PNG; safe to leave) |
| `ego` | read-only personality reflection |
| `ask_jeff` | DB write but operationally idempotent + non-destructive (queue a question) |
| `checkpoint` (read paths) | read-only |
| `battle_qa` | dispatches its own subprocess; speculation shouldn't wrap it |
| `decompose_task` | DB writes (creates child tasks). Treat as **sandboxed** — see below. |
| `task_planner` | DB writes (plan steps). **sandboxed**. |
| `delegate` | spawns delegate; in-process state managed; no FS effects |
| `notify` | external notification (Discord/email). **never** — can't unsend. |
| `schedule` | DB write of pending job. **never** — can't unschedule reliably. |
| `spawn_worker` | spawns process. **never** — can't reap reliably. |

### sandboxed (route through sandbox_run when CHUMP_SANDBOX_SPECULATION=1)

| tool | reason |
|---|---|
| `write_file` | direct file write; canonical sandbox candidate |
| `patch_file` | unified-diff application; same |
| `cli` (`run_cli`) | arbitrary shell; biggest blast radius; sandbox is the whole point |
| `run_test` | runs `cargo test`; usually idempotent BUT side effects from test setup (sessions DB, file artifacts) shouldn't leak from speculation |
| `git_commit` | mutates index + history |
| `git_push` | actually `never` (can't unpush). Sandbox can isolate the push attempt but the remote keeps the receive side effect. Document as sandboxed-but-warn. |
| `git_revert` | mutates history |
| `git_stash` | mutates working tree state |
| `cleanup_branches` | deletes local refs |
| `merge_subtask` | composite git+file ops |
| `patch_apply` (internal helper) | inherits patch_file routing |
| `set_working_repo` | switches CHUMP working dir; technically reversible but trivially confusing inside speculation |
| `onboard_repo` | clones a repo; massive FS writes |
| `repo_allowlist` (write paths) | mutates persistent allowlist |
| `decompose_task` | adds child task rows (DB write) |
| `task_planner` | persists plan steps |
| `checkpoint` (write paths) | snapshots in-process state to disk |
| `memory` (write paths) | adds to chump_memory |
| `memory_brain` (write paths) | persists to chump_brain markdown |
| `skill` (install/update) | writes to chump-brain/skills |
| `skill_hub` (install) | downloads + writes |
| `a2a` | inter-agent invocations; defer to receiving agent's policy |
| `fleet` (write paths) | peer-state writes |

### never (cannot be rolled back; counted but allowed)

| tool | reason |
|---|---|
| `git_push` | remote receive side effect persists |
| `notify` | external delivery |
| `schedule` | timer registration |
| `spawn_worker` | external process; reaping is best-effort |

## Rollback semantics summary

When a speculative branch rolls back:
1. **safe** tools' in-process effects are reverted via `speculative_execution::fork()/restore()`.
2. **sandboxed** tools' effects (when `CHUMP_SANDBOX_SPECULATION=1`) are torn down by removing the sandbox worktree.
3. **never** tools' effects ARE NOT rolled back — they're counted into
   `chump_speculation_metrics` (INFRA-001a) so we can quantify the leak rate.

When a speculative branch commits:
1. **safe** — keep the in-memory state.
2. **sandboxed** — copy worktree changes back into the real working dir
   (atomic rename if possible).
3. **never** — already happened; no-op on commit.

## Operational notes

- `CHUMP_SANDBOX_SPECULATION=0` (default) is the legacy behavior:
  no FS isolation, in-process rollback only. Safe to keep until
  INFRA-001a metrics show non-trivial leak rate.
- This doc is the contract `src/speculative_execution.rs` consults. If
  you add a new tool, update this doc AND its classification in
  `src/tool_inventory.rs::tool_speculation_class()` (TBD as part of
  INFRA-001b). Until then, unknown tools default to `never`.
