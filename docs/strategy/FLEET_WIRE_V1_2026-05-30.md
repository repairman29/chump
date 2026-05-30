# Fleet wire v1 — best-in-class agent comms/OS

**Date:** 2026-05-30
**Author:** ci-audit-onboarding Opus session (chump-Chump-1776471708)
**Umbrella:** META-167
**Status:** Design — dispatching slices in parallel post-merge

---

## TL;DR

The recv-side v0 (META-157 wave, merged 2026-05-30T05:48-06:35Z) proved **delivery works** end-to-end — META-RECURSIVE PROOF V3 at 07:37Z fired `feedback_fanout_delivered recipient_count=2`. But **reply-back doesn't yet**:

- Peers can READ broadcasts via INFRA-2262 tick-preamble (300s cycle)
- Peers cannot AUTO-REPLY because no reactor logic exists per role (META-155 HOLD-until-design)
- Latency is 300s file-tick, not sub-second push
- Capabilities aren't published, so broadcaster can't filter offline curators
- Sub-agents have to learn shell + envvars to use the wire
- Restart-safe replay isn't wired

v1 fixes all 5. Behind feature flag `CHUMP_FLEET_WIRE_V1` (default OFF until E2E green).

## 1. The 5 gaps from best-in-class

| # | Today | Best-in-class | Gap |
|---|---|---|---|
| 1 | Read-only | Erlang/OTP gen_server with per-(role × kind) reaction table | **META-155 reactor table** |
| 2 | 300s file tick | inotify/kqueue sub-second wake + NATS JetStream push subscribe | **Push latency** |
| 3 | No capability registry | NATS KV chump_capabilities (INFRA-1761 already shipped, unused by curators) | **Capability publish per role** |
| 4 | Shell + envvars | MCP server `mcp__chump_fleet__{inbox_drain, broadcast, vote, consensus_status, capabilities}` | **MCP surface** |
| 5 | At-most-once file delivery | JetStream durable consumer + explicit ack + replay on restart | **Durable consumers** |

## 2. Reactor table — the heart of v1

Each curator-loop's tick body grows a Phase 1.5 (between Phase 0 inbox-drain and the existing Phase 1+ work):

```bash
# Phase 1.5 — react to fresh broadcasts in inbox
for event in $(read_inbox_since_cursor); do
    kind="$(jq -r .kind <<< "$event")"
    corr_id="$(jq -r .corr_id <<< "$event")"

    # Dedupe: skip if already voted on this corr_id in last 1h
    [[ -f .chump-locks/<role>-vote-cooldown/$corr_id ]] && continue
    age=$(($(date +%s) - $(stat -f %m .chump-locks/<role>-vote-cooldown/$corr_id 2>/dev/null || echo 0)))
    (( age < 3600 )) && continue

    case "$kind" in
        proposal) vote=$(_decide_proposal "$event") ;;
        preference) vote=$(_decide_preference "$event") ;;
        defect) vote=$(_decide_defect "$event") ;;
        retro) vote=$(_decide_retro "$event") ;;
        *) continue ;;
    esac

    chump vote "$corr_id" "$vote" --reason "<role>: <reasoning>"
    mkdir -p .chump-locks/<role>-vote-cooldown && touch .chump-locks/<role>-vote-cooldown/$corr_id
done
```

### Per-role reaction matrix

