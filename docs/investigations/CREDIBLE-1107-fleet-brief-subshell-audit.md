# CREDIBLE-1107: fleet-brief.sh subshell execution + error-swallowing audit

**Slice of:** CREDIBLE-129 (fleet-brief ship-count intermittently returns 0
while fleet is actively shipping — false fleet-dead signal at SessionStart).
**Scope of this slice:** enumerate *every* subshell/git/tool invocation in
`scripts/dispatch/fleet-brief.sh` that suppresses stderr or defaults to a
falsy value (`0`, empty string) on non-zero exit, and document the root-cause
failure scenario for each. This is an audit-only slice — fixes for individual
sites are follow-up gaps, not this one.

## Why this matters

`fleet-brief.sh` is the first thing every SessionStart hook shows the
operator/agent. Every site below that swallows an error and substitutes a
falsy default is a potential source of a **silently wrong banner** — either a
false "fleet is dead" (undercounts) or a false "fleet looks healthy" /
false "SILENT-FLEET-DEATH" alert (depending on which direction the default
value pushes the downstream comparison). CREDIBLE-129 reproduced one instance
of this class (ship-count → 0); this audit catalogs the rest so they can be
triaged and fixed individually instead of re-discovered one incident at a
time.

## Common pattern

Nearly every site follows the same shape:

```bash
some_git_or_tool_command 2>/dev/null || <falsy-default>
```

`2>/dev/null` discards stderr (so a `fatal: ...` from git, or any tool error
message, is never seen by anyone — not the terminal, not a log file). The
`|| true` / `|| echo 0` / `|| echo ".git"` clause then converts a non-zero
exit code into a *successful* shell expression whose value is the fallback.
Downstream code has no way to distinguish "the real answer is 0/empty" from
"the query failed and we substituted 0/empty" — the two are bitwise
identical by the time they reach a comparison or a printed count.

## Inventory (by line, in `scripts/dispatch/fleet-brief.sh`)

