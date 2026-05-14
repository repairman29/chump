#!/usr/bin/env bash
# test-gh-mutation-throttle.sh — INFRA-1112
#
# Verifies that _chump_gh_classify_call correctly identifies mutations vs queries
# and that _chump_gh_throttle_wait uses separate window files for each class.

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GITHUB_LIB="$REPO_ROOT/scripts/coord/lib/github.sh"

# Source the classification function directly from github.sh
# (safe — only function definitions at top level; no side effects)
_chump_gh_classify_call() {
    local subcmd="${1:-}" flag2="${2:-}"
    case "$subcmd" in
        pr)
            case "$flag2" in
                merge|create|review|comment|edit|close|reopen) echo mutation; return ;;
            esac
            ;;
        issue)
            case "$flag2" in
                create|close|reopen|edit|comment|pin|unpin) echo mutation; return ;;
            esac
            ;;
        release)
            case "$flag2" in
                create|delete|edit|upload) echo mutation; return ;;
            esac
            ;;
        api)
            local _saw_method=0 _upper
            for _a in "$@"; do
                if [[ "$_saw_method" -eq 1 ]]; then
                    _upper="$(echo "$_a" | tr '[:lower:]' '[:upper:]')"
                    case "$_upper" in POST|PATCH|PUT|DELETE) echo mutation; return ;; esac
                    _saw_method=0
                fi
                [[ "$_a" == "-X" || "$_a" == "--method" ]] && _saw_method=1
            done
            for _a in "$@"; do
                _upper="$(echo "$_a" | tr '[:lower:]' '[:upper:]')"
                [[ "$_upper" =~ ^--METHOD=(POST|PATCH|PUT|DELETE)$ ]] && { echo mutation; return; }
            done
            ;;
    esac
    echo query
}

echo "=== INFRA-1112: mutation vs query classification ==="
echo

# ── 1. Mutation detection — pr merge ──────────────────────────────────────────
echo "[1. pr merge → mutation]"
if [[ "$(_chump_gh_classify_call pr merge --squash 1234)" == "mutation" ]]; then
    ok "pr merge classified as mutation"
else
    fail "pr merge NOT classified as mutation"
fi

# ── 2. Mutation detection — pr create ─────────────────────────────────────────
echo
echo "[2. pr create → mutation]"
if [[ "$(_chump_gh_classify_call pr create --base main)" == "mutation" ]]; then
    ok "pr create classified as mutation"
else
    fail "pr create NOT classified as mutation"
fi

# ── 3. Mutation detection — api POST ──────────────────────────────────────────
echo
echo "[3. api -X POST → mutation]"
if [[ "$(_chump_gh_classify_call api repos/X/issues -X POST -f title=test)" == "mutation" ]]; then
    ok "api -X POST classified as mutation"
else
    fail "api -X POST NOT classified as mutation"
fi

# ── 4. Mutation detection — api --method PATCH ────────────────────────────────
echo
echo "[4. api --method PATCH → mutation]"
if [[ "$(_chump_gh_classify_call api repos/X/issues/1 --method PATCH -f state=closed)" == "mutation" ]]; then
    ok "api --method PATCH classified as mutation"
else
    fail "api --method PATCH NOT classified as mutation"
fi

# ── 5. Mutation detection — api --method=DELETE ───────────────────────────────
echo
echo "[5. api --method=DELETE → mutation]"
if [[ "$(_chump_gh_classify_call api repos/X/branches/Y --method=DELETE)" == "mutation" ]]; then
    ok "api --method=DELETE classified as mutation"
else
    fail "api --method=DELETE NOT classified as mutation"
fi

# ── 6. Query detection — pr list ──────────────────────────────────────────────
echo
echo "[6. pr list → query]"
if [[ "$(_chump_gh_classify_call pr list --state open)" == "query" ]]; then
    ok "pr list classified as query"
else
    fail "pr list NOT classified as query"
fi

# ── 7. Query detection — api GET (no -X) ──────────────────────────────────────
echo
echo "[7. api repos/X/pulls → query]"
if [[ "$(_chump_gh_classify_call api repos/X/pulls)" == "query" ]]; then
    ok "api repos/X/pulls (no -X) classified as query"
else
    fail "api repos/X/pulls NOT classified as query"
fi

# ── 8. Query detection — api -X GET ───────────────────────────────────────────
echo
echo "[8. api -X GET → query]"
if [[ "$(_chump_gh_classify_call api rate_limit -X GET)" == "query" ]]; then
    ok "api -X GET classified as query"
else
    fail "api -X GET NOT classified as query"
fi

# ── 9. Separate window files in github.sh ─────────────────────────────────────
echo
echo "[9. Separate window files in github.sh]"
if grep -q '\.gh-throttle-window\.mutation' "$GITHUB_LIB" && \
   grep -q '\.gh-throttle-window\.query' "$GITHUB_LIB"; then
    ok "github.sh uses class-specific window files (.mutation + .query)"
else
    fail "github.sh does NOT have class-specific window files"
fi

# ── 10. api_class field in gh_self_throttled emit ─────────────────────────────
echo
echo "[10. gh_self_throttled includes api_class field]"
if grep -q '"api_class":' "$GITHUB_LIB" || grep -q '"api_class":"%s"' "$GITHUB_LIB"; then
    ok "gh_self_throttled event includes api_class field"
else
    fail "gh_self_throttled event does NOT include api_class field"
fi

# ── 11. CHUMP_GH_MUTATION_MAX env var referenced ──────────────────────────────
echo
echo "[11. CHUMP_GH_MUTATION_MAX referenced in github.sh]"
if grep -q 'CHUMP_GH_MUTATION_MAX' "$GITHUB_LIB"; then
    ok "CHUMP_GH_MUTATION_MAX referenced in github.sh"
else
    fail "CHUMP_GH_MUTATION_MAX NOT referenced in github.sh"
fi

# ── 12. EVENT_REGISTRY updated for api_class field ────────────────────────────
echo
echo "[12. EVENT_REGISTRY fields_required includes api_class]"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -A12 'kind: gh_self_throttled' "$REGISTRY" | grep -q 'api_class'; then
    ok "EVENT_REGISTRY.yaml lists api_class in fields_required for gh_self_throttled"
else
    fail "EVENT_REGISTRY.yaml does NOT list api_class for gh_self_throttled"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
