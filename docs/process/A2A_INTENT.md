---
doc_tag: operator-guide
last_audited: 2026-05-13
audience: operator, fleet agents
purpose: How the INTENT-overlap gate prevents concurrent-shipping races at claim time
implements: INFRA-1116 (META-061 Layer-1 tactical)
---
# A2A INTENT — claim-time overlap enforcement

## What it does

When you (or an agent) tries to claim a gap with a declared path scope, `gap-preflight.sh` now refuses if another live session has announced INTENT on overlapping paths in the last 60 seconds. No more silent races where two agents independently ship the same gap with identical commits.

The protocol has been in `broadcast.sh`'s header comment for months ("agents should check ambient.jsonl for INTENT events from the last 5 minutes before claiming a gap"). INFRA-1116 *enforces* it instead of relying on voluntary discipline.

## Opt-in via `CHUMP_CLAIM_PATHS`

The gate is opt-in. Pass `CHUMP_CLAIM_PATHS=<csv>` to declare your path scope:

```bash
# Declare paths and run preflight
CHUMP_CLAIM_PATHS="src/main.rs,scripts/coord/" \
  scripts/coord/gap-preflight.sh INFRA-779

# Or for chump claim (passes through env)
CHUMP_CLAIM_PATHS="src/main.rs" chump claim INFRA-779
```

Path semantics:
- Comma-separated.
- Each path is a prefix matched against other sessions' INTENT `files`.
- Exact-equal, prefix-of, or prefixed-by all count as overlap.
- Trailing `/` is normalized.
- Path-undeclared claims SKIP the gate (back-compat with today's mostly-undeclared callers).

## Announcing your INTENT

After your claim succeeds, announce INTENT so the next agent's preflight sees you:

```bash
scripts/coord/intent-announce.sh INFRA-779 "src/main.rs,scripts/coord/"
```

This is best-effort — failure to emit doesn't block your work. v1 hooks INTENT-emit into `chump claim` itself so it happens automatically post-success.

## On overlap detected

Output looks like:

```
[intent-gate] OVERLAP detected — refusing claim
[intent-gate]   session=claim-infra-986-12345
[intent-gate]     gap=INFRA-986  paths=src/main.rs,scripts/coord/
[intent-gate]     announced=2026-05-13T22:30:00Z
[intent-gate]   my paths: src/main.rs
[intent-gate] Next steps:
[intent-gate]   wait — re-run preflight after 60s (their INTENT may expire)
[intent-gate]   ping — scripts/coord/broadcast.sh --to claim-infra-986-12345 ALERT kind=overlap '<message>'
[intent-gate]   force — CHUMP_CLAIM_FORCE_OVERLAP=1 CHUMP_CLAIM_OVERRIDE_REASON='<text>' chump claim ...
```

Three coordination paths:

1. **Wait.** INTENT events expire after `CHUMP_CLAIM_INTENT_WINDOW_S` (default 60s). If the other agent legitimately gave up or moved on, you'll be clear shortly.
2. **Ping.** Use the mailbox (INFRA-1115) to alert the holding session — they may HANDOFF to you, retract their INTENT, or just confirm they're still working.
3. **Force.** Operator escape hatch:
   ```bash
   CHUMP_CLAIM_FORCE_OVERLAP=1 \
   CHUMP_CLAIM_OVERRIDE_REASON="cherry-pick — I'm completing their abandoned WIP" \
     chump claim INFRA-779
   ```
   The reason is required (without it: "(no reason given)") and written to `ambient.jsonl` as `intent_overlap_overridden` for audit.

## Stale-session filter

The gate ignores INTENTs from sessions whose lease file is missing OR whose lease has expired. So an agent that announced INTENT and then died doesn't block forever — their lease expiry frees the gate.

## What's NOT enforced yet (v1+)

| Feature | Tracker |
|---|---|
| `chump claim` (Rust) integration alongside the shell preflight gate | follow-up gap |
| Auto-emit INTENT on successful `chump claim` (currently best-effort via `intent-announce.sh`) | follow-up |
| Wildcard INTENT (`paths=**`) refusing all subsequent claims | INFRA-1116 v1 AC |
| INTENT refresh on long-running work (currently expires at window TTL) | INFRA-1116 v1 AC |
| Two-phase commit via RPC (ask the holder before refusing) | Layer 2b INFRA-1119 |
| Cross-machine INTENT visibility | Layer 1a INFRA-1118 (NATS-primary) |
| `chump-commit.sh` INTENT-on-staged-paths | INFRA-1116 v1 AC |

Each tracked in INFRA-1116's full AC.

## Events emitted

- `intent_overlap_detected` — gate refused a claim. Fields: `{ts, kind, session, gap, my_paths, conflicting}`. Surfaces in `waste-tally` so the operator can see how often the gate fires.
- `intent_overlap_overridden` — operator bypassed via `CHUMP_CLAIM_FORCE_OVERLAP=1`. Fields: `{ts, kind, session, gap, paths, reason}`. Surfaces in audit-priorities to flag repeat-bypass patterns.

Both registered in `docs/observability/EVENT_REGISTRY.yaml`.

## Performance + scale

The gate scans `ambient.jsonl` once per preflight invocation. For a 1-MB file with ~3000 events, the python parse is ~50ms p99. Future Layer 1a (INFRA-1118) NATS-primary shifts this to a push subscription with no file scan.

## Threat model (v0)

In-fleet trust assumed (operator runs all sessions on the host). Any agent can write any INTENT on behalf of any other session — the file is world-readable + world-writable within `.chump-locks/`. Layer 4f (INFRA-1123) signed provenance closes this hole; for v1 single-machine deployments, the trust model is fine.

## See also

- [`scripts/coord/intent-overlap-check.sh`](../../scripts/coord/intent-overlap-check.sh) — gate logic
- [`scripts/coord/intent-announce.sh`](../../scripts/coord/intent-announce.sh) — emit INTENT
- [`scripts/coord/gap-preflight.sh`](../../scripts/coord/gap-preflight.sh) — caller integration
- [`scripts/ci/test-intent-overlap-gate.sh`](../../scripts/ci/test-intent-overlap-gate.sh) — 9-assertion test
- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — six-layer context
- [`docs/process/A2A_MAILBOX.md`](./A2A_MAILBOX.md) — sibling tactical primitive (INFRA-1115)
- [`docs/process/PR_NUDGE.md`](./PR_NUDGE.md) — sibling tactical primitive (INFRA-1117)
