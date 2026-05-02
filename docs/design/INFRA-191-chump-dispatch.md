# INFRA-191 — `chump dispatch` canonical workflow

**Status:** design (drafted 2026-05-01, pre-implementation)
**Author:** practical-villani session, drafted in parallel with INFRA-188 cutover
**Replaces:** the manual `gap-preflight.sh → gap-claim.sh → bot-merge.sh` shell sequence

## Problem

The current per-agent ship loop is **three shell scripts plus a human/agent stitching them together**:

```bash
git fetch origin main && git status
scripts/coord/gap-preflight.sh <ID>
scripts/coord/gap-claim.sh <ID>
# … work …
scripts/coord/bot-merge.sh --gap <ID> --auto-merge
chump --release   # if not on the bot-merge happy path
```

Failure modes observed in production (April–May 2026):
- Agents skip the preflight (it's "just a check") → land on already-done gaps and burn cycles.
- Agents forget the claim → siblings race them and someone redoes the work.
- Agents commit through `git commit` directly, bypassing `chump-commit.sh`'s sibling-stomp guard.
- Agents push manually when `bot-merge.sh` "looks broken," skipping the INFRA-154 auto-close + INFRA-190 pr-watch hook.
- Agents leave stale lease files behind because `chump --release` is a separate step.
- Lease TTL + claim happen at different layers (`.chump-locks/*.json` vs `.chump/state.db`) — neither layer is the source of truth for "is anyone working on this right now."

Each of these is fixable in shell, and we have. But every fix means another scripts/coord/*.sh file, another env-var bypass, another hook to install. The combinatorial surface is the problem, not any individual script.

INFRA-191 is the **single Rust-native command** that runs the whole loop atomically:

```bash
chump dispatch <ID>            # claim → work-callback → ship → release
chump dispatch --pick          # pick the next available gap, then dispatch
chump dispatch --pick --watch  # daemon mode: pick, dispatch, repeat
```

## Goals

1. **One command, one process** — a single Rust binary owns the whole ship cycle. No shell glue between steps.
2. **Atomic claim+work+ship+release** — if the process dies mid-cycle, the lease expires; if it ships, the lease is released; never both, never neither.
3. **Replace `bot-merge.sh` callsites** without breaking `bot-merge.sh` — keep the shell as a fallback during transition (same pattern INFRA-059 used for `chump gap …` vs the legacy shell scripts).
4. **Backend-agnostic work callback** — same dispatch loop works for an interactive Claude Code session, a `claude -p` headless agent (AUTO-013), or `chump --execute-gap` (COG-025 chump-local backend).
5. **Fleet-ready** — `chump dispatch --pick --watch --max-concurrent N` is the natural Tier 3 entry point for INFRA-211 (run-fleet.sh). One musher process per N agents.

## Non-goals (deferred to follow-up gaps)

- **Spawning the actual agent process.** `chump dispatch` *runs inside* the agent's loop; it doesn't spawn it. Spawning belongs to `run-fleet.sh` (INFRA-211) or the existing `chump-orchestrator` (COG-025).
- **Cross-host coordination.** Single-host only in v1. Cross-host gap-reserve race is INFRA-216.
- **Replacing the merge queue.** Auto-merge still uses GitHub's queue; `chump dispatch` just arms it.
- **Replacing `bot-merge.sh` immediately.** Keep both during transition; cut over one callsite at a time.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  chump dispatch <ID>  (Rust, in src/dispatch.rs)                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. preflight()        ← reads .chump/state.db + active leases  │
│       ├── gap exists, status=open, no live claim                │
│       └── current branch is clean OR on .claude/worktrees/*     │
│                                                                 │
│  2. claim()            ← writes .chump-locks/<session>.json     │
│       ├── reads CHUMP_SESSION_ID / CLAUDE_SESSION_ID            │
│       ├── stamps gap_id, paths, started_at                      │
│       └── emits ambient.jsonl: {kind: "gap_claim", id, session} │
│                                                                 │
│  3. work_callback()    ← caller-provided closure / external cmd │
│       ├── interactive: returns Ok(()) when caller signals done  │
│       ├── headless:    spawns `claude -p <prompt>`, waits exit  │
│       └── exec-gap:    runs `chump --execute-gap <ID>`          │
│                                                                 │
│  4. ship()             ← internalises bot-merge.sh logic        │
│       ├── rebase on main                                        │
│       ├── fmt/clippy/test gate                                  │
│       ├── push branch (force-with-lease)                        │
│       ├── gh pr create + INFRA-154 auto-close gap status flip   │
│       ├── CI pre-flight (INFRA-CHOKE prevention)                │
│       ├── gh pr merge --auto --squash                           │
│       ├── pin pr-<N>-checkpoint tag (INFRA-190 squash insurance)│
│       └── detach pr-watch.sh background process                 │
│                                                                 │
│  5. release()          ← always runs, even on error             │
│       ├── delete .chump-locks/<session>.json                    │
│       ├── purge ./target if .bot-merge-shipped exists           │
│       └── emit ambient.jsonl: {kind: "gap_release", id, result} │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### File layout

```
src/dispatch.rs              ← the dispatch::run() entry point
src/dispatch/preflight.rs    ← step 1
src/dispatch/claim.rs        ← step 2 (consolidates gap-claim.sh)
src/dispatch/ship.rs         ← step 4 (Rust port of bot-merge.sh)
src/dispatch/release.rs      ← step 5
src/dispatch/work.rs         ← work_callback trait + impls
```

`src/main.rs` adds:
```rust
Some("dispatch") => dispatch::run(args)?,
```

### Public API (Rust)

```rust
pub struct DispatchOptions<'a> {
    pub gap_id: Option<&'a str>,        // None = pick mode
    pub pick: bool,
    pub watch: bool,
    pub max_concurrent: usize,
    pub work: WorkBackend,
    pub auto_merge: bool,
    pub broadcast: bool,
}

pub enum WorkBackend {
    Interactive,                                 // caller drives; chump dispatch waits
    Headless { model: String, prompt: String },  // spawns `claude -p`
    ExecGap,                                     // spawns `chump --execute-gap <ID>`
}

pub fn run(opts: DispatchOptions) -> Result<DispatchOutcome>;

pub struct DispatchOutcome {
    pub gap_id: String,
    pub pr_number: Option<u64>,
    pub branch: String,
    pub duration_secs: u64,
    pub result: ShipResult,  // Shipped { pr } | Blocked { reason } | Aborted { error }
}
```

### Shell surface

```bash
chump dispatch <ID>                            # one-shot, interactive backend (default)
chump dispatch <ID> --backend headless         # claude -p
chump dispatch <ID> --backend exec-gap         # chump --execute-gap
chump dispatch --pick                          # pick next, then dispatch
chump dispatch --pick --watch                  # loop forever (Tier 3 fleet entry)
chump dispatch --pick --watch --max-concurrent 5
chump dispatch <ID> --no-auto-merge            # ship PR but don't arm merge queue
chump dispatch <ID> --paths "src/foo.rs,docs/" # narrow lease scope (INFRA-189)
chump dispatch <ID> --dry-run                  # preflight only, no claim/ship
```

Exit codes:
- `0` — shipped (PR landed in queue) OR clean abort (e.g. nothing to pick in `--watch`)
- `1` — preflight failed (gap done / claimed by other / branch dirty)
- `2` — work_callback returned error
- `3` — ship failed (CI red, push rejected, etc.)
- `4` — couldn't release lease (stale, manual cleanup needed)

## Migration plan

Same pattern INFRA-059 used for `chump gap …`: ship Rust path, leave shell scripts as fallback, cut over callsites one at a time, retire shell after a stability window.

### Phase 1 — Rust path lands, shell stays (1 PR)
- `chump dispatch` works end-to-end for the **interactive** backend
- Internally calls `bot-merge.sh` for `ship()` (don't port the shell yet — wrap it)
- Adds 1 unit test per phase + 1 integration test (`dispatch::run` with mocked git/gh)
- No callsite changes in CLAUDE.md / AGENTS.md / scripts

### Phase 2 — Headless + exec-gap backends (1 PR)
- `WorkBackend::Headless` and `WorkBackend::ExecGap` impls
- Used by `run-fleet.sh` (INFRA-211) when it lands

### Phase 3 — Port `ship()` to native Rust (1 PR)
- Replace the `bot-merge.sh` wrap with native Rust git/gh calls
- Reuse `gh` CLI via `tokio::process::Command` (same as bot-merge.sh does)
- bot-merge.sh stays as a fallback; no callsite changes yet

### Phase 4 — Switch CLAUDE.md ship-pipeline guidance (1 PR)
- "Ship pipeline" section flips from `bot-merge.sh` to `chump dispatch`
- bot-merge.sh gets a deprecation header but keeps working
- Update scheduled remote-agent prompts to use `chump dispatch`

### Phase 5 — Retire bot-merge.sh (1 PR, ≥2 weeks after Phase 4)
- Move bot-merge.sh to `scripts/legacy/`
- Update any remaining stragglers
- Final pre-commit guard: warn if `bot-merge.sh` is invoked

## Test plan

Per-phase unit + integration tests. Critical scenarios:

| Scenario | Test |
|---|---|
| Happy path: gap available, work succeeds, PR ships | integration test with mocked gh + git |
| Preflight rejects done gap | unit test |
| Preflight rejects gap claimed by live sibling | unit test (write fake `.chump-locks/<sib>.json`) |
| Work callback errors → release runs, exit 2 | unit test |
| Ship CI red → don't arm auto-merge, exit 3 | integration test |
| Process killed mid-work → next preflight sees stale lease, allows re-pickup | integration test (kill, sleep TTL, re-run) |
| `--watch --max-concurrent 5` honors the cap | integration test |
| Pick mode skips gaps with `depends_on` not yet closed | unit test |

## Open questions

1. **Should `dispatch --watch` write structured progress to ambient.jsonl every N seconds for the FLEET-006 dashboard?** Default yes (cheap). Suppress with `--quiet`.
2. **Should `ship()` Phase 3 use `git2` (libgit2 bindings) or shell out to `git` like bot-merge.sh does?** Recommendation: shell out. libgit2's API for `force-with-lease` is awkward and we already have stable `gh`/`git` semantics in bot-merge.sh.
3. **Backend selection precedence when env vars conflict** (`CHUMP_DISPATCH_BACKEND=claude` + `--backend exec-gap`)?  Recommendation: CLI wins, env var is the fleet-wide default.
4. **Should `--pick` honor agent affinity** (INFRA-212 — gap-domain → preferred agent)?  Defer; INFRA-212 is a separate gap that *uses* INFRA-191's pick logic.

## Dependencies

- INFRA-188 (per-file gap registry) — **must land first** so `chump dispatch` can read gaps incrementally without parsing 5000 lines of monolithic YAML on every preflight. Currently in flight (PR #731 v0 shipped, full cutover in progress at the time of this writing).

## Open-ended risks

- **bot-merge.sh has 820 lines of accumulated edge-case handling.** Phase 3 (port to Rust) will surface latent assumptions. Mitigation: extensive integration test suite *before* Phase 3 cuts the cord, run both side-by-side for ≥1 week.
- **Lease TTL semantics aren't perfectly aligned across the two layers** today (`.chump-locks/` files vs `.chump/state.db` claim rows from `chump gap claim`). Phase 1 should pick *one* canonical layer; recommendation: keep `.chump-locks/` as source of truth (TTL via mtime, `chump gap claim` writes there too).
- **`--watch` in production needs a kill switch** that's not "send SIGTERM and hope." Recommendation: dispatch checks `.chump/dispatch-pause` file every iteration; touch the file to halt the loop after current cycle.

## Implementation pointers for the next session

- Existing dispatcher logic to consolidate: `scripts/coord/musher.py` (gap pick), `scripts/coord/bot-merge.sh` (ship), `scripts/coord/gap-claim.sh` + `gap-preflight.sh` + `gap-reserve.sh` (claim/release).
- Existing Rust gap APIs to extend: `src/gap_store.rs` (already has `list_open()`, `claim()`, `ship()`, `dump_per_file()` post-INFRA-188).
- COG-025 chump-local backend: `src/orchestrator/` already has the `chump-orchestrator` binary that spawns headless agents — `WorkBackend::Headless` should reuse that codepath, not reinvent.
- Test scaffolding pattern: `src/gap_store.rs::tests::test_dump_per_file_*` (just landed in PR #731) is the closest example of full end-to-end test with tmpdir + state.db roundtrip.

---

*This design is the spec for the deferred autonomous run. Not yet ready to ship — depends on INFRA-188 cutover landing first.*
