#!/usr/bin/env bash
# uncommitted-wip-watchdog.sh — RESILIENT-256 (2026-08-09)
#
# The load-bearing half of RESILIENT-256. On 2026-08-09 an agent ran
# `git reset --hard origin/main` in the shared almanac primary checkout and
# destroyed ~574 insertions across 7 files that had sat UNCOMMITTED for 13
# hours. Recovery was impossible: unstaged changes never enter the object
# store, so there was no reflog entry, no stash, and `git fsck --lost-found`
# over every dangling commit/tree/blob found nothing.
#
# Git has no pre-reset hook, so no hook can save you. The durable fix is that
# work reaches the OBJECT STORE early — after which `reset --hard` is merely
# annoying instead of terminal. This watchdog is that fix:
#
#   1. Scan every checkout in the roster (fleet repos + all their linked
#      worktrees).
#   2. For each dirty tree, age it by the newest mtime among its dirty paths.
#   3. Older than the threshold → `chump wip-snapshot`, which writes a
#      refs/wip/<branch>/<epoch> commit WITHOUT touching the working tree or
#      the index (safe against a checkout another session is typing into).
#   4. ALERT into ambient.jsonl so the staleness is visible in the standard
#      pre-flight `tail -30 .chump-locks/ambient.jsonl`.
#
# A WIP commit on a scratch branch would satisfy the same requirement; the
# snapshot ref is preferred only because it needs no branch, no checkout
# switch, and cannot surprise the session that owns the tree.
#
# Usage:
#   scripts/ops/uncommitted-wip-watchdog.sh                 # scan + snapshot + alert
#   scripts/ops/uncommitted-wip-watchdog.sh --dry-run       # report only
#   scripts/ops/uncommitted-wip-watchdog.sh --quiet         # ALERT only
#   scripts/ops/uncommitted-wip-watchdog.sh --root DIR      # extra scan root
#   scripts/ops/uncommitted-wip-watchdog.sh --threshold-h N # default 3
#
# Env:
#   CHUMP_WIP_THRESHOLD_H   hours before uncommitted work is "stale" (default 3)
#   CHUMP_WIP_ROOTS         colon-separated scan roots (default: ~/Projects)
#
# launchd: scripts/setup/install-wip-watchdog-launchd.sh (every 30 min).
# Graded by scripts/ops/reaper-heartbeat-watchdog.sh under the name `wip`.
#
# ── EVENT_REGISTRY coverage scanner-anchor (INFRA-1237 / INFRA-1287) ─────────
# Both kinds below are emitted for real further down, but through a `$kind`
# shell variable the coverage regex cannot see through. Anchor the literals
# here in the scanner's detectable JSON form, one per line (extract_kinds()
# uses re.search — first match per line only, so two on one line loses one):
#   "kind":"wip_unprotected"
#   "kind":"wip_snapshotted"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/reaper-instrumentation.sh
source "$SCRIPT_DIR/../lib/reaper-instrumentation.sh"

DRY_RUN=0
QUIET=0
THRESHOLD_H="${CHUMP_WIP_THRESHOLD_H:-3}"
declare -a EXTRA_ROOTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --quiet)       QUIET=1; shift ;;
        --threshold-h) THRESHOLD_H="${2:?--threshold-h needs a number}"; shift 2 ;;
        --root)        EXTRA_ROOTS+=("${2:?--root needs a path}"); shift 2 ;;
        -h|--help)     sed -n '2,45p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *)             echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

reaper_setup wip
# A snapshot is kilobytes of git objects; the loss it prevents is permanent
# and total. And low disk is precisely when agents reach for `git clean -fdx`
# and `reset --hard` — so this is the worst possible moment to switch the
# data-loss guard off. Still emits the disk_critical ALERT.
export REAPER_DISK_EXEMPT=1
export REAPER_DISK_EXEMPT_WHY="snapshots are KB; the loss they prevent is permanent, and disk pressure is when destructive git gets run"
reaper_check_disk_headroom

THRESHOLD_S=$(( THRESHOLD_H * 3600 ))
NOW=$(date +%s)

# chump may not be on PATH under launchd; fall back to the repo build.
CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
[[ -z "$CHUMP_BIN" && -x "$HOME/.local/bin/chump" ]] && CHUMP_BIN="$HOME/.local/bin/chump"
[[ -z "$CHUMP_BIN" && -x "$REAPER_REPO_ROOT/target/release/chump" ]] && CHUMP_BIN="$REAPER_REPO_ROOT/target/release/chump"

# ── Build the roster: every checkout we can see ──────────────────────────────
# Scan roots hold repos one level down (~/Projects/<repo>). For each repo we
# also enumerate its linked worktrees, because a worktree is exactly where an
# agent's uncommitted work is *supposed* to live — and it rots there too.
declare -a ROOTS=()
if [[ -n "${CHUMP_WIP_ROOTS:-}" ]]; then
    while IFS= read -r r; do [[ -n "$r" ]] && ROOTS+=("$r"); done < <(tr ':' '\n' <<<"$CHUMP_WIP_ROOTS")
else
    ROOTS+=("$HOME/Projects")
