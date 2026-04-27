---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump × Cursor — fleet, CLI, and safe multi-agent work

**Audience:** Cursor IDE sessions, Composer agents, headless `agent` CLI invocations, and Chump `run_cli` delegations.

This doc is the **canonical** handoff surface for “how we work together safely.” Older references to `docs/process/CHUMP_CURSOR_PROTOCOL.md` / `docs/process/CURSOR_CLI_INTEGRATION.md` should be updated to point here until those files are restored from archive.

---

## 1. Non-negotiables (same as every Chump agent)

Read **`docs/process/AGENT_COORDINATION.md`** and **`docs/architecture/AGENT_LOOP.md`** before parallel work:

- **`scripts/coord/gap-preflight.sh <GAP-ID>`** then **`scripts/coord/gap-claim.sh <GAP-ID>`** before touching shared paths or `docs/gaps.yaml`.
- **Work in a linked git worktree** (see `CLAUDE.md`) — not the main repo root.
- **Never bypass coordination hooks** with `CHUMP_*=0`, `--no-verify`, or mystery env flags to “unstick” an error you do not understand. Stop and surface it.
- **Gap filing under contention:** follow **AGENT_LOOP § Go slow to go fast** — `scripts/coord/broadcast.sh`, PR diff scans for reserved IDs, and prefer **`scripts/coord/gap-reserve.sh`** (see **INFRA-021**) over ad-hoc “next free number” picks.

---

## 2. Cursor CLI (`agent`) — smoke and PATH

- Install puts `agent` under `~/.local/bin` or `~/.cursor/bin` — ensure **`PATH`** includes them.
- From repo root: **`bash scripts/dev/cursor-cli-status-and-test.sh`** — checks model sidecar, lists Chump processes, verifies `agent`, optional one-shot against `target/release/chump`.
- **`CHUMP_CURSOR_CLI`** in `.env` is the integration toggle for Chump-side delegation (see script output when unset).

### MCP: `chump-mcp-coord` (INFRA-033)

For MCP-first workflows (Cursor, Zed, Claude Desktop), run **`chump-mcp-coord`** from this repo with **`CHUMP_REPO`** set to the workspace root (see `crates/mcp-servers/chump-mcp-coord/README.md` and `crates/mcp-servers/README.md`). It exposes **`gap_preflight`**, **`gap_claim_lease`**, **`lease_list_active`**, **`musher_pick`**, and **`ambient_tail`** over JSON-RPC stdio — same invariants as shell, without ad-hoc copy/paste. CI runs **`bash scripts/ci/test-mcp-coord-smoke.sh`** (`tools/list` probe).

Headless / scripted use must still respect **tool safety** and **lease** rules — there is no “CLI exception” for stomping `main`.

---

## 3. Chump → Cursor delegation (`run_cli`)

When Chump (e.g. Discord) delegates coding to Cursor, the pattern is **non-interactive `agent`** with an explicit prompt and scope — see **`docs/architecture/INTENT_ACTION_PATTERNS.md`** (“Use Cursor to fix …” → `run_cli` with `agent -p "..."`).

Every delegation prompt must include:

1. **Goal** (one sentence) and **gap ID** (if any).
2. **Branch + worktree path** (or instruction to create `claude/<codename>`).
3. **Files in scope** — list paths; forbid drive-by edits outside scope.
4. **Verification** — exact `cargo test` / `bash scripts/...` commands to run before declaring done.
5. **Hand back** — PR URL or “blocked on X” with logs.

See also **`docs/process/CURSOR_CLAUDE_COORDINATION.md`** for when to route work through Cursor vs Claude Code vs both.

---

## 3b. Claude session handoff — what the Cursor parent pastes back

When a **Claude Code** sibling (or unattended `claude -p` loop) lands commits while you own coordination in Cursor, require a **single packaged return** before you merge or repick:

- **Gap ID** and whether the gap row is still open or should move to `status: done` in your PR.
- **Branch name** + **absolute worktree path** they used (under `.claude/worktrees/…`).
- **Commits / SHAs** or PR link that shipped the work; **CI status** if available.
- **Remaining acceptance** — bullets still unchecked, or “none — ready to close”.
- **Lease** — confirm they stopped claiming the gap (`gap_id` cleared or session ended) so your `gap-claim.sh` does not fight a stale lease.

