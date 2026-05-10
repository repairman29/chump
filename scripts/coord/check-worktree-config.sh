#!/usr/bin/env bash
# scripts/coord/check-worktree-config.sh — INFRA-794 (2026-05-10)
#
# Diagnostic: verify core.worktree is correct for ALL linked worktrees.
# During the CREDIBLE-017 session (2026-05-10) the worktree at
# .chump/worktrees/credible-017 had core.worktree pointing at the
# infra-617 worktree path instead of credible-017, causing all git
# operations to resolve to the wrong working tree. This script
# catches that class of misconfiguration before it bites again.
#
# Usage:
#   scripts/coord/check-worktree-config.sh
#   scripts/coord/check-worktree-config.sh --fix    # auto-fix mismatches
#   scripts/coord/check-worktree-config.sh --json   # machine-readable output
#
# Exit code: 0 if all worktrees are correct, 1 if any mismatch found.

set -euo pipefail

FIX_MODE=0
JSON_MODE=0
for arg in "$@"; do
    case "$arg" in
        --fix) FIX_MODE=1 ;;
        --json) JSON_MODE=1 ;;
    esac
done

MAIN_REPO="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." && pwd 2>/dev/null)"
[[ -z "$MAIN_REPO" ]] && { echo "Not in a git repo"; exit 2; }

HAS_ERRORS=0
RESULTS="[]"

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    wt_path="${line#worktree }"
    
    expected_wt="$wt_path"
    
    git_dir_file="$wt_path/.git"
    if [[ -f "$git_dir_file" ]]; then
        git_dir_line="$(head -1 "$git_dir_file" 2>/dev/null || true)"
        git_dir="${git_dir_line#gitdir: }"
        
        if [[ -d "$git_dir" ]]; then
            actual_cfg="$(git --git-dir="$git_dir" config core.worktree 2>/dev/null || echo "")"
            
            status="ok"
            if [[ -z "$actual_cfg" ]]; then
                status="ok"
            elif [[ "$actual_cfg" != "$expected_wt" ]]; then
                status="mismatch"
                HAS_ERRORS=1
            fi
            
            if [[ "$JSON_MODE" == "1" ]]; then
                RESULTS=$(python3 -c "
import json, sys
r = json.loads(sys.argv[1])
r.append({'worktree': sys.argv[2], 'git_dir': sys.argv[3], 'core.worktree': sys.argv[4], 'expected': sys.argv[5], 'status': sys.argv[6]})
print(json.dumps(r))
" "$RESULTS" "$wt_path" "$git_dir" "$actual_cfg" "$expected_wt" "$status" 2>/dev/null || echo "$RESULTS")
            else
                if [[ "$status" == "mismatch" ]]; then
                    echo "[CHECK] MISMATCH: $wt_path"
                    echo "        core.worktree = $actual_cfg"
                    echo "        expected      = $expected_wt"
                    if [[ "$FIX_MODE" == "1" ]]; then
                        echo "[CHECK] Fixing: git --git-dir=$git_dir config core.worktree $expected_wt"
                        git --git-dir="$git_dir" config core.worktree "$expected_wt"
                        echo "[CHECK] Fixed."
                    fi
                fi
            fi
        else
            HAS_ERRORS=1
            [[ "$JSON_MODE" == "0" ]] && echo "[CHECK] ERROR: git dir not found at $git_dir (from $git_dir_file)"
        fi
    else
        [[ "$JSON_MODE" == "0" ]] && echo "[CHECK] SKIP: $wt_path (no .git file — likely main checkout)"
    fi
done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' || echo "")

if [[ "$JSON_MODE" == "1" ]]; then
    echo "$RESULTS"
fi

exit $HAS_ERRORS