| Role | Subscribes (kind in) | Vote-decision logic | Cooldown |
|---|---|---|---|
| **decompose** | proposal | +1 if (AC count ≥ 3 AND status=open AND no existing sub-gaps); -1 if AC vague | 1h per corr_id |
| **ci-audit** | proposal that references regression_attributed kind in description | per blame-bot suspect_commits count; cross-ref current CI cluster via tick subcommand | 30 min |
| **handoff** | proposal that proposes new Contract type or modifies existing | +1 if Contract schema well-formed (Input/Output/Validate/prompt/ModelTier present); -1 if overlaps existing | 1h |
| **target** | proposal touching demo-target gap or META-074 children | +1 per pillar-alignment with active demo-target; 0 otherwise | 2h |
| **shepherd** | proposal that proposes a new wedge-class or fleet-rescue pattern | +1 per existing wedge-class match (VOA-001 schema); -1 if reinvents existing rescue | 1h |
| **md-links** | proposal that touches docs/ | +1 lane match; -1 otherwise | 6h |
| **observability** | proposal mentioning ambient kinds, registry, daemons, telemetry | +1 if measurable per existing observability primitives | 4h |
| **infra-watcher** | proposal mentioning runner / daemon / disk / claude-proc health | +1 if matches substrate concern | 4h |
| **external-collab** | proposal mentioning Marcus / PITCH / partnership | +1 per Marcus arc alignment | 6h |
| **deliberator** | NEVER vote (META-162 lane: only tallies + emits consensus_result) | n/a | n/a |

### Dedupe + cooldown

- Per-corr_id cooldown: prevents same curator voting twice on same proposal
- Cooldown TTL varies by role (see matrix above)
- Stored as filename mtime in `.chump-locks/<role>-vote-cooldown/<corr_id>`
- Cleaned up by stale-vote-cooldown-reaper (separate launchd plist, sweep > 7d)

### Anti-reaction-loop guard

- A curator MUST NOT react to a `kind=vote` event (only `kind=proposal/preference/defect/retro`)
- A curator MUST NOT react to its own broadcasts (broadcaster_session_id == self → skip)
- A curator MUST NOT react if `kind=consensus_result` has already fired for that corr_id

## 3. Push latency — sub-second wake

### Mechanism

- Linux: `inotifywait -m -e modify .chump-locks/inbox/<self>.jsonl`
- macOS: `fswatch --event=Updated .chump-locks/inbox/<self>.jsonl`
- On event → send SIGUSR1 to parent curator-loop PID
- Curator-loop traps SIGUSR1 → immediately runs Phase 0 + 1.5 (without waiting for 300s tick)

### Implementation

`scripts/coord/lib/inbox-watcher.sh`:
- Background helper started by each curator-loop at startup
- Exits cleanly on parent EXIT (via `_setup_inbox_watcher_trap`)
- Falls back to 300s polling if watcher tool unavailable

### Acceptance signal

Broadcaster emits FEEDBACK at T0 → expect first vote within **5 seconds** with push enabled (was 300s with cron only).

## 4. Capability publish — "who can do what right now"

Each curator-loop at startup writes a `CapabilityManifest` (chump-capability-v1 schema, shipped via INFRA-1760) to NATS KV bucket `chump_capabilities`:

```json
{
  "schema_version": "chump-capability-v1",
  "session_id": "curator-opus-ci-audit-2026-05-30",
  "role": "ci-audit",
  "model_tier": "Opus",
  "skills": ["ci", "test-gates", "blame-bot", "audit"],
  "last_seen_at": "2026-05-30T07:50:00Z",
  "ttl_seconds": 300
}
```

Refreshed every 30s via heartbeat (already wired in each curator-loop). Broadcaster reads bucket pre-fanout to filter offline curators (TTL expired).

**Why this matters:** today, fan-out sends to ALL `.curator-opus-*.lock` sentinels. With capability publish + filter, broadcaster can scope by role-set ("only ci-audit + handoff") or skill-set ("anyone who can do Rust").

## 5. MCP surface — agent OS for free

New crate: `crates/chump-mcp-fleet/`

Exposes 5 MCP tools any Claude (or other MCP-compatible) instance gets automatically:

| Tool | Purpose |
|---|---|
| `mcp__chump_fleet__inbox_drain` | Read pending inbox events for caller session |
| `mcp__chump_fleet__broadcast` | Emit a FEEDBACK kind=proposal (or vote / preference / defect) |
| `mcp__chump_fleet__vote` | Cast a +1/-1/0 vote on a corr_id |
| `mcp__chump_fleet__consensus_status` | Check current vote tally + verdict for a corr_id |
| `mcp__chump_fleet__capabilities` | List currently online curators with capabilities |

