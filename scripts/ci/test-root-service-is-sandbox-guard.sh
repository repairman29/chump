#!/usr/bin/env bash
# scripts/ci/test-root-service-is-sandbox-guard.sh — INFRA-3603
#
# WHY: `claude -p ... --dangerously-skip-permissions` refuses to run as
# root/sudo unless IS_SANDBOX=1 is exported first (see
# book/src/LINUX_NODE_ONBOARDING.md). Every root-owned systemd .service
# unit (no User= line -> runs as root) whose ExecStart chain calls that
# invocation MUST export IS_SANDBOX=1 when uid==0, or the beat silently
# exits 1 on every single cycle forever (chump-board-cycle.service ran
# broken for days before INFRA-3603 caught it live on helsinki).
#
# This is a regression gate, not an audit: it finds every root-owned
# *.service unit, resolves the script(s) its ExecStart/ExecStartPre lines
# invoke, and fails if any resolved script calls
# --dangerously-skip-permissions without also referencing IS_SANDBOX.
set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

echo "=== INFRA-3603 root-service IS_SANDBOX guard check ==="

# Find all *.service units with no User= line (root-owned) anywhere in the repo.
mapfile -t ROOT_SERVICES < <(find . -name "*.service" -not -path "./target/*" 2>/dev/null | sort)

if [[ "${#ROOT_SERVICES[@]}" -eq 0 ]]; then
    fail "no .service files found — check discovery glob"
    echo "=== $PASS passed, $FAIL failed ==="
    exit 1
fi

checked_any=0
for svc in "${ROOT_SERVICES[@]}"; do
    if grep -q '^User=' "$svc"; then
        continue  # explicit non-root user — out of scope
    fi
    if grep -q '__RUN_USER__' "$svc"; then
        continue  # templated unit substituted at provision time, not root by default
    fi

    # Pull every scripts/**/*.sh path referenced by ExecStart / ExecStartPre lines.
    mapfile -t referenced < <(grep -E '^Exec(Start|StartPre)=' "$svc" | grep -oE 'scripts/[A-Za-z0-9_./@-]+\.sh' | sort -u)

    for rel in "${referenced[@]}"; do
        target="$REPO_ROOT/$rel"
        [[ -f "$target" ]] || continue
        checked_any=1

        if ! grep -q -- '--dangerously-skip-permissions' "$target"; then
            continue  # doesn't invoke claude -p unattended — not in scope
        fi

        if grep -q 'IS_SANDBOX' "$target"; then
            ok "$rel (referenced by $svc) has IS_SANDBOX guard"
        else
            fail "$rel (referenced by root-owned $svc) calls --dangerously-skip-permissions with no IS_SANDBOX guard — will exit 1 under root systemd (see INFRA-3603)"
        fi
    done
done

if [[ "$checked_any" -eq 0 ]]; then
    fail "no scripts/**/*.sh calling claude -p were resolved from any root .service — check the ExecStart parse regex still matches current unit files"
fi

echo "=== $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    printf 'FAILURES:\n'
    printf ' - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
