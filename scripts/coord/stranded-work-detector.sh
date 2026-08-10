#!/usr/bin/env bash
# stranded-work-detector.sh — ZERO-WASTE-039
#
# Work done ON the factory (operator/Claude sessions editing main checkouts
# directly) has no registration artifact, so no gate, detector, picker, or
# session-start digest ever sees it. Observed 2026-08-05: Chump's own
# checkout carried the almanac Phase D integration (+313 lines) dirty for
# 4-5 days while the fleet independently re-shipped the same work as PR
# #3477, and an audit session nearly shipped the residue a second time
# (EFFECTIVE-362, caught only by a 3-way conflict at claim time).
#
# This detector makes that class of work VISIBLE, not fixed — per
# MISSION-045, a signal is not work: it never auto-commits and never
# auto-files a gap. It surfaces four independent signals per checkout:
#
#   (a) dirty tracked files whose newest mtime is > CHUMP_STRANDED_DIRTY_H
#       old (default 24h)
#   (b) local branches carrying `git cherry origin/<main>` '+' commits whose
#       latest commit is > CHUMP_STRANDED_BRANCH_H old (default 24h)
#   (c) the checkout's HEAD is not on the default branch
#   (d) stashes older than CHUMP_STRANDED_STASH_D (default 7 days)
#
# Zero-loss guarantee: before any WARN is emitted for a dirty checkout, its
# `git diff HEAD` is written to a dated patch under the snapshot dir
# (default $MAIN_REPO/.chump/stranded/<repo>/, already gitignored) — so a
# `git reset --hard` on the live tree cannot destroy work this detector has
# already seen. Branches and stashes are already committed objects (safe in
# the object store); only the working-tree diff is at reset-hard risk.
#
# Usage:
#   scripts/coord/stranded-work-detector.sh                    # scan + snapshot + WARN
#   scripts/coord/stranded-work-detector.sh --json             # JSONL + summary line
#   scripts/coord/stranded-work-detector.sh --dry-run          # report only, no
#                                                                 patch write, no ambient emit
#   scripts/coord/stranded-work-detector.sh --quiet             # summary line only
#   scripts/coord/stranded-work-detector.sh --root DIR          # extra scan root
#   scripts/coord/stranded-work-detector.sh --out-dir DIR       # override snapshot dir
#   scripts/coord/stranded-work-detector.sh --checkout PATH     # scan just PATH
#                                                                 (no globbing/worktree
#                                                                 enumeration) — cheap
#                                                                 single-repo check, what
#                                                                 freshness-preamble.sh uses
#
# Env:
#   CHUMP_STRANDED_ROOTS     colon-separated scan roots (default: $HOME/Projects)
#   CHUMP_STRANDED_DIR       snapshot dir (default: <main-repo>/.chump/stranded)
#   CHUMP_STRANDED_DIRTY_H   hours before a dirty tree counts as stranded (default 24)
#   CHUMP_STRANDED_BRANCH_H  hours before an ahead-branch counts as stranded (default 24)
#   CHUMP_STRANDED_STASH_D   days before a stash counts as stranded (default 7)
#   CHUMP_STRANDED_EXTERNAL  1 (default) also scans ~/.chump/external/*/* repos
#                            (registered external repos, the almanac case)
#
# launchd: scripts/setup/install-stranded-work-launchd.sh (daily).
# Session-start digest: scripts/coord/freshness-preamble.sh calls this in
# --dry-run --json mode to surface the count cheaply.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"

MAIN_REPO="$(resolve_main_worktree "$0" 2>/dev/null || echo "$SCRIPT_DIR/../..")"

DRY_RUN=0
JSON=0
QUIET=0
declare -a EXTRA_ROOTS=()
OUT_DIR="${CHUMP_STRANDED_DIR:-$MAIN_REPO/.chump/stranded}"
SINGLE_CHECKOUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     JSON=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --quiet)    QUIET=1; shift ;;
        --root)     EXTRA_ROOTS+=("${2:?--root needs a path}"); shift 2 ;;
        --out-dir)  OUT_DIR="${2:?--out-dir needs a path}"; shift 2 ;;
        --checkout) SINGLE_CHECKOUT="${2:?--checkout needs a path}"; shift 2 ;;
        -h|--help)  sed -n '2,45p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

DIRTY_THRESHOLD_S=$(( ${CHUMP_STRANDED_DIRTY_H:-24} * 3600 ))
BRANCH_THRESHOLD_S=$(( ${CHUMP_STRANDED_BRANCH_H:-24} * 3600 ))
STASH_THRESHOLD_S=$(( ${CHUMP_STRANDED_STASH_D:-7} * 86400 ))
EXTERNAL_SCAN="${CHUMP_STRANDED_EXTERNAL:-1}"

NOW=$(date +%s)

declare -a ROOTS=()
if [[ -n "${CHUMP_STRANDED_ROOTS:-}" ]]; then
    while IFS= read -r r; do [[ -n "$r" ]] && ROOTS+=("$r"); done < <(tr ':' '\n' <<<"$CHUMP_STRANDED_ROOTS")
