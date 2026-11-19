#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# INFRA-1437: smoke test for `chump session-summary`.
#
# Verifies:
#   1. Source contract — session_summary.rs exports the public surface we
#      depend on (parse_args, render_text, render_json).
#   2. Wiring — main.rs dispatches the subcommand and the help banner
#      mentions it.
#   3. End-to-end — stub `gh` via the CHUMP_SESSION_SUMMARY_GH_STUB env hook
#      with synthetic PR lists, run the real binary, assert the rendered
#      table contains the expected three sections (Merged / Armed / Filed)
#      and that auto-merge classification holds.
#
# Does not mutate the working tree. Skips end-to-end if no chump binary is
# available (matches preflight-scope test convention).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── 1. Source-contract checks ──────────────────────────────────────────────
grep -q 'pub fn parse_args' src/session_summary.rs \
    || fail "src/session_summary.rs missing pub fn parse_args"
grep -q 'pub fn render_text' src/session_summary.rs \
    || fail "src/session_summary.rs missing pub fn render_text"
grep -q 'pub fn render_json' src/session_summary.rs \
    || fail "src/session_summary.rs missing pub fn render_json"
grep -q 'pub fn run' src/session_summary.rs \
    || fail "src/session_summary.rs missing pub fn run"
grep -q 'CHUMP_SESSION_SUMMARY_GH_STUB' src/session_summary.rs \
    || fail "src/session_summary.rs missing CHUMP_SESSION_SUMMARY_GH_STUB hook"

# Wiring in main.rs
grep -q 'mod session_summary' src/main.rs \
    || fail "src/main.rs missing 'mod session_summary'"
grep -q 'Some("session-summary")' src/main.rs \
    || fail "src/main.rs missing session-summary dispatch"

echo "[1/3] source contract + wiring: OK"

# ── 2. Locate chump binary (skip end-to-end if absent) ─────────────────────
CHUMP_BIN=""
for candidate in \
    "$REPO_ROOT/target/release/chump" \
    "$REPO_ROOT/target/debug/chump"; do
    if [[ -x "$candidate" ]]; then
        CHUMP_BIN="$candidate"
        break
    fi
done

if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$REPO_ROOT/scripts/dispatch/ensure-debug-chump.sh" ]]; then
        bash "$REPO_ROOT/scripts/dispatch/ensure-debug-chump.sh" >/dev/null 2>&1 || true
        if [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
            CHUMP_BIN="$REPO_ROOT/target/debug/chump"
        fi
    fi
fi

if [[ -z "$CHUMP_BIN" ]]; then
    echo "[skip] no chump binary available — contract checks passed"
    exit 0
fi

# ── 3. End-to-end with stubbed gh ──────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub responds based on whether --state merged or --state open appears in argv.
# Synthetic data:
#   merged: PR 9001 (INFRA-9001), PR 9002 (no gap)
#   open:   PR 9100 with autoMergeRequest non-null  → Armed
#           PR 9101 with autoMergeRequest null       → Filed
cat > "$TMP/gh-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -e
mode=""
for a in "$@"; do
    case "$a" in
        merged) mode="merged" ;;
        open)   mode="open"   ;;
    esac
done
if [[ "$mode" == "merged" ]]; then
    cat <<'JSON'
[{"number":9001,"title":"feat(INFRA-9001): synthetic merged change"},{"number":9002,"title":"chore: bump deps"}]
JSON
elif [[ "$mode" == "open" ]]; then
    cat <<'JSON'
[{"number":9100,"title":"feat(INFRA-9100): armed pr","autoMergeRequest":{"mergeMethod":"SQUASH"}},{"number":9101,"title":"feat(INFRA-9101): filed pr","autoMergeRequest":null}]
JSON
else
    echo "stub: unexpected mode" >&2
    exit 2
fi
STUB
chmod +x "$TMP/gh-stub.sh"

OUT="$TMP/out.txt"
CHUMP_SESSION_SUMMARY_GH_STUB="$TMP/gh-stub.sh" \
    "$CHUMP_BIN" session-summary --since 2026-05-21 > "$OUT" 2>&1 \
    || fail "chump session-summary exited non-zero (output: $(cat "$OUT"))"

grep -q 'Session: 2026-05-21 (window 24h)' "$OUT" \
    || fail "header line missing/wrong (output: $(cat "$OUT"))"
grep -q '^Merged:' "$OUT" \
    || fail "Merged section missing"
grep -qE '#9001 .*INFRA-9001' "$OUT" \
    || fail "merged PR #9001 not in output"
grep -qE '#9002' "$OUT" \
    || fail "merged PR #9002 (no gap) not in output"
grep -q '^Armed (auto-merge pending CI):' "$OUT" \
    || fail "Armed section missing"
grep -qE '#9100 .*INFRA-9100' "$OUT" \
    || fail "armed PR #9100 not in output"
grep -q '^Filed (PR opened, not yet merged):' "$OUT" \
    || fail "Filed section missing"
grep -qE '#9101 .*INFRA-9101' "$OUT" \
    || fail "filed PR #9101 not in output"

# Armed PR #9100 must NOT appear under Filed, and vice versa.
filed_section="$(awk '/^Filed/{flag=1; next} flag' "$OUT")"
echo "$filed_section" | grep -q '#9100' \
    && fail "armed PR #9100 leaked into Filed section"
armed_section="$(awk '/^Armed/{flag=1; next} /^Filed/{flag=0} flag' "$OUT")"
echo "$armed_section" | grep -q '#9101' \
    && fail "filed PR #9101 leaked into Armed section"

echo "[2/3] text output: 3 sections rendered correctly"

# JSON path
OUTJ="$TMP/out.json"
CHUMP_SESSION_SUMMARY_GH_STUB="$TMP/gh-stub.sh" \
    "$CHUMP_BIN" session-summary --since 2026-05-21 --json > "$OUTJ" 2>&1 \
    || fail "chump session-summary --json exited non-zero"

grep -q '"since":"2026-05-21"' "$OUTJ" || fail "json missing since"
grep -q '"window":"24h"' "$OUTJ" || fail "json missing window"
grep -q '"merged":\[' "$OUTJ" || fail "json missing merged array"
grep -q '"armed":\[' "$OUTJ" || fail "json missing armed array"
grep -q '"filed":\[' "$OUTJ" || fail "json missing filed array"
grep -q '"number":9100' "$OUTJ" || fail "json missing armed PR #9100"

echo "[3/3] json output: shape matches"
echo "OK: scripts/ci/test-session-summary.sh"
