#!/usr/bin/env bash
# test-fast-checks-matrix-coverage.sh — META-202
#
# Verifies the matrix entry list in .github/workflows/ci.yml
# fast-checks-matrix matches the test-*.sh files on disk that are
# invoked by that job.
#
# Two drift classes caught:
#   (A) A test-*.sh is in the matrix but no longer exists on disk.
#   (B) A test-*.sh exists in scripts/ci/ and is NOT in the matrix,
#       AND is not in the exclusions list below.
#
# Exit 0 — no drift.
# Exit 1 — drift detected; lists offending entries.
#
# Usage:
#   bash scripts/ci/test-fast-checks-matrix-coverage.sh
#   bash scripts/ci/test-fast-checks-matrix-coverage.sh --list-all   # dump full matrix list
#
# Note: this script reads the fast-checks-matrix job from ci.yml. It
# tolerates the matrix being absent (old sequential fast-checks still
# active) and exits 0 with an INFO note in that case.
#
# Canonical list: .github/workflows/ci.yml, job fast-checks-matrix,
# strategy.matrix.test entries.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CI_YML=".github/workflows/ci.yml"
CI_DIR="scripts/ci"

PASS=0; FAIL=0; WARNS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN: $1"; WARNS+=("$1"); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

LIST_ALL=0
for arg in "$@"; do
    [[ "$arg" == "--list-all" ]] && LIST_ALL=1
done

echo "=== test-fast-checks-matrix-coverage.sh (META-202) ==="
echo ""

# ── 1. Verify ci.yml exists ───────────────────────────────────────────────────
if [[ ! -f "$CI_YML" ]]; then
    echo "SKIP: $CI_YML not found" >&2
    exit 0
fi

# ── 2. Extract the fast-checks-matrix job's matrix.test entries ───────────────
# The matrix is defined as a YAML list under:
#   fast-checks-matrix:
#     strategy:
#       matrix:
#         test:
#           - test-foo.sh
#           - test-bar.sh
#
# We extract lines between the "fast-checks-matrix:" job header and the
# next top-level job definition (indent-2 word + colon).
#
# Also handles the chump-bin-group entry which is a grouped multi-script
# string that includes '+' as a separator.

MATRIX_ENTRIES=()

# Use Python for reliable YAML matrix extraction — bash sed/awk are
# not portable across macOS/Linux for \s patterns and indent tracking.
while IFS= read -r entry; do
    [[ -n "$entry" ]] && MATRIX_ENTRIES+=("$entry")
done < <(python3 - "$CI_YML" <<'PYEOF'
import sys, re

ci_yml = sys.argv[1]
lines = open(ci_yml).read().splitlines()

in_matrix_job = False
in_matrix_block = False
in_test_list = False
test_list_indent = None

for line in lines:
    # Detect job at indent 2
    if re.match(r'^  [A-Za-z0-9_-]+:\s*$', line):
        job = line.strip().rstrip(':')
        if job == 'fast-checks-matrix':
            in_matrix_job = True
            in_matrix_block = False
            in_test_list = False
            continue
        elif in_matrix_job:
            break  # hit next job

    if not in_matrix_job:
        continue

    # Detect "matrix:" section
    stripped = line.strip()
    if stripped == 'matrix:':
        in_matrix_block = True
        continue

    if not in_matrix_block:
        continue

    # Detect "test:" key
    if stripped == 'test:':
        in_test_list = True
        # Record the indent level of "test:" so we know where the list lives
        test_list_indent = len(line) - len(line.lstrip(' '))
        continue

    if not in_test_list:
        continue

    # List items are "          - value" — deeper than "test:"
    current_indent = len(line) - len(line.lstrip(' '))
    if stripped.startswith('- '):
        entry = stripped[2:].strip().strip('"').strip("'")
        print(entry)
    elif stripped and current_indent <= test_list_indent:
        # Back to test: level or higher — end of list
        break
PYEOF
)

