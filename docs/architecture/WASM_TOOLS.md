---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# WASM tools (WASI sandbox)

Chump’s **sandboxed** tool path runs **WASI** modules via the **`wasmtime`** CLI. No host filesystem mounts or network are passed to the guest by default (`src/wasm_runner.rs`). **Trust context:** WASM is the **bounded** tier in the tool trust ladder; **`run_cli` is not equivalent**—see [TOOL_APPROVAL.md](TOOL_APPROVAL.md) (Trust ladder).

## What ships today

| Tool | WASM artifact | Contract |
|------|---------------|----------|
| **`wasm_calc`** | `wasm/calculator.wasm` | One line on stdin: arithmetic (`+ - * /`, one binary op) → result on stdout. |
| **`wasm_text`** | `wasm/text_transform.wasm` | Line 1: `reverse` \| `upper` \| `lower`. Line 2: UTF-8 text (host truncates at **8192 bytes**). Transformed line on stdout. |

Shared pieces:

| Piece | Role |
|-------|------|
| **`wasm_runner::run_wasm_wasi`** | Spawns `wasmtime run --disable-cache <wasm>` with piped stdio. |
| **`wasm_runner::wasm_artifact_path`** | Resolves `wasm/<file>.wasm` from cwd then executable dir. |

A tool is **registered** only when **`wasmtime`** is on `PATH` and the matching **`.wasm`** file exists (`*_available()` in each tool module).

## Build `calculator.wasm`

From repo root (after `rustup target add wasm32-wasip1`):

```bash
cd wasm/calc-wasm
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/calc-wasm.wasm ../calculator.wasm
```

The `wasm/calc-wasm` crate is a **standalone** workspace member (see its `Cargo.toml`) so it does not inherit the parent Chump workspace.

Source: `wasm/calc-wasm/src/main.rs`.

## Build `text_transform.wasm`

```bash
cd wasm/text-wasm
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/text-wasm.wasm ../text_transform.wasm
```

`wasm/text-wasm` is also a **nested workspace** (same pattern as `calc-wasm`). Source: `wasm/text-wasm/src/main.rs`.

**Note:** `wasm/*.wasm` is **gitignored**; build artifacts locally or in CI before enabling these tools.

## Checklist: adding a new sandboxed WASM tool

1. **Contract** — Define stdin/stdout (or a tiny framed protocol) and document it; keep I/O bounded (line length, runtime).
2. **Isolation** — Use `run_wasm_wasi` or the same pattern: no `--dir`, no network flags, unless you deliberately extend `wasm_runner` and document the new surface.
3. **Binary location** — Use `wasm_runner::wasm_artifact_path("your.wasm")` so cwd and release bundles match `wasm_calc` / `wasm_text`.
4. **Availability gate** — Expose `*_available()` and only register the tool when wasmtime + artifact exist, so CI and laptops without wasmtime stay clean.
5. **Tests** — Add at least one integration test that **skips** when the artifact or wasmtime is missing (see `wasm_text_tool` tests).
6. **Docs** — One paragraph in this file + the tool’s module doc linking here.

## Sandbox prerequisites (`CHUMP_SANDBOX_ENABLED=1`)

The `sandbox_run` tool (distinct from WASM tools) runs a shell command in a disposable git
worktree and tears it down afterwards. It requires:

| Requirement | Why |
|-------------|-----|
| `.git` directory at repo root | `git worktree add` needs a git repo. |
| `git` on `PATH` | Worktree create / remove calls. |
| Write access to the repo's parent directory | Worktree is created as a sibling of the repo root. |
| Non-shallow clone | `git worktree add` fails on shallow clones (CI: use `fetch-depth: 0`). |

**Environment variables:**

| Variable | Default | Effect |
|----------|---------|--------|
| `CHUMP_SANDBOX_ENABLED` | `0` | Set to `1` to enable; off by default. |
| `CHUMP_SANDBOX_TIMEOUT_SECS` | `120` | Max seconds a sandboxed command may run (1–600). |
| `CHUMP_SANDBOX_ALLOWLIST` | *(empty)* | Comma-separated substrings. When set, command must match at least one (case-insensitive). |
| `CHUMP_SANDBOX_DISK_BUDGET_MB` | `500` | Max MiB the worktree may use after the command runs. Overage is warned in output; worktree is still removed. |

High-risk commands (as classified by `cli_tool::heuristic_risk`) are **always rejected**
regardless of the allowlist.

**Mac vs CI differences:**

- **Mac (local dev):** `git` must be a full clone (Xcode CLT or Homebrew). Unified memory
  contention under concurrent cargo builds may slow sandbox runs.
- **CI (GitHub Actions):** Add `fetch-depth: 0` to the checkout step. The sandbox worktree
  is created in `/tmp` or the runner's `TMPDIR`. Disk budget of 500 MB is usually sufficient
  but can be raised for large repo builds.

## Non-goals (near term)

**Do not** plan on **WASM-wrapping all of `run_cli`**. Host shell, Git, and network semantics do not map cleanly to WASI without a large, reviewed capability matrix. Prefer **`CHUMP_TOOLS_ASK`**, allowlists, and future container/SSH-jump profiles for high-risk commands ([TOOL_APPROVAL.md](TOOL_APPROVAL.md)).

Longer-term JIT WASM ideas: [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md).

## Related

- `src/wasm_calc_tool.rs`, `src/wasm_text_tool.rs`, `src/wasm_runner.rs`  
- [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) — tool registration patterns
