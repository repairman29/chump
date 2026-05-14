---
doc_tag: operator-guide
last_audited: 2026-05-13
audience: operator, fleet agents
purpose: How `chump pr nudge` auto-diagnoses stuck PRs and posts structured comments
implements: INFRA-1117 (META-061 Layer-1 tactical)
---
# chump pr nudge — operator + agent guide

## What it is

A tool that **diagnoses why an open PR is stuck** and posts a focused, recipe-bearing comment so the owner-agent (or operator) can land it.

Replaces the manual pattern: during the rate-limit-storm of 2026-05-13 the operator had to leave 13 nearly-identical comments on dirty PRs. This script mechanizes that loop.

Script: `scripts/coord/chump-pr-nudge.sh`.

## Diagnoses

| Class | Trigger | Template |
|---|---|---|
| `dirty` | mergeable_state=dirty (real merge conflict) | rebase recipe + REST-merge |
| `blocked-ci` | required check (`test`, `audit`, ACP smoke) has `conclusion: failure` | flake-check recipe + retry instructions |
| `base-modified` | mergeable_state=blocked but all required checks green | "main moved, retry merge" |
| `clean-not-merged` | mergeable_state=clean (or unstable with required green) AND no auto-merge armed | REST-merge command |
| `orphan-disarmed` | no auto-merge AND last commit ≥ 6 hours ago | "if you've moved on, close" |

The script picks **exactly one** primary class; multi-class cases (e.g. dirty + flaky CI) are addressed with the dirty action recipe first since rebasing often heals both.

## Usage

### Single PR

```bash
# Diagnose + post (subject to cooldown)
scripts/coord/chump-pr-nudge.sh 1799

# Dry-run: print the comment, don't post
scripts/coord/chump-pr-nudge.sh 1799 --dry-run

# Bypass the 24h cooldown (operator escape hatch)
scripts/coord/chump-pr-nudge.sh 1799 --force
```

### Batch mode

```bash
# Nudge every open PR whose mergeable_state == dirty
scripts/coord/chump-pr-nudge.sh --all-dirty

# Or every orphan / every blocked-ci / every clean-not-merged / every base-modified
scripts/coord/chump-pr-nudge.sh --all-orphan
scripts/coord/chump-pr-nudge.sh --all-blocked-ci
scripts/coord/chump-pr-nudge.sh --all-clean
scripts/coord/chump-pr-nudge.sh --all-base-modified

# Batch dry-run (preview the sweep without posting)
scripts/coord/chump-pr-nudge.sh --all-dirty --dry-run
```

Batch mode internally rate-limits each post through `chump_gh` (INFRA-1079 self-throttle + INFRA-1080 pre-emptive backoff), so a 30-PR sweep won't burn the REST bucket.

### Stats

```bash
scripts/coord/chump-pr-nudge.sh --stats
```

Reads `.chump-locks/pr-nudge-history.jsonl` and prints per-class counts (posted vs dry-run). Use this to see which classes recur — e.g. lots of `base-modified` means main is moving fast and operators should consider tighter merge windows.

## Cooldown

Default: same `(pr, sha, class)` within 24 hours is skipped with a NOTE. Cooldown resets when:
- The PR's SHA changes (new push)
- The diagnosis class changes (e.g. CI flipped from failing → green)
- The template version bumps

Override with `--force` for the rare "you really need to see this" case. Tune the window via `CHUMP_NUDGE_COOLDOWN_HOURS`.

## Templates

Stored in `scripts/coord/pr-nudge-templates/<class>.md`. Each template supports these placeholders:

| Placeholder | Value |
|---|---|
| `{{PR}}` | PR number |
| `{{SHA}}` | full head SHA |
| `{{SHA_SHORT}}` | first 8 chars of SHA |
| `{{FAILING_CHECKS}}` | comma-separated names of failing required checks |
| `{{REQUIRED_STATUS}}` | "green" or "failing (<names>)" |
| `{{LAST_COMMIT_AGE}}` | human-readable age of last commit |

Templates are operator-overridable: drop a replacement in the same path. Per-repo overrides go in `scripts/coord/pr-nudge-templates/<repo-name>/<class>.md` (planned; not yet implemented in v0).

## Events emitted

- `kind=pr_nudged` to `.chump-locks/ambient.jsonl` on every real post. Fields: `{ts, pr, sha, class}`. Registered in `EVENT_REGISTRY.yaml`.
- A line is also appended to `.chump-locks/pr-nudge-history.jsonl` (the cooldown ledger).

Dry-runs land in history with `dry_run: true` but do NOT emit `pr_nudged` to ambient.

## Rate-limit safety

Every gh call routes through `chump_gh` from `scripts/coord/lib/github.sh`:

- INFRA-1079 throttle limits aggregate gh calls/min across the fleet (default 60/min).
- INFRA-1080 pre-empt defers background calls when GraphQL bucket < 10% remaining.

`chump pr nudge` doesn't tag itself as background (PRs need timely action), so it always proceeds when GraphQL has any headroom. Pure REST flow — no GraphQL burn.

## When NOT to use

- **Audit / forensics.** The ambient.jsonl `pr_nudged` events are the audit trail; the GitHub comments are the user-facing channel.
- **Active human review thread.** If a non-bot account commented on the PR more recently than the last nudge, hold off (v0 doesn't yet auto-detect this — operator discretion).
- **The PR is already merging.** `state: open` is the precondition; closed/merged PRs are skipped.

## Composition with other a2a primitives

- **INFRA-1115 mailbox:** v1 will additionally drop the diagnosis into the PR-author session's inbox if the session is still live (resolved via capability manifest, Layer 2c). For v0, the GitHub comment is the only channel.
- **INFRA-1079/1080 throttle/preempt:** transparently applied per the source.

## Failure modes

| Failure | Behavior |
|---|---|
| gh API returns non-200 | Script exits with error message + non-zero status; no history entry |
| Template file missing | Error to stderr; no comment posted |
| PR not found | Skipped silently (state≠open) |
| Cooldown active | NOTE to stderr; exit 0 (intended skip) |
| Multi-class diagnosis (dirty + flaky CI) | Single template — dirty wins because rebase usually heals CI |
| Author is human (operator) reviewing | v0: no detection. Operator can `git revert` the comment if undesired |

## See also

- [`scripts/coord/chump-pr-nudge.sh`](../../scripts/coord/chump-pr-nudge.sh) — source
- [`scripts/coord/pr-nudge-templates/`](../../scripts/coord/pr-nudge-templates/) — comment templates
- [`scripts/ci/test-pr-nudge.sh`](../../scripts/ci/test-pr-nudge.sh) — 10-assertion test
- [`docs/design/A2A_ROADMAP.md`](../design/A2A_ROADMAP.md) — context: where nudge sits in the six-layer plan
- [`docs/process/A2A_MAILBOX.md`](./A2A_MAILBOX.md) — sibling tactical primitive (mailbox)