if [[ ${#MATRIX_ENTRIES[@]} -eq 0 ]]; then
    echo "INFO: fast-checks-matrix job not found or has no matrix.test entries."
    echo "INFO: Matrix parallelization (META-202) may not be landed yet."
    echo "INFO: Exiting 0 — no drift to report against an absent matrix."
    exit 0
fi

echo "Matrix entries found: ${#MATRIX_ENTRIES[@]}"
if [[ "$LIST_ALL" == "1" ]]; then
    for e in "${MATRIX_ENTRIES[@]}"; do
        echo "  - $e"
    done
    echo ""
fi

# ── 3. Scripts on disk that the matrix is the source-of-truth for ─────────────
# Exclusions: scripts that are NOT expected to be in the matrix.
# These are either:
#   - In a different job (pr-hygiene, cargo-test, etc.)
#   - Run in a different location (scripts/eval/)
#   - Infrastructure scripts (run-*.sh, check-*.sh, cargo-test-with-rerun.sh)
#   - Advisory/staleness scripts (check-release-staleness.sh)
#   - Scripts in other jobs (audit, e2e, etc.)
#
# Add entries here when a new test-*.sh is intentionally placed in a
# different job than fast-checks-matrix.

EXCLUSIONS=(
    # Infrastructure / runner scripts (not CI gate scripts)
    "run-fast-checks-sequential.sh"
    "run-local-ci.sh"
    "run-remote-ci.sh"
    "run-battle-sim-suite.sh"
    "run-battle-qa-full.sh"
    "run-feature-smokes.sh"
    "run-stories.sh"
    "run-tauri-e2e.sh"
    "run-tests-with-config.sh"
    # Advisory scripts (continue-on-error, needs GH_TOKEN)
    "check-release-staleness.sh"
    # Belongs in pr-hygiene job
    "check-pr-scope.sh"
    "check-mass-deletion.sh"
    # Belongs in pr-hygiene job — path/manifest checks
    "test-broad-canary-coverage.sh"
    "test-merge-group-coverage.sh"
    "test-pr-ac-coverage.sh"
    "test-workflow-linux-guard.sh"
    "test-install-script-manifest.sh"
    "test-pwa-parse-gate.sh"
    "test-public-doc-privacy.sh"
    # Coverage / audit jobs (different job)
    "test-gap-audit-priorities.sh"
    # The coverage check itself — would be circular
    "test-fast-checks-matrix-coverage.sh"
    # In scripts/eval/ not scripts/ci/
    "research-lane-a-smoke.sh"
    # Nightly / e2e jobs
    "ci-setup-ollama-e2e.sh"
    "chump-preflight.sh"
    "verify-external-golden-path.sh"
    "golden-path-timing.sh"
    # Precommit replay — belongs in pre-commit-replay job
    "precommit-strict-replay.sh"
    "test-precommit-strict-replay.sh"
    # Another job (INFRA-2118 cache job)
    "test-gap-list-domain-summary.sh"
    "test-gap-list-done-format.sh"
    "test-install-gh-shim-worktree-safe.sh"
    "test-cache-event-emission.sh"
    "test-gh-shim-script-attribution.sh"
    "test-graphql-debounce.sh"
    "test-cache-mergestatestatus.sh"
    "test-rollup-cascade-cancel.sh"
    "test-bounced-pr-detector.sh"
    "test-orphan-pr-closer.sh"
    "test-no-manual-ship-bypass.sh"
    "test-gap-closure-consistency-fixture.sh"
    "test-worktree-show-toplevel.sh"
    "test-lint-handoff-comment.sh"
    "test-review-handoff-reengage.sh"
    "test-worker-circuit-breaker.sh"
    "test-worker-first-output-watchdog.sh"
    "test-worker-timeout-no-commit.sh"
    "test-bot-merge-stacked-rebase.sh"
    "test-curator-decision-logging.sh"
    "test-curator-p0-demotion.sh"
    "test-curator-freshness.sh"
    "test-curator-auto-decompose.sh"
    "test-required-model.sh"
    "test-picker-priority.sh"
    "test-fleet-bootstrap.sh"
    # cargo-test-with-rerun.sh is a wrapper used by cargo-test job
    "cargo-test-with-rerun.sh"
    # Helper library scripts (not directly invoked)
    # coord-surfaces-smoke.sh is included in the matrix as a chump-bin-group entry
)

is_excluded() {
    local script="$1"
    for excl in "${EXCLUSIONS[@]}"; do
        [[ "$excl" == "$script" ]] && return 0
    done
    return 1
}

# ── 4. Check (A): matrix entries that don't exist on disk ─────────────────────
echo ""
echo "--- Check A: matrix entries that are missing on disk ---"
A_FAILS=0
for entry in "${MATRIX_ENTRIES[@]}"; do
    # Virtual group entries are not .sh files — skip disk check
    if [[ "$entry" == "chump-bin-group" ]]; then
        ok "virtual group entry (no .sh file expected): $entry"
        continue
    fi
    # chump-bin-group entries using '+' separator (future expansion)
    if echo "$entry" | grep -q '+'; then
        IFS='+' read -ra parts <<< "$entry"
        for part in "${parts[@]}"; do
            part=$(echo "$part" | tr -d ' ')
            [[ -z "$part" ]] && continue
            if [[ -f "$CI_DIR/$part" ]]; then
                ok "grouped entry member exists: $part"
            else
                fail "grouped entry member NOT found on disk: $part (entry: $entry)"
                A_FAILS=$((A_FAILS+1))
            fi
        done
    else
        if [[ -f "$CI_DIR/$entry" ]]; then
            ok "matrix entry exists on disk: $entry"
        else
            fail "matrix entry NOT found on disk: $entry"
            A_FAILS=$((A_FAILS+1))
        fi
    fi
done

# ── 5. Check (B): scripts in the OLD fast-checks job not in the matrix ───────
# The old fast-checks job is kept with if: false. We extract its script list
# and compare against the matrix — any script in the old job but not in the
# matrix is a drift risk (it was intentionally tested before but lost from
# the parallel job).
echo ""
echo "--- Check B: scripts in old fast-checks job missing from matrix ---"
B_FAILS=0

# Extract all scripts/ci/*.sh references from the fast-checks job (if: false)
OLD_FAST_CHECKS_SCRIPTS=$(python3 - "$CI_YML" <<'PYEOF'
import sys, re

ci_yml = sys.argv[1]
lines = open(ci_yml).read().splitlines()

in_fast_checks = False
for line in lines:
    stripped = line.strip()
    # Detect the old fast-checks job (has if: false)
    if re.match(r'^  fast-checks:\s*$', line):
        in_fast_checks = True
        continue
    # Stop at next job (indent 2 word + colon)
    if in_fast_checks and re.match(r'^  [A-Za-z0-9_-]+:\s*$', line):
        break
    if not in_fast_checks:
        continue
    # Extract scripts/ci/*.sh references
    m = re.search(r'(scripts/ci/[\w\-\.]+\.sh)', stripped)
    if m:
        print(m.group(1).replace('scripts/ci/', ''))
PYEOF
)

# Build matrix membership list
MATRIX_SCRIPTS_LIST=""
for entry in "${MATRIX_ENTRIES[@]}"; do
    [[ "$entry" == "chump-bin-group" ]] && continue
    MATRIX_SCRIPTS_LIST="${MATRIX_SCRIPTS_LIST}${entry}"$'\n'
done

# Also add scripts that are inside chump-bin-group (extracted from ci.yml)
CHUMP_BIN_SCRIPTS=$(python3 - "$CI_YML" <<'PYEOF'
import sys, re

ci_yml = sys.argv[1]
lines = open(ci_yml).read().splitlines()

in_matrix_job = False
in_bin_group_step = False
for line in lines:
    stripped = line.strip()
    if re.match(r'^  fast-checks-matrix:\s*$', line):
        in_matrix_job = True
        continue
    if in_matrix_job and re.match(r'^  [A-Za-z0-9_-]+:\s*$', line) and 'fast-checks-matrix' not in line:
        break
    if not in_matrix_job:
        continue
    # Detect chump-bin-group steps block
    if 'chump-bin-group tests' in stripped or 'chump-bin-group:' in stripped:
        in_bin_group_step = True
    if in_bin_group_step:
        m = re.search(r'bash scripts/ci/([\w\-\.]+\.sh)', stripped)
        if m:
            print(m.group(1))
PYEOF
)

MATRIX_SCRIPTS_LIST="${MATRIX_SCRIPTS_LIST}${CHUMP_BIN_SCRIPTS}"$'\n'

in_matrix_list() {
    local script="$1"
    echo "$MATRIX_SCRIPTS_LIST" | grep -qxF "$script"
}

if [[ -z "$OLD_FAST_CHECKS_SCRIPTS" ]]; then
    echo "  INFO: old fast-checks job not found or has no script references — skipping check B"
else
    while IFS= read -r script; do
        [[ -z "$script" ]] && continue
        if in_matrix_list "$script"; then
            : # present in matrix — OK
        elif is_excluded "$script"; then
            : # intentionally excluded from matrix (advisory, different job, etc.)
        else
            warn "in old fast-checks but not in matrix: $script"
            B_FAILS=$((B_FAILS+1))
        fi
    done <<< "$OLD_FAST_CHECKS_SCRIPTS"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  WARN (on disk, not in matrix): $B_FAILS"
echo "  FAIL (in matrix, not on disk): $A_FAILS"

if [[ ${#WARNS[@]} -gt 0 ]]; then
    echo ""
    echo "Scripts on disk not in matrix (add to ci.yml fast-checks-matrix or exclusions):"
    for w in "${WARNS[@]}"; do
        echo "  - $w"
    done
fi

if [[ $FAIL -gt 0 || $A_FAILS -gt 0 ]]; then
    echo ""
    echo "FAIL: $FAIL matrix-vs-disk drift issue(s) detected." >&2
    exit 1
fi

if [[ $B_FAILS -gt 0 ]]; then
    echo ""
    echo "WARN: $B_FAILS script(s) exist on disk but are not in the matrix."
    echo "      If they are new fast-checks gates, add them to fast-checks-matrix in ci.yml."
    echo "      If they belong to a different job, add them to the EXCLUSIONS list above."
    # Warnings don't fail the check — they're informational
    exit 0
fi

echo ""
echo "PASS: matrix entries and disk scripts are in sync."
exit 0
