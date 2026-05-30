# Fleet recv-side v0 — close the broadcast loop on the deployed NATS/A2A stack

**Date:** 2026-05-30
**Author:** ci-audit-onboarding Opus session
**Umbrella:** META-157
**Status:** Design — awaiting operator sign-off before fleet dispatch

---

## TL;DR

The fleet has a mature emit side and a 0-bytes-on-disk recv side. Today (2026-05-30) I broadcast 3 FEEDBACK proposals (META-132 fresh-eyes, META-132 cadence, META-152/153/154 rollup) and received **zero replies** despite 5 alive curator sessions heartbeating throughout. Diagnosis below identifies a compound 3-step failure, all addressable in v0 against the **already-deployed** NATS/A2A stack (INFRA-1759 RPC, INFRA-1760 CapabilityManifest, INFRA-1761 NATS KV chump_scratch are shipped).

v0 = 6 parallel slices via META-069 Sonnet dispatch, closing with an end-to-end test that proves a broadcast → 5 curator drains → 3 votes → 1 `kind=consensus_result` event. Shipped behind a feature flag (`CHUMP_FLEET_RECV_SIDE_V0`) defaulting off until E2E green.

## 1. Deployment reality (corrected)

I previously claimed "NATS not deployed" and "INFRA-1118-1123 mostly unshipped." Both wrong. Verified facts as of 2026-05-30T04:40Z:

