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
# INFRA-1649: `run_guard` (below) additionally prints a one-line summary —
# `guard: ok` on stdout for any non-blocking outcome (pass or transient
# skip), or `guard: fail class=<transient|permanent>` on stderr + exit 1
# for a blocking outcome — so callers can grep a single line instead of
# re-deriving pass/fail from ambient.jsonl.
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

# INFRA-1649: the hardened guard body, split into a function so the
# permanent/transient failure class it settles on can be reported in a
# single summary line by the caller below, instead of being buried in
# per-file stderr output. Sets the global GUARD_FAILURE_CLASS on any
# non-zero return (transient|permanent); leaves it unset on success.
GUARD_FAILURE_CLASS=""

run_guard() {
    if [[ "${CHUMP_ACTIONLINT_GUARD:-1}" == "0" ]]; then
        echo "[actionlint-guard] CHUMP_ACTIONLINT_GUARD=0 — guard disabled." >&2
        return 0
    fi

    # scanner-anchor: "kind":"actionlint_guard_skipped"
    # scanner-anchor: "kind":"actionlint_guard_blocked"
    # scanner-anchor: "kind":"actionlint_guard_passed"
    local base_ref="origin/main"
    if ! git rev-parse "$base_ref" &>/dev/null; then
        echo "[actionlint-guard] WARN: cannot resolve $base_ref; skipping guard." >&2
        emit_ambient "actionlint_guard_skipped" "no-base-ref"
        return 0
    fi

    local changed_workflows
    mapfile -t changed_workflows < <(git diff --name-only "${base_ref}...HEAD" 2>/dev/null \
        | grep -E '^\.github/workflows/.*\.ya?ml$' || true)

    if [[ "${#changed_workflows[@]}" -eq 0 ]]; then
        return 0
    fi

    if ! command -v actionlint &>/dev/null; then
        echo "[actionlint-guard] WARN: actionlint binary not found — skipping local gate (transient class)." >&2
        echo "[actionlint-guard] Install: brew install actionlint (or go install github.com/rhysd/actionlint/cmd/actionlint@latest)" >&2
        echo "[actionlint-guard] The CI-side actionlint step (META-199) still gates this PR on GitHub." >&2
        emit_ambient "actionlint_guard_skipped" "binary-not-installed"
        return 0
    fi

    echo "[actionlint-guard] Checking ${#changed_workflows[@]} changed workflow file(s) with actionlint..." >&2

    local findings="" real_findings=0 tool_errors=0 out rc
    for wf in "${changed_workflows[@]}"; do
        [[ -f "$REPO_ROOT/$wf" ]] || continue
        out="$(actionlint "$REPO_ROOT/$wf" 2>&1)"
        rc=$?
        if [[ "$rc" -eq 0 ]]; then
            echo "[actionlint-guard]   ✓ $wf" >&2
        elif [[ "$rc" -eq 1 ]]; then
            # INFRA-1649: exit 1 is actionlint's documented "ran fine, found
            # >=1 real finding" code — a permanent (blocking) class, since
            # retrying the identical push fails the same way until the
            # workflow file is fixed.
            real_findings=1
            echo "[actionlint-guard]   ✗ $wf" >&2
            echo "$out" | sed 's/^/[actionlint-guard]     /' >&2
            findings="${findings}${wf}: $(echo "$out" | head -1);"
        else
            # INFRA-1649: any other exit code (crash, bad invocation, OOM,
            # signal) is a transient tool error, not a workflow finding —
            # never block a push on the linter itself misbehaving.
            tool_errors=1
            echo "[actionlint-guard]   ⚠ $wf — actionlint exited $rc (tool error, non-blocking):" >&2
            echo "$out" | sed 's/^/[actionlint-guard]     /' >&2
        fi
    done

    if [[ "$real_findings" -ne 0 ]]; then
        echo "" >&2
        echo "[actionlint-guard] BLOCKED (INFRA-2322): actionlint reported findings in changed workflow file(s)." >&2
        echo "[actionlint-guard] Common classes: matrix-in-if (matrix.* referenced in a job-level if:)," >&2
        echo "[actionlint-guard] and version-typo (malformed uses: owner/repo@ref pin)." >&2
        echo "[actionlint-guard] Bypass (rare, document why): CHUMP_ACTIONLINT_GUARD=0 git push" >&2
        echo "" >&2
        emit_ambient "actionlint_guard_blocked" "$findings"
        GUARD_FAILURE_CLASS="permanent"
        return 1
    fi

    if [[ "$tool_errors" -ne 0 ]]; then
        echo "[actionlint-guard] WARN: actionlint tool error(s) on this run — treated as transient, not blocking." >&2
        emit_ambient "actionlint_guard_skipped" "tool-error"
        return 0
    fi

    echo "[actionlint-guard] ✓ all changed workflow file(s) clean." >&2
    emit_ambient "actionlint_guard_passed" "${#changed_workflows[@]} file(s) checked"
    return 0
}

if run_guard; then
    echo "guard: ok"
    exit 0
else
    echo "guard: fail class=${GUARD_FAILURE_CLASS:-permanent}" >&2
    exit 1
fi
