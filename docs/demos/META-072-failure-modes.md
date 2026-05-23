# META-072 demo-loop failure modes

Documents what makes the `chump-demo` Track-3 (autonomous-throughput) demo
**break**, with recovery paths.

Pair with:
* `docs/writeups/2026-05-23-autonomy-cascade.md` (DOC-052 — the engineering
  honest writeup that this demo operationalizes).
* `docs/writeups/2026-05-23-autonomy-cascade-public.md` (the 5-paragraph
  customer-facing distillation).

---

## Failure modes

### 1. Worker stalls

**Symptom**: `prs_merged_per_hour` in the metrics report comes out under
0.5 against a 60-minute window with N≥10 seed gaps.

**Root cause**: a curator session deadlocked in `bot-merge.sh`, or a Sonnet
sub-agent never returned from a long-running tool call, or a worktree
collision blocked progress on a critical path.

**Recovery**:
* `chump fleet doctor` — looks for stale leases + zombie subprocesses.
* `scripts/ops/reap-orphan-claude-procs.sh` — catches process leaks
  (INFRA-1662). PTY-pressure urgent mode (INFRA-1851) covers the worst case.
* `chump pr-rescue --once --dry-run` (INFRA-1714) — surfaces which PRs are
  classified as auto-recoverable.

### 2. Undetected cascade keystone

**Symptom**: `cascade_keystones_classified` is 0 but the queue clearly
cascaded (multiple PRs stalled with the same failing CI step for >10 min).

**Root cause**: INFRA-1840's failure-class classifier hasn't shipped yet or
isn't running on the operator's host. Without it the keystone-pattern is
visible only to the human operator's pattern-match.

**Recovery**:
* Land INFRA-1840 (failure-class classifier — emits
  `kind=keystone_candidate` when ≥3 open PRs share the same CI failure log).
* Until then: human operator reads `chump-ambient-glance` output every 10 min
  during cascade windows.

### 3. YAML integrity bug

**Symptom**: every PR's `gaps-integrity` CI gate fails simultaneously.
Recovery feels surgically targeted at one yaml file, but the actual fix is
the operator un-breaking `docs/gaps/<ID>.yaml`.

**Root cause**: a Sonnet sub-agent wrote malformed YAML to a gap file
(unescaped pipes in AC, embedded conflict markers, or YAML-invalid quoting).
The integrity gate ran first and main contaminated the queue.

**Recovery**:
* INFRA-1831 (`gaps-integrity` runs in `chump preflight`) shipped 2026-05-23
  — the gate trips locally now, before commit, so this class shouldn't
  recur post-fix.
* If it does: `chump gap audit --integrity` + manual yaml repair.

### 4. operator_keystrokes_per_ship over-counts

**Symptom**: metrics report shows `operator_keystrokes_per_ship` >> 100
for what felt like a hands-off session.

**Root cause**: the heuristic counts `bash_call` ambient events from any
session matching `--operator-session-glob` (default `chump-Chump-*`). If
the operator's terminal also runs background tooling (`chump-ambient-glance`,
file watchers, etc.) those add to the count without being directives.

**Recovery**:
* Tighten `--operator-session-glob` to the operator's main interactive
  shell session only.
* Or: post-process the metrics report to subtract known-background bash_call
  sources (cron firings, plist daemons).
* v1 follow-up: classify `bash_call` events as
  `operator_initiated|automation_initiated` at emit time so the demo
  doesn't have to infer.

### 5. Auto-merge dropped silently

**Symptom**: a PR sat with `auto_merge_armed=false` but `mergeable_state=BLOCKED`
for the full window; the demo's pr_merged tally stays low.

**Root cause**: a force-push without `--auto` re-arm drops auto-merge;
or branch-protection settings changed mid-flight.

**Recovery**:
* INFRA-1838 (auto-rebase nudges BLOCKED+armed PRs) shipped 2026-05-23 —
  the daemon re-pokes stuck PRs every minute.
* If still stuck: `gh pr merge <N> --auto --squash` manually; if that fails,
  inspect `gh pr view <N> --json mergeStateStatus` + `branch_protection`.

### 6. Anthropic rate limit / OAUTH refresh

**Symptom**: curator sessions silently lose ability to dispatch Sonnet
sub-agents mid-scenario; no obvious error, just zero new commits.

**Root cause**: OAUTH token expired or daily-tier credits exhausted.

**Recovery**:
* `claude /login` in the operator's terminal — refreshes
  `~/.chump/oauth-token.json`.
* `chump fleet doctor --auth` — explicit auth-validation pass.
* If credit-exhausted: switch to API-key mode (`CHUMP_AUTH_MODE=api-key`).

### 7. Demo runs against a busy main

**Symptom**: the metrics under-report demo-attributable PRs because the
operator merged other (non-synthetic-gap) work during the window.

**Root cause**: the v0 metrics collector doesn't filter PRs by gap-ID
prefix; any merge in the watcher window counts.

**Recovery (v0)**: run the demo against an empty queue; pause non-demo work.
**Recovery (v1 follow-up)**: filter `pr_merged` events by branch-name
prefix (e.g., `chump/SMOKE-*-claim`) so only seeded gaps' PRs count.

---

## Acceptance gate (META-072 AC #3)

A scenario qualifies as a repeatable demo when ALL of:

| Metric                                    | Threshold        |
|-------------------------------------------|------------------|
| `prs_merged_per_hour`                     | ≥ 1.0 sustained  |
| `operator_keystrokes_per_ship`            | < 100 average    |
| Ghost-PR cleanup events                   | 0                |
| Cascade keystones (if any)                | classified < 10m |

The 2026-05-23 session (Track-3 evidence baseline) hit ~5 PRs/hr in its
6-hour cascade window, ~30–50 operator directives / 20 PRs ≈ 1.5–2.5
keystrokes/ship in those 6 hours. The demo's acceptance bar is set lower
than the baseline so the demo can succeed on a less-loaded fleet.
