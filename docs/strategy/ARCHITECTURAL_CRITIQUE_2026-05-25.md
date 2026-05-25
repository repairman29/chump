# Architectural Critique — Chump as of 2026-05-25

**Authored:** 2026-05-25 by opus-curator-overnight (Principal Systems Architect framing, per operator request).
**Umbrella gap:** [INFRA-1985](../gaps/INFRA-1985.yaml).
**Sub-gaps:** INFRA-1964 through INFRA-1984 (21 findings).
**Companion docs:** [`SHIP_ORDER_VISION_2026-05-25.md`](SHIP_ORDER_VISION_2026-05-25.md) for tier-ordered remediation, [`PRODUCTIZATION_PLAN_2026-05-22.md`](PRODUCTIZATION_PLAN_2026-05-22.md) for the operator-set goals this audit measures against.

## Methodology

Direct code survey (workspace `Cargo.toml`, `src/main.rs`, `src/dispatch.rs`, `src/atomic_claim.rs`, `src/state_db.rs`, the 33,730 LOC of bash in `scripts/coord/` + `scripts/dispatch/`) cross-referenced against failure modes observed during 2026-05-24/25 live session-driving. Findings tagged `[OBSERVED]` are ones I personally watched fire in this session.

## Findings by severity

### CRITICAL (6 — INFRA-1964…INFRA-1969)

| # | Finding | Code citation | Gap |
|---|---|---|---|
| **C1** | Mission-reality gap on local-LLM — fleet workers default to `claude -p`; no MLX path wired in production | `src/dispatch.rs:355-470` (`WorkBackend::Headless`); no `mlx` crate in workspace | [INFRA-1964](../gaps/INFRA-1964.yaml) |
| **C2** | `src/main.rs` is 14,450 LOC with 231 `mod` declarations — full-recompile blast radius | `wc -l src/main.rs` → 14,450; `grep -c '^mod ' src/main.rs` → 231 | [INFRA-1965](../gaps/INFRA-1965.yaml) |
| **C3** | 33,730 LOC bash orchestrator (`bot-merge`/`queue-driver`/`pr-rescue`/`pr-auto-rebase`) racing without primitives | `scripts/coord/` + `scripts/dispatch/` aggregate LOC | [INFRA-1966](../gaps/INFRA-1966.yaml) |
| **C4** | State store is single-node SQLite via `r2d2` pool — fleet pattern cannot scale across machines | `src/state_db.rs:8`; `src/atomic_claim.rs:284-304` | [INFRA-1967](../gaps/INFRA-1967.yaml) |
| **C5** | `graphql_exhausted` self-amplifying loop — per-process bucket emits cascade alerts | `scripts/coord/lib/gh-shim/gh` debounce broken when `resets_at:unknown` | [INFRA-1968](../gaps/INFRA-1968.yaml) |
| **C6** | Pre-commit hook architecturally cannot read commit message; `Net-new-docs:` trailer always invisible | `scripts/git-hooks/pre-commit:1605-1631` reads `$MSG_FILE` which doesn't exist at pre-commit stage | [INFRA-1969](../gaps/INFRA-1969.yaml) |

### HIGH (9 — INFRA-1970…INFRA-1978)

| # | Finding | Code citation | Gap |
|---|---|---|---|
| **H1** | Lease primary key is paths, not gap-ID — admits duplicate-PR race | `crates/chump-agent-lease/`; `src/atomic_claim.rs` | [INFRA-1970](../gaps/INFRA-1970.yaml) |
| **H2** | Auto-rearm daemon closes PRs after legitimate force-push — no intent signal | `scripts/coord/pr-auto-rearm.sh` | [INFRA-1971](../gaps/INFRA-1971.yaml) |
| **H3** | Subagent dispatches have no parent-enforced wall-clock kill; 100K+ tokens per stall | `src/dispatch.rs:470` (`wait_with_hang_detection` emits but does not SIGTERM) | [INFRA-1972](../gaps/INFRA-1972.yaml) |
| **H4** | `ambient.jsonl` unindexed append-only — every consumer greps linearly | `src/adversary.rs:emit_ambient_alert` + many shell appends | [INFRA-1973](../gaps/INFRA-1973.yaml) |
| **H5** | Concurrent rebase daemons race operator-initiated rebase — no per-branch lock | `scripts/coord/pr-auto-rebase.sh` | [INFRA-1974](../gaps/INFRA-1974.yaml) |
| **H6** | Voice-lint half-state — fails but not in required-checks; banned terms ship to main | `scripts/ci/test-voice-banlist.sh` wired into CI, missing from branch protection | [INFRA-1975](../gaps/INFRA-1975.yaml) |
| **H7** | Stale repo-vars invisible to `infra-watcher` — `CHUMP_SELF_HOSTED_ENABLED` sat 4d dead | `scripts/coord/infra-watcher-loop.sh` audits substrate, not vars | [INFRA-1976](../gaps/INFRA-1976.yaml) |
| **H8** | `chump` binary staleness gate forces routine bypass; JIT refresh missing | INFRA-825 enforcement at gap-mutation paths; rebuild is multi-minute | [INFRA-1977](../gaps/INFRA-1977.yaml) |
| **H9** | `chump --briefing`/`health` JSON `schema_version` not asserted by callers | INFRA-1548 added the field; `scripts/dispatch/*` consumers don't check it | [INFRA-1978](../gaps/INFRA-1978.yaml) |

### MEDIUM (6 — INFRA-1979…INFRA-1984)