else
    ROOTS+=("$HOME/Projects")
fi
[[ ${#EXTRA_ROOTS[@]} -gt 0 ]] && ROOTS+=("${EXTRA_ROOTS[@]}")

canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

CHECKOUTS_FILE="$(mktemp)"
trap 'rm -f "$CHECKOUTS_FILE"' EXIT

if [[ -n "$SINGLE_CHECKOUT" ]]; then
    # Fast path: check exactly one checkout, no globbing/worktree enumeration.
    # This is what freshness-preamble.sh uses so the per-session digest never
    # pays the cost of a fleet-wide scan; the fleet-wide sweep is the daily
    # launchd job's job.
    [[ -d "$SINGLE_CHECKOUT" ]] && canon "$SINGLE_CHECKOUT" >> "$CHECKOUTS_FILE"
else
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

    # (e) registered external repos (the almanac case) — ~/.chump/external/<owner>/<repo>/repo
    if [[ "$EXTERNAL_SCAN" == "1" && -d "$HOME/.chump/external" ]]; then
        while IFS= read -r gitdir; do
            canon "$(dirname "$gitdir")" >> "$CHECKOUTS_FILE"
        done < <(find "$HOME/.chump/external" -maxdepth 4 -name .git -type d 2>/dev/null)
    fi
fi

sort -u "$CHECKOUTS_FILE" -o "$CHECKOUTS_FILE"

SCANNED=0
STRANDED_CHECKOUTS=0
DIRTY_TOTAL=0
AHEAD_BRANCH_TOTAL=0
AGED_STASH_TOTAL=0
NOT_ON_MAIN_TOTAL=0
PATCH_WRITTEN_TOTAL=0

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null || printf '"%s"' "$1"
}

while IFS= read -r co; do
    [[ -d "$co" ]] || continue
    git -C "$co" rev-parse --git-dir >/dev/null 2>&1 || continue
    SCANNED=$(( SCANNED + 1 ))

    branch="$(git -C "$co" symbolic-ref --short -q HEAD || echo DETACHED)"
    default_branch="$(git -C "$co" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    [[ -z "$default_branch" ]] && default_branch="main"

    # (a) dirty tracked files, aged by newest mtime among them
    dirty_count=0
    newest=0
    while IFS= read -r line; do
        [[ ${#line} -lt 4 ]] && continue
        code="${line:0:2}"
        [[ "$code" == "??" ]] && continue   # untracked — not in scope
        p="${line:3}"
        p="${p##* -> }"
        p="${p%\"}"; p="${p#\"}"
        dirty_count=$(( dirty_count + 1 ))
        m=$(stat -f%m "$co/$p" 2>/dev/null || stat -c%Y "$co/$p" 2>/dev/null || echo 0)
        [[ "$m" -gt "$newest" ]] && newest="$m"
    done < <(git -C "$co" status --porcelain 2>/dev/null)
    dirty_age=0
    dirty_stale=0
    if [[ "$dirty_count" -gt 0 && "$newest" -gt 0 ]]; then
        dirty_age=$(( NOW - newest ))
        [[ "$dirty_age" -gt "$DIRTY_THRESHOLD_S" ]] && dirty_stale=1
    fi

    # (b) ahead-branches: local branches with unmerged '+' commits > threshold old
    declare -a ahead_lines=()
    while IFS= read -r b; do
        [[ "$b" == "$default_branch" ]] && continue
        git -C "$co" rev-parse -q --verify "origin/$default_branch" >/dev/null 2>&1 || continue
        plus_count=$(git -C "$co" cherry "origin/$default_branch" "$b" 2>/dev/null | grep -c '^+' || true)
        [[ "$plus_count" -gt 0 ]] || continue
        commit_ts=$(git -C "$co" log -1 --format=%ct "$b" 2>/dev/null || echo 0)
        [[ "$commit_ts" -eq 0 ]] && continue
        b_age=$(( NOW - commit_ts ))
        [[ "$b_age" -gt "$BRANCH_THRESHOLD_S" ]] || continue
        ahead_lines+=("$b|$plus_count|$b_age")
    done < <(git -C "$co" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

    # (c) checkout not on default branch (and not detached in a worktree oddity)
    not_on_main=0
    [[ "$branch" != "$default_branch" && "$branch" != "DETACHED" ]] && not_on_main=1

    # (d) aged stashes
    declare -a stash_lines=()
    while IFS= read -r sline; do
        [[ -z "$sline" ]] && continue
        sref="${sline%% *}"
        sts="${sline##* }"
        [[ "$sts" =~ ^[0-9]+$ ]] || continue
        s_age=$(( NOW - sts ))
        [[ "$s_age" -gt "$STASH_THRESHOLD_S" ]] || continue
        stash_lines+=("$sref|$s_age")
    done < <(git -C "$co" stash list --format='%gd %ct' 2>/dev/null)

    found=0
    [[ "$dirty_stale" -eq 1 ]] && found=1
    [[ ${#ahead_lines[@]} -gt 0 ]] && found=1
    [[ "$not_on_main" -eq 1 ]] && found=1
    [[ ${#stash_lines[@]} -gt 0 ]] && found=1

    if [[ "$found" -eq 0 ]]; then
        ahead_lines=(); stash_lines=()
        continue
    fi

    STRANDED_CHECKOUTS=$(( STRANDED_CHECKOUTS + 1 ))
    [[ "$dirty_stale" -eq 1 ]] && DIRTY_TOTAL=$(( DIRTY_TOTAL + 1 ))
    AHEAD_BRANCH_TOTAL=$(( AHEAD_BRANCH_TOTAL + ${#ahead_lines[@]} ))
    AGED_STASH_TOTAL=$(( AGED_STASH_TOTAL + ${#stash_lines[@]} ))
    [[ "$not_on_main" -eq 1 ]] && NOT_ON_MAIN_TOTAL=$(( NOT_ON_MAIN_TOTAL + 1 ))

    # Zero-loss snapshot BEFORE the warning — dirty working-tree diffs are the
    # only signal here at real reset-hard risk (branches/stashes are already
    # committed objects).
    patch_path="none"
    if [[ "$dirty_stale" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
        reponame="$(basename "$co")"
        outdir="$OUT_DIR/$reponame"
        mkdir -p "$outdir" 2>/dev/null || true
        datestr="$(date -u +%Y%m%dT%H%M%SZ)"
        safe_branch="${branch//\//_}"
        patch_file="$outdir/${datestr}-${safe_branch}.patch"
        if git -C "$co" diff HEAD > "$patch_file" 2>/dev/null && [[ -s "$patch_file" ]]; then
            patch_path="$patch_file"
            PATCH_WRITTEN_TOTAL=$(( PATCH_WRITTEN_TOTAL + 1 ))
        else
            rm -f "$patch_file" 2>/dev/null || true
            patch_path="empty"
        fi
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        msg="stranded work in $co: dirty=${dirty_stale} (age ${dirty_age}s, patch=${patch_path}), ahead_branches=${#ahead_lines[@]}, aged_stashes=${#stash_lines[@]}, not_on_main=${not_on_main} (branch=${branch}). Surfaced only — no auto-commit, no auto-filed gap. Review and commit/ship or discard."
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        lock_dir="$MAIN_REPO/.chump-locks"
        mkdir -p "$lock_dir" 2>/dev/null || true
        printf '{"event":"ALERT","kind":"stranded_work","gap":"ZERO-WASTE-039","checkout":"%s","dirty":%s,"dirty_age_s":%d,"ahead_branches":%d,"aged_stashes":%d,"not_on_main":%s,"patch":"%s","ts":"%s","reason":%s}\n' \
            "$co" "$([[ $dirty_stale -eq 1 ]] && echo true || echo false)" "$dirty_age" "${#ahead_lines[@]}" "${#stash_lines[@]}" \
            "$([[ $not_on_main -eq 1 ]] && echo true || echo false)" "$patch_path" "$ts" "$(json_escape "$msg")" \
            >> "$lock_dir/ambient.jsonl" 2>/dev/null || true
        [[ "$QUIET" -eq 0 ]] && printf 'WARN [stranded_work] %s\n' "$msg" >&2
    fi

    if [[ "$JSON" -eq 1 ]]; then
        printf '{"checkout":"%s","branch":"%s","dirty":%s,"dirty_age_s":%d,"ahead_branches":%d,"aged_stashes":%d,"not_on_main":%s,"patch":"%s"}\n' \
            "$co" "$branch" "$([[ $dirty_stale -eq 1 ]] && echo true || echo false)" "$dirty_age" "${#ahead_lines[@]}" "${#stash_lines[@]}" \
            "$([[ $not_on_main -eq 1 ]] && echo true || echo false)" "$patch_path"
    fi

    ahead_lines=(); stash_lines=()
done < "$CHECKOUTS_FILE"

if [[ "$JSON" -eq 1 ]]; then
    printf '{"summary":true,"scanned":%d,"stranded_checkouts":%d,"dirty":%d,"ahead_branches":%d,"aged_stashes":%d,"not_on_main":%d,"patches_written":%d}\n' \
        "$SCANNED" "$STRANDED_CHECKOUTS" "$DIRTY_TOTAL" "$AHEAD_BRANCH_TOTAL" "$AGED_STASH_TOTAL" "$NOT_ON_MAIN_TOTAL" "$PATCH_WRITTEN_TOTAL"
else
    printf '=== stranded-work-detector: %d checkouts, %d stranded (dirty=%d, ahead_branches=%d, aged_stashes=%d, not_on_main=%d, patches_written=%d) ===\n' \
        "$SCANNED" "$STRANDED_CHECKOUTS" "$DIRTY_TOTAL" "$AHEAD_BRANCH_TOTAL" "$AGED_STASH_TOTAL" "$NOT_ON_MAIN_TOTAL" "$PATCH_WRITTEN_TOTAL"
fi

exit 0
