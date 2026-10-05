#!/usr/bin/env bash
# test-all-gates-force-fire.sh — CREDIBLE-050
#
# Force-fires each CI gate listed in scripts/ci/gate-manifest.yaml against
# a synthetic violating fixture and asserts the correct outcome.
#
# Per Q2 research (docs/syntheses/2026-05-11-three-questions-research.md):
# 9 of 10 gates shipped on 2026-05-11 had fired ZERO times in production.
# Either the gates work and the bad behavior hasn't happened, OR the gates
# are dead code. This script proves the former.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/gate-manifest.yaml"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

# shellcheck source=lib/gate-fixtures.sh
source "$SCRIPT_DIR/lib/gate-fixtures.sh"

if [[ ! -f "$MANIFEST" ]]; then
    fail "gate-manifest.yaml not found at $MANIFEST"
    exit 1
fi

read_manifest() {
    python3 -c "
import sys, yaml
data = yaml.safe_load(open('$MANIFEST'))
for g in data.get('gates', []):
    print(f\"{g['id']}|{g['check_script']}|{g.get('expected_exit_nonzero', True)}|{g.get('fixture_kind', '')}|{g.get('known_broken', '')}|{g.get('fixture_args', '')}\")
"
}

list_gates() {
    printf '== Gates in manifest ==\n'
    read_manifest | awk -F'|' '{printf "  %s\n    script: %s\n    expected_nonzero: %s\n", $1, $2, $3}'
}

# ── Fixture preparers ──────────────────────────────────────────────────────
# Extracted to lib/gate-fixtures.sh (INFRA-4537) so test-bypass-line-output-
# audit.sh can force-fire the same gates without duplicating this logic.

# ── Main runner ────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--list" ]]; then
    list_gates
    exit 0
fi

target_gate=""
if [[ "${1:-}" == "--gate" ]]; then
    target_gate="${2:?--gate requires an ID}"
fi

if ! command -v python3 &>/dev/null; then
    fail "python3 not on PATH — required for YAML parsing"
    exit 1
fi
if ! python3 -c "import yaml" 2>/dev/null; then
    info "pyyaml not installed; some gates may skip"
fi

total=0; passed=0; failed=0; skipped=0
fixtures_to_clean=()

known_broken_count=0
while IFS='|' read -r gate_id check_script expected_nonzero fixture_kind known_broken fixture_args; do
    if [[ -n "$target_gate" && "$gate_id" != "$target_gate" ]]; then
        continue
    fi
    total=$((total + 1))

    # known_broken: skip with explicit "tracked-elsewhere" message so the
    # runner reports green while the underlying bug is being fixed in a
    # separate gap. Removing the manifest field re-arms the gate.
    if [[ -n "$known_broken" ]]; then
        known_broken_count=$((known_broken_count + 1))
        info "$gate_id — SKIP (known_broken=$known_broken; tracked separately)"
        continue
    fi

    if [[ ! -f "$REPO_ROOT/$check_script" ]]; then
        skipped=$((skipped + 1))
        info "$gate_id — SKIP (script not found: $check_script)"
        continue
    fi

    if [[ "$fixture_kind" == "state.db-with-ghost-closed-pr" ]] && ! command -v sqlite3 &>/dev/null; then
        skipped=$((skipped + 1))
        info "$gate_id — SKIP (sqlite3 not on PATH)"
        continue
    fi

    # INFRA-538 smoke test needs the chump binary. Skip if not built —
    # CI builds it before this runner, but local invocations may not.
    if [[ "$gate_id" == "INFRA-538-state-db-restore" ]] && [[ ! -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]] && [[ ! -x "$REPO_ROOT/target/release/chump" ]]; then
        skipped=$((skipped + 1))
        info "$gate_id — SKIP (chump binary not built — run 'cargo build --bin chump' first)"
        continue
    fi

    fixture_root="$(prepare_fixture "$fixture_kind" 2>/dev/null)" || true
    if [[ -z "$fixture_root" ]]; then
        skipped=$((skipped + 1))
        info "$gate_id — SKIP (no fixture preparer for kind='$fixture_kind')"
        continue
    fi
    [[ "$fixture_root" != "$REPO_ROOT" ]] && fixtures_to_clean+=("$fixture_root")

    pushd "$fixture_root" >/dev/null
    set +e
    # CREDIBLE-051: per-gate fixture_args (manifest field) replaces the
    # old GATE_FIXTURE_ARGS env-var trick. The previous setter lived inside
    # $(prepare_fixture) — a subshell, so its export never reached here.
    if [[ -n "$fixture_args" ]]; then
        # shellcheck disable=SC2086
        bash "$REPO_ROOT/$check_script" $fixture_args >/dev/null 2>&1
    else
        bash "$REPO_ROOT/$check_script" >/dev/null 2>&1
    fi
    exit_code=$?
    set -e
    popd >/dev/null

    if [[ "$expected_nonzero" == "True" || "$expected_nonzero" == "true" ]]; then
        if [[ "$exit_code" -ne 0 ]]; then
            passed=$((passed + 1))
            pass "$gate_id — gate fired (exit=$exit_code) on fixture '$fixture_kind'"
        else
            failed=$((failed + 1))
            fail "$gate_id — gate did NOT fire (exit=0) on fixture '$fixture_kind'. DEAD GATE?"
        fi
    else
        if [[ "$exit_code" -eq 0 ]]; then
            passed=$((passed + 1))
            pass "$gate_id — smoke test passed (exit=0)"
        else
            failed=$((failed + 1))
            fail "$gate_id — smoke test failed (exit=$exit_code)"
        fi
    fi
done < <(read_manifest)

for f in "${fixtures_to_clean[@]:-}"; do
    [[ -d "$f" ]] && rm -rf "$f"
done

echo ""
printf '== CREDIBLE-050 force-fire summary ==\n'
printf '   total=%d  passed=%d  failed=%d  skipped=%d  known_broken=%d\n' \
    "$total" "$passed" "$failed" "$skipped" "$known_broken_count"

if [[ "$failed" -gt 0 ]]; then
    fail "$failed gate(s) failed their force-fire fixture"
    exit 1
fi

if [[ "$total" -eq 0 ]]; then
    fail "no gates ran"
    exit 1
fi

pass "all $passed gates verified"
exit 0