| # | Finding | Code citation | Gap |
|---|---|---|---|
| **M1** | Inbox jsonl files grow unbounded — no rotation cap | `.chump-locks/inbox/<session-id>.jsonl` (broadcast.sh appends, no prune) | [INFRA-1979](../gaps/INFRA-1979.yaml) |
| **M2** | Worktree lifecycle is operator-cleared; reaper missed 20 GB stale today | `stale-worktree-reaper` daemon; cleared by hand 2026-05-24 | [INFRA-1980](../gaps/INFRA-1980.yaml) |
| **M3** | `gh pr view .state` returns transient `CLOSED` during force-push window | observed 2× (PRs #2561 and #2566) | [INFRA-1981](../gaps/INFRA-1981.yaml) |
| **M4** | `chump gap reserve` title-similarity gate friction without preventing duplicate-PR class | INFRA-1149 Jaccard ≥ 0.85 block; bypassed 3× today | [INFRA-1982](../gaps/INFRA-1982.yaml) |
| **M5** | MCP servers run independent lifecycle; `chump-mcp-lifecycle` not uniformly used | `crates/mcp-servers/{github,tavily,adb,gaps,eval,coord,memory}` | [INFRA-1983](../gaps/INFRA-1983.yaml) |
| **M6** | No shared fleet snapshot; agents re-grep JSONL at session start | every monitor I armed today did `tail -F .jsonl \| grep` | [INFRA-1984](../gaps/INFRA-1984.yaml) |

## The deepest issue

Of the 21 findings, **C1 (mission-reality gap on local-LLM)** is the largest single risk. Chump positions as a localized agent replacing distributed bot infrastructure. The shipping product is a coordination layer over a cloud LLM. The day Anthropic rate-limits the OAUTH token (which I watched happen on 2026-05-24 17:16Z with 6 `graphql_exhausted` events in 60 seconds — see C5) or deprecates a model, every fleet worker stalls. There is no functional MLX path in `dispatch.rs`. `mlx` does not appear anywhere in the workspace search.

The next-deepest is the **mismatch between framing and reality at the orchestration layer (C3)**. Chump-as-a-Rust-project has 24 crates; Chump-as-orchestrator is 33,730 LOC of bash. The Rust binary is mostly a CLI for atomic state mutations the bash calls into. Every concurrency-critical operation (rebase, force-push, auto-merge arm, queue drain, daemon supervision) is bash glue around `git`, `gh`, and `jq`. I watched at least four race conditions fire from this layer in 24 hours.

The third is **single-node coordination (C4)**. The Pi-mesh / dual-RTX-6000 vision in `MEMORY.md` does not have a storage layer that supports it. `state.db` is one SQLite file. Atomic claim CAS serializes through one file on one machine. When `CHUMP_NATS_URL` is set, the push-route works — in production today, it is unset.

## Lived evidence from this session (cited inline above)

- **6 `graphql_exhausted` events in 60 seconds** on 2026-05-24 17:16-17:18Z → C5
- **`bot-merge` silent wedge for 17 minutes** on `chump gap import` exit-code mis-classification → C3
- **Two Sonnet implementer dispatches burned 144K + 157K tokens with zero artifacts** → H3
- **Duplicate PRs #2539 + #2540 for INFRA-1950**, opened 69 seconds apart → H1
- **`pr-auto-rebase` daemon rebased my branch in parallel with my own rebase** on PR #2566 at 04:51:46Z → H5
- **`CHUMP_SELF_HOSTED_ENABLED=false`** sat 4 days unrecovered after 2026-05-20 disk_critical → H7
- **Binary-staleness bypass used 4× in 24 hours** because rebuild is too slow for in-loop use → H8
- **`gh pr view .state` returned transient `CLOSED`** for both PR #2561 and PR #2566 → M3
- **20 GB of stale `/tmp/chump-*` worktrees** cleared by hand on 2026-05-24 → M2
- **Pre-commit hook required `CHUMP_DOCS_DELTA_CHECK=0` bypass** even with `Net-new-docs:` trailer → C6
- **Voice-lint failed PR #2561** but PR merged anyway; 2 banned terms now on main → H6

## Ship order (cross-reference)

The remediation ship order is in [`SHIP_ORDER_VISION_2026-05-25.md`](SHIP_ORDER_VISION_2026-05-25.md). Briefly:

- **Tier 0 (eliminator, ship first regardless of priority):** C5/INFRA-1968, C6/INFRA-1969, H3/INFRA-1972, H8/INFRA-1977, H5/INFRA-1974, H7/INFRA-1976, M2/INFRA-1980
- **Tier 1 (cascade unblocker):** C3/INFRA-1966, H1/INFRA-1970
- **Tier 2 (half-state cleanup):** H6/INFRA-1975 (policy decision), INFRA-1962 (the cleanup that lost the squash race)
- **Tier 3 (foundation):** C1/INFRA-1964 (the mission delivery), C4/INFRA-1967 (cross-machine state)
- **Tier 4 (velocity multiplier):** M6/INFRA-1984 (fleet snapshot), H4/INFRA-1973 (ambient index), C2/INFRA-1965 (decompose main.rs)

## What this doc is NOT

- Not a complete code review (no per-function critique; focused on architectural failure classes)
- Not a roadmap (see `docs/ROADMAP.md`)
- Not a sprint plan (see `ROADMAP_SPRINTS.md`)
- Not a complete priority re-ranking (priorities here are author opinion; operator owns the final order)

## What this doc IS

- A prioritized list of where the system breaks under load, with concrete code citations
- The architectural pivot required for each, summarized in the sub-gap AC
- The umbrella to track all 21 fixes to completion ([INFRA-1985](../gaps/INFRA-1985.yaml))

## Process note for future critiques

The discipline of cross-referencing each finding to a specific code path and lived-evidence event came from `CURATOR_OPUS_LESSONS_2026-05-23.md` ("verify at source"). Any future architectural review should adopt the same discipline: claims without code citations or observed incidents are not findings, they are opinions.