| # | Lines | Site | Suppresses | Falls back to | Downstream effect if triggered |
|---|---|---|---|---|---|
| 1 | 20 | `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"` | stderr + exit code | `pwd` | Wrong repo root if run outside a git tree during a transient git-lock; every path derived from `REPO_ROOT` downstream is then wrong silently. |
| 2 | 21 | `_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"` | stderr + exit code | literal `.git` | `MAIN_REPO` computed from a bogus relative path; `LOCK_DIR`/`AMBIENT_LOG` then point at the wrong (or nonexistent) directory, so ambient writes and curator-liveness reads silently miss. |
| 3 | 40 | `_git_log_24h()`: `git -C "$MAIN_REPO" log --format="%s" --after="24 hours ago" origin/main 2>/dev/null \|\| true` | stderr + exit code | empty stdout | **This is the CREDIBLE-129 root cause.** `origin/main` unresolvable (loose ref mid-`gc`/`pack-refs`, or a fetch killed mid-transport) → `git log` exits 128 → swallowed → `_subjects_24h=""` → `ships_24h=0` via `grep -c .` on empty input → banner reads "Ships: 0" while the fleet is actively shipping. |
| 4 | 41 | `_git_log_6h()` — identical pattern | stderr + exit code | empty stdout | Same failure mode feeding `ships_6h`, the pillar-mix table, and `_overlap_clusters`. |
| 5 | 43 | `_git_log_1h()` — identical pattern | stderr + exit code | empty stdout | Same failure mode feeding `ships_1h`, which directly gates the `_fleet_stalled` STALLED banner (line 122) — a transient ref-read failure can flip `ships_1h` to 0 and, combined with 2 pre-existing BLOCKED PRs, **fire a false STALLED alert** and write a `kind=fleet_stalled` ambient event that other watchers may page on. |
| 6 | 49-51 | `ships_24h=$(echo "$_subjects_24h" \| grep -c . 2>/dev/null \|\| true)` (and the `_6h`/`_1h` siblings) | stderr + exit code of `grep` | `true` (no-op; `ships_*` stays whatever `grep -c` last assigned, or unset) | Low practical risk (`grep -c .` essentially never fails on a string), but it's a second swallow layered on top of #3-5 — if `echo`/pipe ever SIGPIPEs, this masks it too. |
| 7 | 99-102 | overlap-cluster scan: `git -C "$MAIN_REPO" log --name-only --format="" --after="6 hours ago" origin/main 2>/dev/null \| sed ... \| ... \|\| true` | stderr + exit code | empty `_overlap_raw` | Same `origin/main`-unresolvable window as #3-5; overlap-cluster section just silently disappears from the banner with no distinction from "no clusters this window." |
| 8 | 116 | `gh pr list --state open --json ... 2>/dev/null` (feeds the `stalls_4h`/`blocked_count` while-loop) | stderr + exit code | empty loop body → `blocked_count=0`, `stalls_4h=()` | GitHub API failure (rate-limit, network, auth) silently reports **zero BLOCKED PRs** instead of "unknown." This directly suppresses the STALLED banner's second half of its condition (line 122: `blocked_count -ge 2`) — a `gh` outage can mask a real stall instead of surfacing one. |
| 9 | 139 | `_last_merge_ts="$(git -C "$MAIN_REPO" log origin/main -1 --format="%ct" 2>/dev/null \|\| echo 0)"` | stderr + exit code | literal `0` (epoch 1970) | **Opposite-direction false positive.** If `origin/main` is transiently unresolvable here, `_last_merge_ts=0` → `_sfd_merge_age_h = (now_epoch - 0) / 3600` ≈ decades of hours → `_merge_stale=1` unconditionally. Combined with any dead `com.chump.*` daemon (a condition that's fairly common — see RESILIENT-246 commentary at lines 170-227 in the same file), this can fire the **`*** ALERT: SILENT-FLEET-DEATH ***`** banner and write a `kind=silent_fleet_death` ambient event purely from a transient ref-read glitch, not an actual dead fleet. |
| 10 | 151-153 | `launchctl print "gui/$_uid/$_lbl" 2>/dev/null \|\| launchctl print "system/$_lbl" 2>/dev/null \|\| true` | stderr + exit code (both attempts) | empty `_ec` | Not git, but same class: a transient `launchctl` failure (not "job doesn't exist") is indistinguishable from "job doesn't exist," so `_exit_code` extraction is skipped and that daemon is silently excluded from the dead-daemon list — could under-count `_sfd_dead_count`. |
| 11 | 200 | `ls -t "$LOCK_DIR"/curator-filed-*.json 2>/dev/null \| head -1 \|\| true` | stderr + exit code | empty `_cur_newest` | If `LOCK_DIR` is transiently unreadable (e.g. concurrent write / NFS hiccup), curator "last action" collapses to "never" and forces `_curator_stale=1` — false CURATOR SILENT banner. |
| 12 | 362, 367-368 | `"$_chump" gap list --status open 2>/dev/null \|\| true` (called twice — see the INFRA-1355 re-run-on-import-notice comment at line 363-369) | stderr + exit code of the `chump` binary | empty `_open_gaps` | A transient `chump` failure (state.db lock contention, binary crash) makes every pillar in the "Pillar pickable" table read **"0 (!)"** — the exact false-pillar-starvation signal CLAUDE.md's Mission Driver section explicitly warns against acting on (`docs/gaps` intake firewall / "surface, do NOT manufacture" — see CLAUDE.md §Mission Driver point 2). This is a real path by which a fleet-brief-only glitch could trigger unnecessary gap-filing. |
| 13 | 396 | `_slo_json="$("$_chump" health --slo-check --json 2>/dev/null \|\| true)"` | stderr + exit code | empty `_slo_json` | On failure, `_slo_breaches` extraction (`grep -o` on empty string) yields empty, the `-gt 0` test is skipped — SLO breach banner is silently omitted rather than reported as "unknown." Under-reports, doesn't over-report (unlike #9), but still not distinguishable from "no breaches." |

## Root-cause scenario (generalized, per AC #2)

The unifying mechanism behind sites #3, #4, #5, #7, and #9 (all `origin/main`
reads) is the same one CREDIBLE-129 reproduced concretely
(`scripts/dev/repro-ship-count-zero.sh`, authored on the CREDIBLE-597 slice):