| Component | Status | Evidence |
|---|---|---|
| NATS broker | **Running** at `nats://127.0.0.1:4222` | `chump-coord ping` exits 0 |
| broadcast.sh dual-publish | **Active** for INTENT/HANDOFF/STUCK/DONE/WARN/ALERT/**FEEDBACK** | `emit_to_nats` invoked for all 7 event types |
| INFRA-1759 RPC stubs (Layer 2b) | **DONE** (#2379 merged 2026-05-23) | `chump-coord status`, `chump-coord post` operational |
| INFRA-1760 CapabilityManifest (Layer 2c) | **DONE** (#2413 merged 2026-05-29) | `chump-capability-v1` schema landed |
| INFRA-1761 NATS KV chump_scratch (Layer 3d) | **DONE** (#2419 merged 2026-05-24) | bucket + 5 seed-keys live |
| INFRA-1118 NATS-primary delivery (Layer 1a umbrella) | **Open** | foundations done, umbrella tracks remaining layer work |
| INFRA-1119-1123 Layer 2b/2c/3d/3e/4f umbrellas | **Open** | each has at least one shipped foundation slice |

Conclusion: **the transport is solved.** Anything we build for v0 plugs into existing primitives, doesn't add new ones.

## 2. Root-cause analysis: why 0 replies to 3 broadcasts

Compound 3-step failure, traced in scripts/coord/broadcast.sh:

### Failure 2A — emit_to_inbox requires --to

`scripts/coord/broadcast.sh:144` `emit_to_inbox()` returns 0 immediately at line 146 when `recipient` is empty:
```bash
emit_to_inbox() {
    local recipient="$1" json="$2"
    [[ -n "$recipient" ]] || return 0    # <-- silent no-op for fan-out
    ...
}
```
Fan-out broadcasts (no `--to`) never write to any inbox file. All ~100 files in `.chump-locks/inbox/` are 0 bytes despite hundreds of broadcasts. This is by design today — but the design assumes FEEDBACK proposals are point-to-point, not fleet-wide. They aren't.

### Failure 2B — 5 of 7 curator loops have no recv code

| Loop script | inbox/feedback grep hits |
|---|---|
| `ci-audit-loop.sh` | 2 (has `_peek_inbox` for own session) |
| `handoff-loop.sh` | 3 (has inbox + addressed-DM handling) |
| `decompose-loop.sh` | **0** |
| `external-collab-loop.sh` | **0** |
| `infra-watcher-loop.sh` | **0** |
| `md-links-loop.sh` | **0** |
| `observability-loop.sh` | **0** |

Even if Failure 2A were fixed and inbox files contained content, 5 curators would never read them.

### Failure 2C — no vote / no consensus primitive

`chump vote` does not exist. No `consensus-tally` CLI. No deliberator role. Even if 2A and 2B were both fixed, a curator that wanted to vote on a proposal has no structured way to do it. Reply mechanism is missing.

**Compound effect:** every fan-out FEEDBACK kind=proposal disappears into ambient.jsonl, where it is technically grep-able by any curator who explicitly scans for it — but no curator's loop does scan for it.

## 3. v0 design — 6 slices

Each slice is independently shippable, file paths chosen for **zero edit-collision** so all 6 can dispatch in parallel via META-069 Sonnet fan-out.

### Slice 1 — broadcast.sh fan-out-to-inbox
**Files:** `scripts/coord/broadcast.sh`, `scripts/ci/test-broadcast-feedback-fanout.sh`
**Change:** when `--to` is unset AND `event=FEEDBACK` AND `kind ∈ {proposal, preference, defect, retro}`, `emit_to_inbox` expands recipient to all live curator session_ids by globbing `.chump-locks/.curator-opus-*.lock` (which gives session_ids). New `--no-fanout` flag opts out for backwards compat.
**Why first:** unblocks Failure 2A; everything downstream depends on inbox actually receiving FEEDBACK.

### Slice 2 — chump vote + consensus-tally CLIs
**Files:** `src/commands/vote.rs` (new), `src/commands/consensus_tally.rs` (new), `scripts/ci/test-chump-vote.sh`, `scripts/ci/test-chump-consensus-tally.sh`
**Change:**
- `chump vote <corr_id> <+1|-1|0> --reason <text>` emits `FEEDBACK kind=vote` to ambient + NATS (no new transport — same `emit_to_nats` path)
- `chump consensus-tally [--corr-id X | --all]` aggregates votes per corr_id from last 24h, prints rolling result + verdict
**Why parallel-safe:** new files only, no shared edits with other slices.

### Slice 3 — decompose-loop.sh drain phase
**Files:** `scripts/coord/decompose-loop.sh`, `scripts/ci/test-decompose-loop.sh` (extended)
**Change:** add Phase 0 `_drain_inbox` + `_peek_pending_feedback` matching the ci-audit pattern. Loop tick exits 0 (actionable) when actionable proposals found.
**Why parallel-safe:** edits only `decompose-loop.sh` (Slice 4's loops are different files).

### Slice 4 — recv code for the 4 remaining dark loops
**Files:** `scripts/coord/external-collab-loop.sh`, `scripts/coord/infra-watcher-loop.sh`, `scripts/coord/md-links-loop.sh`, `scripts/coord/observability-loop.sh`, plus their `scripts/ci/test-*-loop.sh` extensions
**Change:** apply the same Phase 0 pattern as Slice 3 to the 4 loops still missing recv code.
**Why parallel-safe:** distinct files from Slice 3.

### Slice 5 — curator-opus-deliberator role
**Files:** `.claude/agents/deliberator.md` (new), `scripts/coord/deliberator-loop.sh` (new), `.chump/launchd/com.chump.deliberator.plist` (new), `scripts/ci/test-deliberator-loop.sh`
**Change:**
- New role doc + harness-neutral loop CLI per the role-productization template (mirrors ci-audit / handoff / target)
- Runs every 30 min via launchd plist
- Reads `FEEDBACK kind=proposal` events from ambient, tallies votes by `corr_id`, emits `kind=consensus_result {corr_id, verdict ∈ (passed|failed|no_quorum|extended), vote_counts, voters}` after deadline
- Escalates to operator via OPERATOR_RECALL on `no_quorum AND deadline+24h elapsed`
**Why parallel-safe:** all-new files.

### Slice 6 — capability registration
**Files:** all 7 curator loops (small append), `scripts/ci/test-capability-registration.sh`
**Change:** each curator loop on startup publishes manifest to NATS KV `chump_scratch` bucket key `fleet.<role>.capabilities` (matches INFRA-1760/1761 contract).  Deliberator queries this to compute quorum count (= number of capability-registered curators).
**Why last (small conflict-risk):** Slices 3 + 4 already edit the 5 loops; Slice 6 needs to land **after** them. Sequenced.

### End-to-end test (Slice 5 includes, or separate)
**File:** `scripts/ci/test-fleet-recv-side-e2e.sh`
**Change:** starts tmp NATS, dispatches 1 broadcaster + 5 mock curator loops + 1 deliberator, asserts `kind=consensus_result` emitted with correct verdict.

## 4. Dispatch plan (META-069 Sonnet fleet)

Opus PM (this session) dispatches 5 Sonnet sub-agents in parallel via the `Agent` tool — Slices 1, 2, 3, 4, 5 — each with the SUBAGENT_DISPATCH.md epilogue + pre-push checklist baked in. Slice 6 waits for Slices 3+4 to ship.

| Slice | Dispatched as | Wave |
|---|---|---|
| 1 | sonnet via Agent (Rust+shell, ~120 LOC) | 1 |
| 2 | sonnet via Agent (Rust crate, ~180 LOC) | 1 |
| 3 | sonnet via Agent (shell, ~80 LOC) | 1 |
| 4 | sonnet via Agent (shell × 4 loops, ~250 LOC) | 1 |
| 5 | sonnet via Agent (shell + launchd, ~200 LOC) | 1 |
| 6 | sonnet via Agent (shell append + KV write) | 2 (after 3+4) |

Each sub-agent claims its own gap (META-157-a through META-157-f reserved before dispatch), gets its own worktree (collision-free), commits via chump-commit.sh, ships via bot-merge.sh (post-INFRA-156 visibility fix — or with `CHUMP_OPERATOR_RECOVERY=1` manual fallback if bot-merge still hangs).

## 5. Rollout

Behind feature flag `CHUMP_FLEET_RECV_SIDE_V0` (default **OFF**) until E2E test green. Flag flip in a follow-up PR after at least 24h soak with the feature ON on the operator's local fleet.

## 6. What this design explicitly does NOT include

- New transport (NATS already running)
- MCP server (separate productization; tracked in a future META)
- Full INFRA-1118 layer-1a completion (this v0 sits on top of the foundations, doesn't finish the umbrella)
- Shared KV scratchpad expansion beyond capabilities (INFRA-1121 is its own umbrella)
- Signed provenance (INFRA-1123 is its own umbrella)
- Cross-machine federation (single-machine fleet for v0)

## 7. Meta-recursive proof gate

After this design doc lands as a PR and the operator signs off, broadcast `FEEDBACK kind=proposal` for META-157 itself. This is the FIRST broadcast that tests fan-out-to-inbox post-Slice-1. If consensus_result fires within 48h of the broadcast, v0 self-proves. If not, we have a bug in the loop and we fix that before adding more recv-side features.

## 8. Operator sign-off

This doc requires operator sign-off before fleet dispatch begins. Sign-off is recorded as a `Reviewed-By: <operator-id>` trailer on the PR landing this design doc.

---

**Next step after sign-off:** reserve 6 sub-slice gaps META-157-a through META-157-f, then dispatch 5 Sonnet sub-agents in parallel for wave 1.
