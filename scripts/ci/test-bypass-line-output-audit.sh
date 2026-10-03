#!/usr/bin/env bash
# test-bypass-line-output-audit.sh — INFRA-4537 (INFRA-1861 slice)
#
# INFRA-5429 (scripts/ci/test-bypass-line-required.sh) audits gate SOURCE
# for a "How to bypass cleanly:" line via static grep. That proves the
# string exists SOMEWHERE in the script, but not that it is actually
# printed on the real failure path an agent would hit (dead branch, wrong
# fail() call, conditional that never fires). This script closes that gap
# by force-firing each FAIL-capable gate against its real violating
# fixture (scripts/ci/lib/gate-fixtures.sh) and scanning the ACTUAL stdout+
# stderr the check produces.
#
# AC (INFRA-4537):
#   1. CI job scans output of every required check that exits with FAIL
#   2. Job fails if the output does not contain a line starting with
#      "How to bypass cleanly:"
#   3. The job passes when all failing checks include the bypass line
#
# Exit: 0 = clean, 1 = one or more gates failed without a bypass line (or
# didn't fire at all, which would make the audit meaningless).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/gate-manifest.yaml"

# shellcheck source=lib/gate-emit.sh
source "$SCRIPT_DIR/lib/gate-emit.sh" 2>/dev/null || true
# shellcheck source=lib/gate-fixtures.sh
source "$SCRIPT_DIR/lib/gate-fixtures.sh"
gate_emit_start "INFRA-4537" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

BYPASS_PATTERN="How to bypass cleanly:"
VIOLATIONS=0

if [[ ! -f "$MANIFEST" ]]; then
    fail "gate-manifest.yaml not found at $MANIFEST"
    fail "How to bypass cleanly: this gate has no external bypass — restore scripts/ci/gate-manifest.yaml (CREDIBLE-050)"
    exit 1
fi

if ! command -v python3 &>/dev/null || ! python3 -c "import yaml" 2>/dev/null; then
    fail "python3 + pyyaml required to parse gate-manifest.yaml"
    fail "How to bypass cleanly: install pyyaml (pip install pyyaml) — this audit has no other bypass"
    exit 1
fi

read_fail_capable_gates() {
    python3 -c "
import yaml
data = yaml.safe_load(open('$MANIFEST'))
for g in data.get('gates', []):
    if g.get('expected_exit_nonzero', True) and not g.get('known_broken'):
        print(f\"{g['id']}|{g['check_script']}|{g.get('fixture_kind', '')}|{g.get('fixture_args', '')}\")
"
}

checked=0
while IFS='|' read -r gate_id check_script fixture_kind fixture_args; do
    [[ -z "$gate_id" ]] && continue

    script_path="$REPO_ROOT/$check_script"
    if [[ ! -f "$script_path" ]]; then
        fail "$gate_id: check_script $check_script not found on disk"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi

    if [[ "$fixture_kind" == "state.db-with-ghost-closed-pr" ]] && ! command -v sqlite3 &>/dev/null; then
        info "$gate_id — SKIP (sqlite3 not on PATH)"
        continue
    fi

    fixture_root="$(prepare_fixture "$fixture_kind" 2>/dev/null)" || true
    if [[ -z "$fixture_root" ]]; then
        info "$gate_id — SKIP (no fixture preparer for kind='$fixture_kind')"
        continue
    fi

    output_file="$(mktemp -t gate-output.XXXXXX)"
    pushd "$fixture_root" >/dev/null
    set +e
    if [[ -n "$fixture_args" ]]; then
        # shellcheck disable=SC2086
        bash "$script_path" $fixture_args >"$output_file" 2>&1
    else
        bash "$script_path" >"$output_file" 2>&1
    fi
    exit_code=$?
    set -e
    popd >/dev/null

    checked=$((checked + 1))

    if [[ "$exit_code" -eq 0 ]]; then
        fail "$gate_id ($check_script) did not exit FAIL on its violating fixture — cannot audit output it never produced. DEAD GATE?"
        VIOLATIONS=$((VIOLATIONS + 1))
    elif grep -qF "$BYPASS_PATTERN" "$output_file"; then
        pass "$gate_id ($check_script) FAIL output (exit=$exit_code) contains a '$BYPASS_PATTERN' line"
    else
        fail "$gate_id ($check_script) exited FAIL (exit=$exit_code) but its actual output has no '$BYPASS_PATTERN' line"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi

    rm -f "$output_file"
    [[ "$fixture_root" != "$REPO_ROOT" ]] && rm -rf "$fixture_root"
done < <(read_fail_capable_gates)

echo ""
if [[ "$checked" -eq 0 ]]; then
    fail "no FAIL-capable gates were audited — manifest or fixture wiring is broken"
    fail "How to bypass cleanly: this audit has no bypass — investigate scripts/ci/gate-manifest.yaml and scripts/ci/lib/gate-fixtures.sh"
    gate_emit_result "INFRA-4537" "fail" "no-gates-audited" "0 gates checked"
    exit 1
fi

if [[ "$VIOLATIONS" -eq 0 ]]; then
    echo "INFRA-4537: all $checked FAIL-capable gate(s) print a bypass line on their real failure output."
    gate_emit_result "INFRA-4537" "pass" "" ""
    exit 0
else
    fail "INFRA-4537: $VIOLATIONS of $checked FAIL-capable gate(s) failed the output audit."
    fail "How to bypass cleanly: add a line 'How to bypass cleanly: <instructions>' to the flagged script's actual FAIL path (see scripts/ci/check-pr-scope.sh for the pattern) and confirm it prints on the real failure, not just in source"
    gate_emit_result "INFRA-4537" "fail" "missing-bypass-line-in-output" "$VIOLATIONS of $checked gate(s) failed"
    exit 1
fi