1. `origin/main` is resolved by git from **`.git/refs/remotes/origin/main`**,
   a loose ref file, unless/until it has been consolidated into
   `packed-refs`.
2. Any real `git fetch` against the repo (including the `git fetch origin
   main --quiet` every session runs as part of CLAUDE.md's mandatory
   pre-flight) can opportunistically trigger `git gc --auto` /
   `git pack-refs` once loose-ref or loose-object counts cross git's
   internal threshold. That operation **deletes the loose ref file** once
   its value has been folded into `packed-refs`. There is a small window
   where a reader hitting `origin/main` sees neither file in a fully
   resolvable state.
3. Separately, a `git fetch` that is killed mid-negotiation — a network
   stall, a `timeout N` wrapper (e.g. the one in
   `ambient-context-inject.sh`'s SessionStart hook), a hung SSH/HTTPS
   transport, or **a stale `.git/index.lock` / `.git/refs/remotes/origin/
   main.lock`** left by a concurrently-running git process on the same
   worktree — can leave the ref in the same transiently-unresolvable state,
   depending on exactly where in the ref-update sequence the interruption
   landed.
4. In either case, `git log ... origin/main` exits **128**
   (`fatal: ambiguous argument 'origin/main': unknown revision or path not
   in the working tree.`) or, in the lock-contention case, exits **128**
   with `fatal: Unable to create '.../index.lock': File exists.` — both are
   ordinary git error text on stderr, both are non-zero exits.
5. Every site above wraps the call in `2>/dev/null || <falsy>`. The stderr
   line that would explain *why* the read failed is discarded before
   anyone — human or ambient log — ever sees it, and the non-zero exit is
   converted into a *successful* substitution of `""` or `0`. From that
   point on, the failure is indistinguishable from "the true answer is zero
   ships" or "the true answer is epoch 0" — there is no error signal left
   anywhere in the pipeline for a downstream reader (human, `fresh-eyes`
   curator, `kind=fleet_stalled`/`kind=silent_fleet_death` ambient
   consumers) to act on.

Because the fetch that most reliably triggers step 2 is the **mandatory
pre-flight fetch that runs at the start of every session**, and because
`fleet-brief.sh` is typically invoked by the SessionStart hook in the same
window, the failure is not a rare edge case — it is a **race between the
pre-flight fetch's ref-consolidation and fleet-brief's own ref read**,
which is why CREDIBLE-129 observed it recur (43 ships → 0 ships → back to a
correct count ~30 minutes later, with no operator intervention) rather than
happening once.

## Non-git sites (for completeness, AC #1 covers "subshell invocations" broadly)

Sites #8 (`gh pr list`), #10 (`launchctl print`), #11 (`ls`), #12/#13
(`chump` binary calls) are not git operations but follow the identical
suppress-and-default shape. They are listed above because AC #1 asks for
"subshell invocations and git operations ... that suppress stderr or
default to 0" — the `gh`/`chump`/`launchctl` sites are the same
error-swallowing anti-pattern applied to different tools, and several of
them (#8, #12) directly interact with the pillar-starvation and STALLED
alerting paths that CLAUDE.md's Mission Driver / no-false-alarm doctrine
cares about.

## Non-goals of this slice

- No code changes. This is an audit/documentation deliverable only, per the
  gap's acceptance criteria.
- Fixing individual sites (e.g. distinguishing "0 ships" from "query
  failed") is deliberately left to follow-up gaps, filed per-site so each
  fix is independently reviewable and testable — mirroring how CREDIBLE-129
  itself was sliced into a reproduce-only step (CREDIBLE-597) before any
  fix slice.