Transport: stdio for Claude Code; Unix socket for daemonized callers. Integrates with existing `chump-mcp-lifecycle` crate.

**Why this matters:** sub-agents I dispatched today had to learn shell + envvars + broadcast.sh signature quirks. With MCP, every Claude instance gets the fleet OS without any shell knowledge.

## 6. JetStream durable consumers — restart-safe

Today: a curator restarts → missed broadcasts are LOST (file inbox is read-since-cursor; if curator dies before reading, those events are still in the file but cursor doesn't advance).

v1: each curator-loop subscribes to a NATS JetStream durable consumer:

```rust
let consumer = jetstream
    .get_or_create_consumer(
        "chump_events",
        consumer::Config {
            durable_name: Some(format!("chump-fleet-{}", role)),
            ack_policy: AckPolicy::Explicit,
            ..Default::default()
        },
    )
    .await?;
```

- Durable: cursor persists across consumer restart
- Explicit ack: only advance cursor after reactor processes the event
- Replay: on restart, immediately catches up on missed events

File inbox stays as fallback when NATS unavailable.

**Observability dashboard panel** (PWA cockpit): per-role consumer lag + delivery latency p50/p99.

## 7. Rollout — 5-day, parallel

| Day | Wave | Slices | Mode |
|---|---|---|---|
| **0 (TODAY)** | Design + umbrella | a (this doc) | Solo Opus |
| **1** | Reactors | b decompose / c ci-audit / d handoff / e bundle (target/shepherd/md-links) | 4 Sonnets parallel |
| **2** | Push + capability | f inbox-watcher / g capability publish | 2 Sonnets parallel |
| **3** | MCP | h mcp-fleet crate | 1 Sonnet |
| **4** | JetStream + obs | i durable consumers + PWA panel | 1 Sonnet |

Each slice ships behind `CHUMP_FLEET_WIRE_V1=1` env flag, default OFF. Flag flip in a follow-up PR after E2E proof + 24h soak.

## 8. E2E proof — closing the umbrella

After all 9 slices land, broadcast a FEEDBACK kind=proposal with corr_id=`META-167-E2E`. Assert within 30 seconds:

1. ≥ 5 `kind=vote` events with `corr_id=META-167-E2E` (one per reacting curator)
2. `kind=consensus_result {corr_id=META-167-E2E, verdict=PASSED, voters_list=[…]}`
3. P50 delivery latency from broadcaster → first vote < 5 seconds (with push enabled)

If proof passes: file follow-up flip-flag PR; close META-167 with `closed_pr=<PR>`.
If proof fails: file follow-up gap for the specific breakage; keep META-167 open.

## 9. Out of scope for v1

- **Signed provenance** (INFRA-1123 / Layer 4f) — defer to v2; trust-anchor + key rotation is a separate body of work
- **Cross-machine federation** — INFRA-1825 mesh-bridge maturation handles this; v1 is single-machine
- **Backpressure-aware broadcaster** — file follow-up META gap once we observe queue-depth issues in production
- **Reaction confidence + retraction** — vote dedupe handles 80%; "I changed my mind" semantics are a separate design

## 10. Open questions for fleet feedback

Tracked under corr_id `META-167-DESIGN-Q`:

1. Should curators react to FEEDBACK from THEIR OWN session? (Default: NO; explicit `broadcaster_session_id != self`)
2. Should curators with capability TTL-expired (offline > 5min) still receive fan-out? (Default: NO; broadcaster pre-filters)
3. Should `chump vote` allow a curator to vote multiple times on the same corr_id with progressively-strengthened reasoning? (Default: NO; cooldown blocks)
4. Should there be a per-corr_id deadline on the FEEDBACK proposal itself, after which no votes count? (Default: YES, 24h; configurable)

Vote any of these via `chump vote META-167-DESIGN-Q <+1/-1/0> --reason "Q<N>: <answer>"`.

---

**Next step after this design lands:** dispatch Wave 1 (4 Sonnets parallel — reactors b/c/d/e).
