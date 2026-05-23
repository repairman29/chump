#!/usr/bin/env bash
# scripts/ci/test-chump-commit-auto-envvar.sh — INFRA-1853
#
# Verifies scripts/coord/chump-commit.sh contains the auto-envvar-append
# block: detects new CHUMP_* env refs in staged Rust/scripts, appends to
# env-vars-internal.txt with AUTO breadcrumb, honors CHUMP_AUTO_ENVVAR=0
# bypass with audit emit.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/chump-commit.sh"
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"

failures=0
ag() { grep -qE -- "$2" "$1" 2>/dev/null || { echo "FAIL: $3"; failures=$((failures+1)); }; }

ag "$SCRIPT" "INFRA-1853" "chump-commit.sh has INFRA-1853 attribution"
ag "$SCRIPT" "env-vars-internal.txt" "chump-commit.sh references env-vars-internal.txt"
ag "$SCRIPT" "CHUMP_\[A-Z\]\[A-Z0-9_\]\+" "chump-commit.sh uses CHUMP_* env-detection regex"
ag "$SCRIPT" "CHUMP_AUTO_ENVVAR" "chump-commit.sh honors CHUMP_AUTO_ENVVAR bypass"
ag "$SCRIPT" "auto_envvar_applied" "chump-commit.sh emits auto_envvar_applied"
ag "$SCRIPT" "auto_envvar_bypassed" "chump-commit.sh emits auto_envvar_bypassed on bypass"
ag "$SCRIPT" "AUTO \(INFRA-1853\)" "chump-commit.sh writes AUTO breadcrumb comment"
ag "$SCRIPT" "git add .*_envvar_file" "chump-commit.sh re-stages env-vars-internal.txt"

ag "$RESERVED" "^auto_envvar_applied" "reserved.txt allowlists auto_envvar_applied"
ag "$RESERVED" "^auto_envvar_bypassed" "reserved.txt allowlists auto_envvar_bypassed"

# Structural: the new block must appear BEFORE git commit
new_block=$(grep -n "INFRA-1853:" "$SCRIPT" | head -1 | cut -d: -f1)
commit_line=$(grep -n "^git commit \"\${GIT_ARGS\[@\]}\"" "$SCRIPT" | tail -1 | cut -d: -f1)
if [[ -n "$new_block" && -n "$commit_line" && "$new_block" -ge "$commit_line" ]]; then
    echo "FAIL: INFRA-1853 block (line $new_block) must precede git commit (line $commit_line)"
    failures=$((failures+1))
fi

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-1853: $failures"; exit 1; }
echo "OK INFRA-1853: chump-commit.sh auto-appends new CHUMP_* envs to env-vars-internal.txt"