You paste the inverse when **Cursor** shipped and Claude picks up: same five bullets from the Cursor parent so Claude’s next `--pick` does not redo merged work.

---

## 4. Cursor IDE: parent session vs subagents (“Task” / partner runs)

**Parent session (Composer / agent in Cursor)** owns coordination: gap pick, lease, PR strategy, and merges.

**Subagents / delegated tasks** should be treated as **specialists**, not second copies of the parent:

| Use subagent for | Prefer subagent type |
|------------------|----------------------|
| Read-only repo recon (where is X?, summarize Y) | Explore / readonly |
| Large multi-file investigation with no writes | Explore |
| Implement a bounded change set the parent will review | General-purpose (writes) |

**Rules**

- Give subagents **one deliverable** (e.g. “return a 10-bullet recon + file:line cites” or “open a PR against branch B with ≤5 files”).
- **Do not** have a subagent run `gap-claim.sh` or edit `docs/gaps.yaml` unless the parent explicitly owns the merge and lease lifecycle.
- Paste **subagent output into the parent** before acting on it — subagents do not inherit full session lease state.

**Partner agents** (second human or second IDE session on the same gap): treat like another autonomous agent — **different `CHUMP_SESSION_ID`**, same preflight/claim rules, smaller PRs.

---

## 5. Improving the system (meta)

When fleet behavior hurts us (duplicate gap IDs, silent bypasses, ambiguous handoffs):

1. **Capture** the failure mode in **`docs/audits/RED_LETTER.md`** or a focused eval note.
2. **Prefer automation** (hook, `gap-reserve`, musher change) over “try to remember next time.”
3. **Update this doc + `.cursor/rules/chump-multi-agent-fleet.mdc`** in the same PR as the behavior change so Cursor agents load the new bar immediately.
4. **Preflight visibility** — run **`bash scripts/dev/fleet-status.sh`** before picking work in a crowded fleet (musher table + leases + ambient + open `docs/gaps.yaml` PRs).

---

## 6. Environment variables and session identity

These are the knobs agents actually hit in multi-session Cursor + Chump setups:

| Variable | Role |
|----------|------|
| **`CHUMP_SESSION_ID`** | Distinguishes parallel humans/tabs/sessions. **Partner agents** must use a **different** value than the parent; collisions merge lease + ambient streams incorrectly. |
| **`CHUMP_CURSOR_CLI`** | Chump-side toggle for delegating to Cursor CLI (see `scripts/dev/cursor-cli-status-and-test.sh` output when unset). |
| **`CHUMP_HOME`** | Repo root override for scripts that support it. |
| **`CHUMP_LOCK_DIR`** | Override for `.chump-locks/` (must match across tools in one workspace). |
| **`CHUMP_AMBIENT_LOG`** | Override path for `ambient.jsonl` (see **`docs/process/AGENT_COORDINATION.md`**). |

**Anti-patterns (no exceptions for Cursor):** disabling hooks with `CHUMP_*=0`, `git commit --no-verify`, or ad-hoc env to silence coordination errors. If preflight/claim fails, **stop** and fix the underlying conflict — do not “paper over” and edit `docs/gaps.yaml` or shared hot paths unclaimed.

---

## See also

- **`docs/architecture/AGENT_LOOP.md`** — autonomous loop, `/loop`, `scripts/dev/agent-loop.sh`, Claude vs Cursor parity (§ Starting a new agent)
- **`docs/process/AGENT_COORDINATION.md`** — leases, ambient, gaps ledger semantics
- **`AGENTS.md`**, **`CLAUDE.md`** — portable vs Chump-specific mechanics

**Related gap rows** (`docs/gaps.yaml`): **INFRA-033** (done — MCP `chump-mcp-coord` tools for preflight/leases/musher). **INFRA-030** (done — `scripts/dev/fleet-status.sh` + AGENT_LOOP wiring), **INFRA-031** (done — Claude vs Cursor parity + §6 env table here), **INFRA-032** (done — dual-surface index + handoff + `coord-surfaces-smoke.sh`).
