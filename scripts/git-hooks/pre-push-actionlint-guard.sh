#!/usr/bin/env bash
# pre-push-actionlint-guard.sh — INFRA-2322
#
# Runs `actionlint` against every .github/workflows/*.yml file changed in
# this push and blocks on real findings. Catches the two recurring classes
# that have reached main via manual review before:
#   - matrix-in-if: a job-level `if:` expression referencing `matrix.*`,
#     which is not in scope until the step level (actionlint flags this as
#     an undefined-variable / context error).
#   - version-typo: a malformed `uses: owner/repo@ref` pin (typo'd action
#     name, missing @ref, etc.) — actionlint validates the `uses:` grammar.
# actionlint's general expression/schema checker catches both classes plus
# the broader syntax-error surface, so this gate is intentionally generic
# rather than pattern-matching those two classes by hand.
#
# Failure-class taxonomy (INFRA-2322):
#   - permanent (blocking): actionlint ran successfully and reported >=1
#     finding against a changed workflow file. The push is blocked; the
#     fix is to correct the workflow file.
#   - transient (non-blocking, warn + skip): the actionlint binary is not
#     installed locally, or it errored for a reason unrelated to workflow
#     content (e.g. crashed). Never blocks a push on tooling absence —
#     this class is Tier-D per docs/process/CI_GATES_INVENTORY.md and the
#     real gate is the CI-side actionlint step; this hook is the fast local
#     pre-catch when the binary happens to be present.
#
# Observability: emits one ambient event per run (pass/fail/skip), each
# carrying duration_ms so the cost of the gate is visible in
# api-cost/waste-tally style rollups without a separate cost-tracking path.
#
# Bypass: CHUMP_ACTIONLINT_GUARD=0 git push
#
# Smoke test: scripts/ci/test-pre-push-actionlint-guard.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

_START_MS=$(($(date +%s%N 2>/dev/null || echo 0) / 1000000))

emit_ambient() {
    local kind="$1" note="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local now_ms=$(($(date +%s%N 2>/dev/null || echo 0) / 1000000))
    local dur=$((now_ms - _START_MS))
    printf '{"ts":"%s","kind":"%s","source":"pre-push-actionlint-guard","note":"%s","duration_ms":%d}\n' \
        "$ts" "$kind" "$note" "$dur" >> "$AMBIENT" 2>/dev/null || true
}

if [[ "${CHUMP_ACTIONLINT_GUARD:-1}" == "0" ]]; then
    echo "[actionlint-guard] CHUMP_ACTIONLINT_GUARD=0 — guard disabled." >&2
    exit 0
fi

# scanner-anchor: "kind":"actionlint_guard_skipped"
# scanner-anchor: "kind":"actionlint_guard_blocked"
# scanner-anchor: "kind":"actionlint_guard_passed"
BASE_REF="origin/main"
if ! git rev-parse "$BASE_REF" &>/dev/null; then
    echo "[actionlint-guard] WARN: cannot resolve $BASE_REF; skipping guard." >&2
    emit_ambient "actionlint_guard_skipped" "no-base-ref"
    exit 0
fi

mapfile -t CHANGED_WORKFLOWS < <(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null \
    | grep -E '^\.github/workflows/.*\.ya?ml$' || true)

if [[ "${#CHANGED_WORKFLOWS[@]}" -eq 0 ]]; then
    exit 0
fi

if ! command -v actionlint &>/dev/null; then
    echo "[actionlint-guard] WARN: actionlint binary not found — skipping local gate (transient class)." >&2
    echo "[actionlint-guard] Install: brew install actionlint (or go install github.com/rhysd/actionlint/cmd/actionlint@latest)" >&2
    echo "[actionlint-guard] The CI-side actionlint step (META-199) still gates this PR on GitHub." >&2
    emit_ambient "actionlint_guard_skipped" "binary-not-installed"
    exit 0
fi

echo "[actionlint-guard] Checking ${#CHANGED_WORKFLOWS[@]} changed workflow file(s) with actionlint..." >&2

FAILED=0
FINDINGS=""
for wf in "${CHANGED_WORKFLOWS[@]}"; do
    [[ -f "$REPO_ROOT/$wf" ]] || continue
    if ! out="$(actionlint "$REPO_ROOT/$wf" 2>&1)"; then
        FAILED=1
        echo "[actionlint-guard]   ✗ $wf" >&2
        echo "$out" | sed 's/^/[actionlint-guard]     /' >&2
        FINDINGS="${FINDINGS}${wf}: $(echo "$out" | head -1);"
    else
        echo "[actionlint-guard]   ✓ $wf" >&2
    fi
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "" >&2
    echo "[actionlint-guard] BLOCKED (INFRA-2322): actionlint reported findings in changed workflow file(s)." >&2
    echo "[actionlint-guard] Common classes: matrix-in-if (matrix.* referenced in a job-level if:)," >&2
    echo "[actionlint-guard] and version-typo (malformed uses: owner/repo@ref pin)." >&2
    echo "[actionlint-guard] Bypass (rare, document why): CHUMP_ACTIONLINT_GUARD=0 git push" >&2
    echo "" >&2
    emit_ambient "actionlint_guard_blocked" "$FINDINGS"
    exit 1
fi

echo "[actionlint-guard] ✓ all changed workflow file(s) clean." >&2
emit_ambient "actionlint_guard_passed" "${#CHANGED_WORKFLOWS[@]} file(s) checked"
exit 0
