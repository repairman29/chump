---
name: verify-existence
description: Tri-state existence check for a gap ID, Rust symbol, endpoint, script, or any artifact name. Returns "confirmed_shipped" (multiple positive signals), "confirmed_absent" (no signals), or "ambiguous" (single signal — investigate manually). Use BEFORE filing any "feature X is missing" gap to avoid the misdiagnosis class precedented by INFRA-1575 and INFRA-238 (claimed 10 A2A gaps missing when all had shipped; claimed origin/main reverted without git fetch). Thin wrapper over harness-neutral CLI at `scripts/dev/verify-existence.sh` (INFRA-1589). Supports `--json` for structured output. Per `.claude/README.md` pattern.
user-invocable: true
allowed-tools:
  - Bash
---

# /verify-existence — Tri-State Existence Check

Canonical surface: [`scripts/dev/verify-existence.sh`](../../../scripts/dev/verify-existence.sh) (INFRA-1589). Any harness invokes the same script.

## When to invoke this skill

Before filing ANY gap claiming "feature X is missing / broken / unfiled." `chump gap show <ID>` returns "not found" both for typos AND for gaps that shipped and were reaped — the silence is ambiguous. This skill resolves the ambiguity.

This is the guard documented in [`AGENTS.md`](../../../AGENTS.md) "Runtime verification before missing-claim" — `INFRA-1575` (10 A2A gaps misdiagnosed as missing) and `INFRA-238` (origin/main "reverted" without verification) are the cautionary precedents.

## Routing

Arguments passed: `$ARGUMENTS` — accept either a single token (gap ID, symbol, endpoint, script name) or `--json <token>`.

```bash
scripts/dev/verify-existence.sh $ARGUMENTS
```

## Exit code is the answer — surface it

| Exit | Meaning | What to do |
|---|---|---|
| 0 | `confirmed_shipped` — multiple positive signals across checks | DO NOT file a "missing" gap. Search git log for the implementing PR if context is needed. |
| 1 | `confirmed_absent` — no signal in any check | File the gap. (You verified — this is real.) |
| 2 | `ambiguous` — exactly one positive signal | Investigate manually before filing. Look at the specific signal that fired. |

## Examples (pass any of these to the skill)

```
INFRA-1296          # shipped gap (reaped from active registry)
build_provider      # Rust symbol
/api/broadcast      # endpoint
broadcast.sh        # script
```

## When NOT to use this

- For "is this gap currently in the open queue?" — use `chump gap show <ID>` (the simple lookup is enough)
- For PR state — use `gh pr view <N>` or the cache helpers (`cache_lookup_pr`)
- For arbitrary string search — use `grep -rn` directly; this skill is for structured existence claims, not exploration