fi
[[ ${#EXTRA_ROOTS[@]} -gt 0 ]] && ROOTS+=("${EXTRA_ROOTS[@]}")

CHECKOUTS_FILE="$(mktemp)"
trap 'rm -f "$CHECKOUTS_FILE"' EXIT

# Paths must be canonicalised before de-duping: `git worktree list` reports
# the resolved path (/private/tmp/...) while a glob over the scan root yields
# the symlinked one (/tmp/...). Without this the same checkout gets scanned
# — and snapshotted — twice, which is how a watchdog earns a reputation for
# crying wolf.
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    for repo in "$root"/*; do
        [[ -e "$repo/.git" ]] || continue
        canon "$repo" >> "$CHECKOUTS_FILE"
        while IFS= read -r wt; do
            [[ -d "$wt" ]] && canon "$wt" >> "$CHECKOUTS_FILE"
        done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    done
done

sort -u "$CHECKOUTS_FILE" -o "$CHECKOUTS_FILE"

SCANNED=0; DIRTY=0; STALE=0; SNAPPED=0; SNAP_FAILED=0
declare -a STALE_LINES=()

while IFS= read -r co; do
    [[ -d "$co" ]] || continue
    SCANNED=$(( SCANNED + 1 ))

    status="$(git -C "$co" status --porcelain 2>/dev/null)" || continue
    [[ -z "$status" ]] && continue
    DIRTY=$(( DIRTY + 1 ))

    # Age = newest mtime among dirty paths. Newest, not oldest: work touched
    # 30 seconds ago is live editing, and snapshotting mid-keystroke is noise.
    newest=0
    count=0
    while IFS= read -r line; do
        [[ ${#line} -lt 4 ]] && continue
        p="${line:3}"
        p="${p##* -> }"
        p="${p%\"}"; p="${p#\"}"
        count=$(( count + 1 ))
        m=$(stat -f%m "$co/$p" 2>/dev/null || stat -c%Y "$co/$p" 2>/dev/null || echo 0)
        [[ "$m" -gt "$newest" ]] && newest="$m"
    done <<< "$status"

    [[ "$newest" -eq 0 ]] && continue
    age=$(( NOW - newest ))
    [[ "$age" -lt "$THRESHOLD_S" ]] && continue

    STALE=$(( STALE + 1 ))
    age_h=$(( age / 3600 ))

    snap_ref="none"
    # There is deliberately no env override here. The one that used to sit in
    # this condition gated on exactly what DRY_RUN already gates on, so it
    # bought nothing — and every
    # bypass-shaped CHUMP_* var costs a slot against the EFFECTIVE-094 debt
    # ceiling, which this branch blew (239 > 238). Paying the addition tax by
    # NOT adding is cheaper than asking the operator to raise a ceiling for a
    # duplicate of a flag that already exists.
    if [[ "$DRY_RUN" -eq 0 && -n "$CHUMP_BIN" ]]; then
        if out="$("$CHUMP_BIN" wip-snapshot --dir "$co" --quiet 2>&1)"; then
            snap_ref="$(awk '{print $2}' <<<"$out")"
            [[ -n "$snap_ref" ]] && SNAPPED=$(( SNAPPED + 1 )) || snap_ref="clean"
        else
            SNAP_FAILED=$(( SNAP_FAILED + 1 ))
            snap_ref="FAILED: ${out:0:120}"
        fi
    fi

    STALE_LINES+=("$co|$count|$age_h|$snap_ref")
    [[ "$QUIET" -eq 0 ]] && printf '  STALE: %s — %d uncommitted path(s), idle %dh, snapshot=%s\n' \
        "$co" "$count" "$age_h" "$snap_ref"
done < "$CHECKOUTS_FILE"

# ── ALERT on anything still un-snapshotted, and on the stale set overall ─────
# The ALERT is the visible half: a snapshot the operator never hears about is
# a snapshot nobody remembers to recover from.
if [[ "$STALE" -gt 0 ]]; then
    for entry in "${STALE_LINES[@]}"; do
        IFS='|' read -r co count age_h snap_ref <<< "$entry"
        if [[ "$snap_ref" == none || "$snap_ref" == FAILED:* ]]; then
            kind="wip_unprotected"
            msg="uncommitted work in $co has been idle ${age_h}h across ${count} path(s) and is NOT in the object store (snapshot: ${snap_ref}). A single \`git reset --hard\` destroys it permanently — unstaged changes have no reflog, no stash, no fsck. Commit it, or run: chump wip-snapshot --dir $co"
        else
            kind="wip_snapshotted"
            msg="uncommitted work in $co idle ${age_h}h across ${count} path(s) — snapshotted to ${snap_ref} so it survives a reset. Still commit it; a snapshot ref is a seatbelt, not a seat."
        fi
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf 'ALERT [%s] %s\n' "$kind" "$msg" >&2
        printf '{"event":"ALERT","kind":"%s","gap":"RESILIENT-256","checkout":"%s","paths":%d,"idle_hours":%d,"snapshot":"%s","ts":"%s","reason":%s}\n' \
            "$kind" "$co" "$count" "$age_h" "$snap_ref" "$ts" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$msg" 2>/dev/null || echo "\"$msg\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    done
fi

if [[ "$QUIET" -eq 0 ]]; then
    printf '=== wip-watchdog: %d checkouts, %d dirty, %d stale (>%dh), %d snapshotted, %d failed ===\n' \
        "$SCANNED" "$DIRTY" "$STALE" "$THRESHOLD_H" "$SNAPPED" "$SNAP_FAILED"
fi

reaper_finish ok "{\"scanned\":$SCANNED,\"dirty\":$DIRTY,\"stale\":$STALE,\"snapshotted\":$SNAPPED,\"snapshot_failed\":$SNAP_FAILED}"
exit 0
