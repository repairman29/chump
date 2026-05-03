---
doc_tag: canonical
owner_gap: INFRA-381
last_audited: 2026-05-03
---

# PR Pipeline Self-Healing

Operator reference for the launchd-graded reapers that keep PRs flowing through merge gates without manual intervention. Read this **once per machine** when setting up dogfood; after that the reapers run autonomously and the heartbeat-watchdog ALERTs `ambient.jsonl` when anything goes silent.

This doc consolidates work shipped under INFRA-307 (stuck-pr-filer), INFRA-354 (pr-watch-shepherd), INFRA-374 (auto-arm-sweeper), INFRA-375 (ci-flake-rerun), INFRA-376 (stuck-pr classifier), plus the existing stale-pr-reaper / gap-doctor / worktree-reaper.

## The four stuck-PR modes

Most stuck PRs fall into one of four categories. Each has a dedicated reaper:

| Stuck mode | Cause | Reaper | Cadence |
|---|---|---|---|
| **DIRTY-from-rebase** | `main` moved underneath an armed PR; needs rebase | [`pr-watch-shepherd.sh`](#pr-watch-shepherd-infra-354) | hourly |
| **CI flake** | Network blip, runner cancelled, OOM, etc — pattern-matched | [`ci-flake-rerun.sh`](#ci-flake-rerun-infra-375) | hourly |
| **Auto-merge orphaned** | Force-push or bot-merge crash dropped the auto-merge state | [`auto-arm-sweeper.sh`](#auto-arm-sweeper-infra-374) | hourly |
| **Real-conflict / infra-broken** | Genuine code conflict or shared CI infra failure → human judgment | [`stuck-pr-filer.sh`](#stuck-pr-filer-infra-307--376) files an INFRA cleanup gap with `[REAL-CONFLICT]` or `[CI-RED]` tag → fleet picks it up | hourly |

The PR pipeline is now self-healing for the first three. The fourth is converted into ordinary fleet work via the classifier.

## Plus the supporting reapers

| Reaper | Purpose | Cadence |
|---|---|---|
| `stale-pr-reaper.sh` | Closes PRs whose gaps already landed on main via another PR | hourly |
| `stale-worktree-reaper.sh` | Removes merged / orphaned linked worktrees under `.claude/worktrees/` | hourly |
| `stale-branch-reaper.sh` | Prunes orphan branches | daily |
| `gap-doctor.py doctor` | Detects DB↔YAML drift in the gap registry | every 15min |
| `ambient-rotate.sh` | Daily rotation of `.chump-locks/ambient.jsonl` to keep it small | daily |
| `reaper-heartbeat-watchdog.sh` | Grades all of the above; ALERTs ambient when anything goes silent | every 30min |

## Install (one-time, per machine)

All installers are idempotent. Safe to re-run.

```bash
# The four PR-flow reapers
bash scripts/setup/install-stuck-pr-filer-launchd.sh        # INFRA-307
bash scripts/setup/install-pr-watch-shepherd-launchd.sh     # INFRA-354
bash scripts/setup/install-auto-arm-sweeper-launchd.sh      # INFRA-374
bash scripts/setup/install-ci-flake-rerun-launchd.sh        # INFRA-375

# Supporting reapers (most of these are likely already installed)
bash scripts/setup/install-stale-pr-reaper-launchd.sh
bash scripts/setup/install-stale-worktree-reaper-launchd.sh
bash scripts/setup/install-stale-branch-reaper-launchd.sh
bash scripts/setup/install-gap-doctor-cron-launchd.sh
bash scripts/setup/install-ambient-rotate-launchd.sh
bash scripts/setup/install-reaper-watchdog-launchd.sh
```

## Verify

```bash
# All chump LaunchAgents loaded?
launchctl list | grep -E 'dev\.chump\.' | sort

# Recent reaper runs visible in ambient stream?
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"reaper_run"|"kind":"pr_watch"|"kind":"auto_armed"|"kind":"ci_flake_rerun"'

# Any silent-reaper ALERTs?
tail -200 .chump-locks/ambient.jsonl | grep '"kind":"reaper_silent"'

# Heartbeat freshness per reaper:
for r in pr stuck-pr worktree branch auto-arm ci-flake; do
  hb="/tmp/chump-reaper-${r}.heartbeat"
  [[ -f "$hb" ]] && echo "$r: $(grep '^ts=' "$hb" | cut -d= -f2-)" || echo "$r: NO HEARTBEAT"
done
```

## What each reaper does

### stuck-pr-filer (INFRA-307 + 376)

Walks open PRs hourly. For each, scores against four conditions:

- **DIRTY** for ≥4h → tag `[REBASE]`
- **CI red** for ≥2h → tag `[CI-RED]`
- **>20 commits BEHIND** → tag `[BEHIND]`
- **Auto-merge disarmed AND original gap has no live lease** → tag `[ORPHAN]`

If any condition matches, files an INFRA P1 cleanup gap titled `PR #<N> stuck [<CLASS>] — <reason>` with description containing the PR URL, suggested action, and routing hint per class. The fleet picker auto-claims P1 INFRA gaps under default filters, so the cleanup work flows to whichever agent is next free.

De-dups by title (`PR #N stuck` substring match in open INFRA gap titles), so re-running is idempotent.

Skips: drafts, dependabot PRs, `chore(gaps): file/reserve …` filing PRs.

Bypass: `CHUMP_STUCK_PR_FILER=0`.

### pr-watch-shepherd (INFRA-354)

Walks open ARMED PRs hourly. For each DIRTY one: disarm → fetch + rebase `origin/main` → force-push (with checkpoint tag for recovery) → re-arm. Conflict-free rebases ship automatically. PRs with real code conflicts are left disarmed with a comment explaining what conflicted — the next stuck-pr-filer cycle catches them as `[REAL-CONFLICT]` cleanup gaps for human/fleet attention.

Replaces the per-PR detached `pr-watch.sh --once` model that died with the author's worktree.

Bypass: `CHUMP_PR_WATCH_SHEPHERD=0`.

### auto-arm-sweeper (INFRA-374)

Walks open PRs hourly. Arms any that are ARMED-eligible-but-unarmed (no draft, no `human-review-wanted` label, no failing required check). Per-PR cooldown (1h) prevents thrashing on PRs the operator deliberately disarmed.

Closes the orphan-arm pattern observed when bot-merge.sh crashes mid-pipeline (before reaching `gh pr merge --auto`) or when force-push silently disarms.

Bypass: `CHUMP_AUTO_ARM_SWEEPER=0`. Skip-label override: `AUTO_ARM_SKIP_LABEL=<label>`.

### ci-flake-rerun (INFRA-375)

Walks open PRs hourly. For each failing required check, fetches the failed-log payload and matches against a tight allowlist of known flake fingerprints:

- `The operation was canceled` (runner cancel)
- `getaddrinfo EAI_AGAIN` (DNS hiccup)
- `connect ETIMEDOUT` (transient network)
- `fatal: unable to access` (git network)
- `Process completed with exit code 137` (OOM kill)
- `Network is unreachable` / `temporarily unavailable`
- (extend via `CI_FLAKE_PATTERNS_FILE`)

On match: `gh run rerun --failed` once per run-id. Per-run-id cooldown record prevents 2nd retry on persistent failures. Real test failures don't match → no rerun → no waste.

Bypass: `CHUMP_CI_FLAKE_RERUN=0`.

### Combined invariants

- **Every reaper writes a heartbeat** at `/tmp/chump-reaper-<NAME>.heartbeat` and emits a `kind=reaper_run` (or reaper-specific `kind=`) event to `.chump-locks/ambient.jsonl` on every run. Visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
- **The heartbeat-watchdog grades all of them** (`reaper-heartbeat-watchdog.sh`) every 30min and ALERTs `kind=reaper_silent` if any miss their cadence (2-4× expected interval per reaper).
- **All reapers honor a `CHUMP_<NAME>=0` bypass env** for emergency disable.
- **All reapers are idempotent** — safe to run by hand at any time.
- **All reapers rotate their own logs** (5MB cap, one .1 archive) so `/tmp/chump-*-reaper.{out,err}.log` never grows unbounded.

## Token-burn defaults (companion: INFRA-371, INFRA-364)

Independent of the pipeline-healing reapers, two changes shipped to make 24/7 fleet operation economically viable:

- **INFRA-371**: `worker.sh` now inlines the gap YAML + a tight rules summary into the `claude -p` prompt instead of telling claude to "read CLAUDE.md and AGENTS.md first". Saves ~20-25K tokens per spawn. Bypass: `FLEET_INLINE_BRIEFING=0`. `run-fleet.sh` also defaults `FLEET_TIMEOUT_S=600` (was 1800), `CHUMP_AMBIENT_INSTALL_SKIP=1`, `CHUMP_LESSONS_AT_SPAWN_N=0`.
- **INFRA-364**: `FLEET_BACKEND=claude` now defaults to `--model haiku`. Override via `FLEET_MODEL=sonnet`.
- **INFRA-372** (filed, not yet shipped): Anthropic prompt caching via `cache_control` in `src/provider_cascade.rs` — up to 90% cost reduction on cached prefix.

## When the reapers can't fix it

Three failure modes still need a human / fleet handoff:

1. **Real code conflict** on rebase — pr-watch-shepherd disarms the PR cleanly; stuck-pr-filer files a `[REAL-CONFLICT]` cleanup gap; the fleet picker (or you) takes it.
2. **Persistent CI failure** that doesn't match flake patterns — ci-flake-rerun skips it; stuck-pr-filer files a `[CI-RED]` gap; needs code fix.
3. **Shared CI infrastructure broken** (release.yml, branch-protection, queue config) — the bot-merge.sh CI pre-flight gate refuses to arm; visible as PRs accumulating without auto-merge. Operator-only fix (admin access required). Watch `ALERT kind=queue_config_drift` events.

## Disable everything (panic button)

```bash
launchctl unload ~/Library/LaunchAgents/dev.chump.{stuck-pr-filer,pr-watch-shepherd,auto-arm-sweeper,ci-flake-rerun}.plist
```

Plus `CHUMP_<REAPER>=0` env for any one-off run.

## Background

This was assembled in a single session 2026-05-02/03 after observing the chump-squad fleet wasted ~96% of cycles on dead picks (ghost-open gaps, immediate-re-pick on rc=1, pre-pick worktree creation before preflight) and ~25-50% of ARMED PRs eventually went DIRTY-orphaned without a per-PR pr-watch.sh process to rebase them. See INFRA-307, INFRA-354, INFRA-359 (ghost-gap reaper, filed), INFRA-361 (rc=1 cooldown + pre-pick preflight, shipped), INFRA-371 (token burn), INFRA-374, INFRA-375, INFRA-376 for the full set.

Net-new-docs: docs/process/PR_PIPELINE_SELF_HEALING.md
