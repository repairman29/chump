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

Suppresses all output on success; exits 0 with no stdout. Useful for scripting where you want
to know if a command succeeded without noisy progress lines.

**Supported commands:** (EFFECTIVE-008)

| Command | Behavior |
|---|---|
| `chump gap reserve --quiet` | No output; bare gap ID is suppressed. Use `--json` instead if you need the ID. |
| `chump gap list --quiet` | No output; exits 0 if query succeeded. |

```bash
# Scripting example: check if there are open gaps without displaying them
if chump gap list --status open --quiet; then
  echo "Gap store reachable"
fi
```

## `--format`

Selects the output format for commands that support multiple rendering modes.
(EFFECTIVE-008)

**Supported values:** `human` (default), `json`, `csv`

**Supported commands:**

| Command | Example |
|---|---|
| `chump gap list --format json` | JSON array of gap objects (same as `--json`) |
| `chump gap list --format csv` | CSV with header: `id,domain,status,priority,effort,title` |
| `chump gap list --format human` | Default human-readable `[status] ID — title (P/e)` lines |

```bash
# CSV output for spreadsheet import
chump gap list --status open --format csv > gaps.csv

# JSON for jq scripting
chump gap list --json | jq '.[] | .id'
# or equivalently:
chump gap list --format json | jq '.[] | .id'
```

**Note:** `--json` and `--format json` are equivalent. `--format` takes precedence when both
are given.
