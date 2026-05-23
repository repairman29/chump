#!/usr/bin/env bash
# scripts/ci/test-chump-commit-auto-fmt.sh — INFRA-1833
#
# Verifies chump-commit.sh contains the INFRA-1833 auto-fmt block:
# runs cargo fmt --all before git commit when staged delta includes .rs,
# honors CHUMP_AUTO_FMT=0 bypass with audit emit.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/chump-commit.sh"

failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }

ag "$SCRIPT" "INFRA-1833" "chump-commit.sh has INFRA-1833 attribution"
ag "$SCRIPT" 'cargo fmt --all' "chump-commit.sh invokes cargo fmt --all"
ag "$SCRIPT" '_has_rust_staged' "chump-commit.sh gates fmt on staged Rust delta"
ag "$SCRIPT" "CHUMP_AUTO_FMT" "chump-commit.sh honors CHUMP_AUTO_FMT bypass"
ag "$SCRIPT" "auto_fmt_applied" "chump-commit.sh emits auto_fmt_applied ambient event"
ag "$SCRIPT" "auto_fmt_bypassed" "chump-commit.sh emits auto_fmt_bypassed on CHUMP_AUTO_FMT=0"
ag "$SCRIPT" "git add -A" "chump-commit.sh re-stages files cargo fmt touched"

# Structural check: the auto-fmt block must appear BEFORE the final 'git commit'
fmt_line=$(grep -n "cargo fmt --all" "$SCRIPT" | head -1 | cut -d: -f1)
commit_line=$(grep -n "^git commit \"\${GIT_ARGS\[@\]}\"" "$SCRIPT" | tail -1 | cut -d: -f1)
if [[ -n "$fmt_line" && -n "$commit_line" ]]; then
    if [[ "$fmt_line" -ge "$commit_line" ]]; then
        echo "FAIL: cargo fmt --all (line $fmt_line) must precede git commit (line $commit_line)"
        failures=$((failures+1))
    fi
else
    echo "FAIL: couldn't locate fmt or commit lines in script"
    failures=$((failures+1))
fi

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1833: $failures"; exit 1; }
echo "OK INFRA-1833: chump-commit.sh auto-runs cargo fmt --all before commit"
