# Call criticality + GraphQL exhaustion handling (INFRA-1080 / INFRA-1040 / INFRA-1079)

Moved out of `AGENTS.md` / `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).

`chump_gh` (the gh wrapper in `scripts/coord/lib/github.sh`) classifies
each call as **critical** (default) or **background**. Background calls
are preempted when `remaining_graphql < CHUMP_GH_BACKOFF_THRESHOLD%`
(default 10%) so critical-path operations never starve.

```bash
chump_gh pr merge "$PR" --auto --squash                          # critical (default)
CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list ...         # background — yields when tight
```

| Critical (default) | Background (opt-in) |
|---|---|
| `gh pr create` / `gh pr merge` | label updates |
| `gh pr update-branch` | overlap scans |
| ship-blocking REST writes | dashboard refreshes |
| operator-initiated rescue | cache reconcile per-PR fetches |

## GraphQL exhaustion handling

Automated:
- **Secondary rate-limit self-throttle** — caps fleet calls to
  `CHUMP_GH_MAX_CALLS_PER_MIN` (default 60) via a shared sliding window.
  Per-script override: `CHUMP_GH_THROTTLE_<UPPERCASE_SCRIPT>=N`.
- **Exhaustion signal** — first call to see `remaining_graphql ≤ 100` emits
  `kind=graphql_exhausted` to `ambient.jsonl` (debounced once per reset
  window). Every agent watching ambient pivots to REST-only paths.

When you see repeated `kind=graphql_exhausted` / `kind=gh_self_throttled`:
1. `scripts/dev/api-cost-leaderboard.sh --window 1h` to find the burner.
2. Background-tag the noisiest non-critical caller.
3. If structural, file a follow-up gap migrating that caller to
   `cache_lookup_*` helpers.
