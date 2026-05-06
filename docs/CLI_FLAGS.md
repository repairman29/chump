# chump CLI flags reference

## `--why`

Adds a one-line transparency annotation to stderr after any action, explaining the non-obvious
choice the CLI just made. Useful for operators and fleet agents tracing routing decisions.

**Supported commands:**

| Command | Example output |
|---|---|
| `chump gap reserve --why` | `reserved INFRA-042 — why: collision-free atomic ID pick from domain INFRA pool (INFRA-216 verification window)` |
| `chump gap claim <ID> --why` | `claimed INFRA-042 — why: gap open and unclaimed, session=my-session, TTL=3600s` |
| `chump gap ship <ID> --why` | `shipped INFRA-042 — why: status flipped to done, closed-pr=#1234, session=my-session` |
| `chump --once --why` | `cascade chose slot=cerebras — why: bandit selection, RPD 28% used, priority=10` |

**Format:** `<action> <ID> — why: <one-line rationale>`

All `--why` output goes to **stderr** so stdout remains parseable (bare gap IDs, JSON, etc.).

## `--once`

Alias for `--autonomy-once`. Runs one autonomy round and exits. Combine with `--why` to see
which cascade slot was selected before the round begins:

```bash
chump --once --why
```

## `--quiet`

Suppresses progress lines (`chump gap reserve`). Stdout still contains the bare gap ID.
