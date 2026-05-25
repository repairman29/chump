#!/usr/bin/env bash
# scripts/ci/test-hook-stdin-drain.sh — INFRA-1990 (THE FLOOR Phase 2)
#
# Static-analysis CI gate: prevents the INFRA-1986 silent-regression class
# from regressing. The bug was: pre-push hook had 2 `while read` loops
# consuming stdin without buffering — the first loop drained stdin, the
# main Guard 1/2/3 loop got EOF and silently exited 0. Force-push race
# protection was OFF for 3 days before anyone noticed.
#
# This gate counts `while read local_sha|remote_sha|local_ref|remote_ref`
# loops in each hook under scripts/git-hooks/*. If any hook has >1 such
# loop without the `_HOOK_STDIN=$(cat || true)` cache pattern, FAIL.
#
# The cache pattern: read stdin ONCE at the top, then feed each loop
# via `done <<<"$_HOOK_STDIN"`. The INFRA-1986 fix established this.
#
# Acceptable:
#   _HOOK_STDIN="$(cat || true)"
#   while read … done <<<"$_HOOK_STDIN"   # loop 1
#   while read … done <<<"$_HOOK_STDIN"   # loop 2
#
# Not acceptable:
#   while read … done <<<"$(cat || true)"  # loop 1 drains real stdin
#   while read … done                       # loop 2 gets EOF, silent
#
# Bypass: CHUMP_HOOK_STDIN_GATE_BYPASS=1 + commit body trailer
#         'Hook-Stdin-Gate-Bypass: <reason>'

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK_DIR="$REPO_ROOT/scripts/git-hooks"
PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1990 hook stdin-drain CI gate ==="
echo

# Bypass env (must be paired with commit body trailer)
if [[ "${CHUMP_HOOK_STDIN_GATE_BYPASS:-0}" == "1" ]]; then
    echo "[WARN] CHUMP_HOOK_STDIN_GATE_BYPASS=1 — gate disabled"
    echo "       Commit body must include 'Hook-Stdin-Gate-Bypass: <reason>'"
    exit 0
fi

[[ -d "$HOOK_DIR" ]] || { echo "FATAL: no $HOOK_DIR"; exit 2; }

# Find hooks that have ANY stdin-consuming `while read` over the
# pre-push ref-protocol fields (local_sha/remote_sha/local_ref/remote_ref).
# Returns one hook path per line.
audit_hook() {
    local hook="$1"
    local hname; hname="$(basename "$hook")"

    # Count `while read` loops that bind local_sha/remote_sha/local_ref/remote_ref.
    # Match any `while ... read ... <one of the 4 vars>` — IFS prefix may
    # contain quoted spaces (e.g. IFS=' '), so allow loose middle match.
    # Note: grep -c prints "0" AND exits 1 on no-match — so use grep | wc -l
    # instead to avoid `|| echo 0` doubling the count.
    local loop_count
    loop_count="$(grep -E 'while[[:space:]].*read[[:space:]]+-r[[:space:]].*(local_sha|local_ref|remote_sha|remote_ref)' "$hook" 2>/dev/null | wc -l | xargs)"
    loop_count="${loop_count:-0}"

    if [[ "$loop_count" -le 1 ]]; then
        ok "$hname: $loop_count stdin-consuming loop(s) — OK"
        return
    fi

    # Multiple loops: require the cache pattern.
    if grep -q "_HOOK_STDIN" "$hook"; then
        # Each loop must redirect from the cache. Spot-check: count
        # `done <<<"$_HOOK_STDIN"` and require >= loop_count.
        local cache_uses
        cache_uses="$(grep -E 'done[[:space:]]*<<<[[:space:]]*"\$_HOOK_STDIN"' "$hook" 2>/dev/null | wc -l | xargs)"
        cache_uses="${cache_uses:-0}"
        if [[ "$cache_uses" -ge "$loop_count" ]]; then
            ok "$hname: $loop_count loops, $cache_uses use _HOOK_STDIN cache — OK"
        else
            fail "$hname: $loop_count stdin-consuming loops but only $cache_uses use _HOOK_STDIN — potential silent-drain regression (see INFRA-1986)"
        fi
    else
        fail "$hname: $loop_count stdin-consuming loops, NO _HOOK_STDIN cache — silent-drain regression risk (the INFRA-1986 class)"
    fi
}

# Audit every executable hook (no .sh extension on git hooks; pre-push, etc.)
for hook in "$HOOK_DIR"/*; do
    # Skip directories + non-hook helper scripts (pre-commit-*.sh, etc.)
    [[ -f "$hook" ]] || continue
    [[ -x "$hook" ]] || continue
    case "$(basename "$hook")" in
        pre-commit-*.sh|pre-push-ci-regression-guard.sh)
            # Helper sub-hooks aren't invoked by git directly; they
            # source the main hook env and don't consume stdin.
            continue
            ;;
    esac
    audit_hook "$hook"
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "Failures detected — these hooks risk the INFRA-1986 silent-regression class."
    echo "Fix: cache stdin once at top:"
    echo "  _HOOK_STDIN=\"\$(cat || true)\""
    echo "Then feed each loop:"
    echo "  while read … done <<<\"\$_HOOK_STDIN\""
    echo
    echo "Bypass (with audit trail):"
    echo "  CHUMP_HOOK_STDIN_GATE_BYPASS=1 git push"
    echo "  Commit body: Hook-Stdin-Gate-Bypass: <reason>"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
