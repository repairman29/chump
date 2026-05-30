# Trunk-cascade recovery — when and how to use `break-trunk-cascade`

> **TL;DR.** A trunk-RED cascade is the rare situation where N PRs in the
> queue are each blocking each other because the fix for wedge A lives
> in a PR that needs wedge B fixed first, and vice versa. The
> `scripts/ops/break-trunk-cascade.sh` operator-button collapses the
> standard manual recovery (drop required checks → admin-merge → restore)
> into one atomic command with a `trap EXIT` guarantee that protections
> are restored even if the script is killed mid-flight. **Use very
> sparingly — every invocation emits `kind=trunk_cascade_broken` to
> ambient and is rate-limited.**

## When to use this command

Use **only** for genuine circular-dependency cascades:

- Three or more PRs all BLOCKED with `mergeable=true`, `autoMergeRequest != null`, 0 fails AND 0 pending — the queue is waiting on a required check that will never run on the open PRs (path-filter exclusion, broken workflow, etc.).
- A required check has been failing on every queued PR for over an hour and the fix sits in the queue itself.
- A workflow file syntax error or stuck self-hosted runner is preventing required checks from emitting at all.

You can usually tell it's a real cascade because the wedge **can't be fixed by linearizing the queue** (rebasing the front-of-queue PR onto main and waiting for CI). Linearizing also fails.

## When NOT to use this command

This is the most important section. The wrong reflex is to use cascade-break for everything that's slow.

- **Single-PR failure** — one PR's CI is genuinely red because the diff is broken. Fix the diff. Push the fix to the same branch. Wait the 5 minutes for CI to re-run. Do not bypass.
- **Slow CI** — if checks are pending and just take a while, wait. The cron isn't a stuck-state signal; the run-list is.
- **You don't understand what's failing** — Pattern 14 verify-before-alarm in `SHEPHERD_LOOP_PLAYBOOK.md`. Look at the PR's `statusCheckRollup` with the per-check `.workflowName`. Find the actual failing check. Often the apparent wedge is just a noisy workflow that doesn't gate the merge.
- **Single PR with one bad shard** — fix the shard's diff or wait for the next CI cycle. Don't reach for the bypass.
- **You are inside a `/loop` and "want to keep things moving"** — Pattern 15's "no idle curators" norm does NOT authorize use of cascade-break as a default action. Cascade-break costs a real safety guarantee (required-check enforcement) for the bypass window.

## Use

```bash
scripts/ops/break-trunk-cascade.sh --pr <N> --reason "<one-line-why>"
```

Required flags:

- `--pr <N>` — the PR to merge through the bypass.
- `--reason "..."` — one-line operator reason. Lands in the ambient audit log and the rate-limit history. **Do not invoke without a real reason.**

Optional:

- `--propagation-wait <sec>` (default 5) — seconds to wait between drop and merge for GitHub's protection state to settle.
- `--dry-run` — print what would happen; no API mutations.
- `--i-know-what-im-doing` — skip the "PR has auto-merge ARMED" sanity check.
- `--repo <owner/repo>` — override the auto-detected repo.

## What the script guarantees

| Guarantee | How |
|---|---|
| Restore always fires | `trap restore_protections EXIT INT TERM` — even SIGKILL parent triggers child restore via shell exit semantics |
| Restore captures the live state, not a stale snapshot | Reads `repos/{owner}/{repo}/branches/main/protection/required_status_checks` and every active ruleset's `required_status_checks` rule into `$SNAPSHOT_DIR` at runtime |
| Rate-limited to prevent abuse | `CHUMP_BREAK_CASCADE_PER_HOUR` (default 1). History at `.chump-locks/break-cascade-history.jsonl` |
| Audit trail | Emits `kind=trunk_cascade_broken` with `pr`, `reason`, `snapshot_contexts`, `bypass_duration_ms`, `session` |
| Refuse on missing preconditions | PR must be OPEN + have auto-merge ARMED (override with `--i-know-what-im-doing`) |

## Post-recovery responsibilities

After a successful cascade-break:

1. **File gaps for every wedge that was bypassed.** The cascade landed without each wedge being independently fixed. Each one is now a latent risk on main; file an INFRA gap per wedge with the symptom + suggested fix.
2. **Verify the restore landed.** `gh api repos/<owner>/<repo>/rulesets/<id>` should show the original `required_status_checks` rule reattached. The `fleet-doctor-strict.sh` `check_required_status_checks` invariant (INFRA-2201) will alert if not.
3. **Update the post-mortem.** The ambient `trunk_cascade_broken` event is the ground-truth audit record; reference it in any synthesis or post-mortem doc.

## Sibling docs

- `docs/process/SHEPHERD_LOOP_PLAYBOOK.md` — Pattern 14 (verify-before-alarm) and Pattern 15 (no idle curators) govern when this command is the right choice
- `scripts/ops/admin-merge-cycle.sh` — older sibling that uses checked-in snapshot JSONs rather than live-snapshotted state; superseded by this command for ad-hoc cascade-break (admin-merge-cycle remains for declared noise-class merges per RESILIENT-031)
- `scripts/coord/fleet-doctor-strict.sh` — `check_required_status_checks` catches the empty-state if restore fails
