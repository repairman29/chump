# Cascade rebase — how the fleet keeps open PRs current after a hot-file commit

> **Status:** stable. Last updated 2026-05-30 (INFRA-2255 added the
> auto-resolve add-both fallback).

When a commit lands on `main` that touches a **workspace-hot file**
(see `scripts/coord/cascade-rebase-trigger-paths.txt`), every open
non-draft PR becomes BEHIND simultaneously. Manually clicking "Update
branch" on each one wastes hours. The cascade-rebase machinery does it
in one sweep.

## Trigger path

1. Worker tick runs `scripts/coord/queue-driver.sh`.
2. `cascade_rebase_if_hot` reads `git diff HEAD~1..HEAD --name-only`.
3. If any changed file appears in `cascade-rebase-trigger-paths.txt`
   (extended by INFRA-711 from the original Cargo.toml-only check), the
   cascade fires.
4. **Per-SHA debounce lock** (INFRA-1310): only one worker actually
   runs the cascade for a given commit SHA. The rest emit
   `kind=cascade_rebase_skipped_duplicate` and bail. Lock auto-expires
   after 10 min.

## Three resolution paths (in order)

For each open non-draft PR, the cascade tries these in order:

### 1. Server-side fast-forward — `gh pr update-branch`

GitHub does an in-place merge of `main` onto the PR branch. Fast,
no local checkout. Works for the BEHIND-but-not-DIRTY case (the PR
diff doesn't conflict with anything that landed on main).

Failure mode: server-side update-branch returns non-zero whenever the
merge would conflict, even if the conflict is purely additive (two
PRs both appending to `event-registry-reserved.txt`). Pre-INFRA-2255
that's where the cascade gave up and the PR sat DIRTY.

### 2. Local rebase + auto-resolve add-both — `cascade_auto_resolve_pr` (INFRA-2255)

When (1) fails, the queue-driver attempts a local rebase:

1. Worktree the PR branch into a scratch directory.
2. `git rebase origin/main`.
3. If `Successfully rebased` → push, done.
4. Otherwise, classify each conflicting file:
   - **In the auto-resolve allowlist?** Strip conflict markers in-place
     via `scripts/coord/auto-resolve-add-both.sh`, which preserves
     content from BOTH sides (additive merge).
   - **Outside the allowlist?** Abort the rebase, emit
     `kind=cascade_resolve_skipped_semantic`, leave the PR for the human.

The auto-resolve allowlist is the **closed set** of append-only files
that historically caused most cascade failures:

| File | Why append-only |
|---|---|
| `scripts/ci/event-registry-reserved.txt` | One line per reserved ambient event-kind; new entries get appended below existing ones. |
| `Cargo.toml` (workspace members) | New crates get appended to the `[workspace].members` list. |
| `docs/observability/EVENT_REGISTRY.yaml` | Per-kind YAML entries appended; merge driver `union` covers most but cascade falls back here too. |
| `scripts/setup/bootstrap-manifest.yaml` | New manifest items appended. |
| `scripts/coord/cascade-rebase-trigger-paths.txt` | New paths added as cascade triggers. |

Files outside this allowlist are treated as semantic conflicts even if
their diff looks additive — the script intentionally errs on the side
of escalating to the human.

On success: `kind=cascade_auto_resolved {pr, file_count, files}` is
emitted to `ambient.jsonl`, the PR is force-pushed with `--force-with-lease`,
and the cascade moves to the next PR.

### 3. Operator escalation

If (1) AND (2) both fail (or (2) was skipped because of a semantic
conflict), the cascade just reports failure for that PR. The operator
or a follow-up `resolve_dirty_pr` invocation (INFRA-1137, the DIRTY
auto-resolver that uses `.gitattributes` merge drivers — different
machinery) takes over.

## Event-kind summary

| Event kind | Emitted when | Consumer |
|---|---|---|
| `cascade_rebase_triggered` | Sweep starts. Reports `pr_ok`, `pr_fail`, `auto_resolved`. | audit-log |
| `cascade_rebase_skipped_duplicate` | Worker lost the per-SHA debounce race. | audit-log |
| `cascade_auto_resolved` (INFRA-2255) | Local rebase + allowlist auto-resolve succeeded on a PR. | audit-log, fleet-brief |
| `cascade_resolve_skipped_semantic` (INFRA-2255) | At least one conflict was outside the allowlist; cascade refused to touch the PR. | audit-log, operator-recall |

## Extending the allowlist

Both the script (`scripts/coord/auto-resolve-add-both.sh`) and the
queue-driver classifier (`cascade_auto_resolve_pr` in
`scripts/coord/queue-driver.sh`) hard-code the file list. To add a new
file:

1. Append it to `ALLOWLIST_PATHS` and `ALLOWLIST_BASENAMES` in the
   script.
2. Append it to the `case $f in ... esac` classifier in the
   queue-driver.
3. Add a fixture + assertion in
   `scripts/ci/test-auto-resolve-add-both.sh`.

Files with a configured merge driver in `.gitattributes` (Cargo.toml's
`cargo-toml-append`, the YAML registries' `union`, etc.) are handled
by the merge-driver layer first — the cascade auto-resolver is the
*secondary* fallback that fires when the driver can't run (because the
conflict surfaced during `git rebase`, not during a `git merge`).

## Related machinery

- `scripts/dev/take-both-resolve.py` (INFRA-1920) — operator hand-tool
  for the same shape, used for ad-hoc mass-rescues. The
  `auto-resolve-add-both.sh` script is the fleet-automated equivalent.
- `resolve_dirty_pr` in `queue-driver.sh` (INFRA-1137) — separate path
  for DIRTY PRs with auto-merge armed; uses `.gitattributes` merge
  drivers, not the allowlist.
- `scripts/coord/cascade-rebase-trigger-paths.txt` (INFRA-711) — the
  config that decides which main-branch commits trigger cascade.

## Why this matters

Before INFRA-2255, cascade fired and then ~half the open PRs went
DIRTY because of add-both conflicts on `event-registry-reserved.txt`
specifically. A human (usually the operator) ran the same 5-step
rebase + take-both + push recipe 6-12 times per day. Three
person-hours per week, every week.

Auto-resolve closes that loop: the fleet handles the additive case
automatically and escalates only the genuine semantic conflicts.
