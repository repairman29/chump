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

if [[ ! -f "$MANIFEST" ]]; then
    fail "gate-manifest.yaml not found at $MANIFEST"
    exit 1
fi

read_manifest() {
    python3 -c "
import sys, yaml
data = yaml.safe_load(open('$MANIFEST'))
for g in data.get('gates', []):
    print(f\"{g['id']}|{g['check_script']}|{g.get('expected_exit_nonzero', True)}|{g.get('fixture_kind', '')}\")
"
}

list_gates() {
    printf '== Gates in manifest ==\n'
    read_manifest | awk -F'|' '{printf "  %s\n    script: %s\n    expected_nonzero: %s\n", $1, $2, $3}'
}

# ── Fixture preparers ──────────────────────────────────────────────────────

fixture_pr_title_vs_diff() {
    local tmp; tmp="$(mktemp -d -t gate-fixture-scope.XXXXXX)"
    cd "$tmp"
    git init -q
    git config user.email t@t.t
    git config user.name t
    mkdir -p docs/gaps src
    echo "- id: TEST-001" > docs/gaps/TEST-001.yaml
    echo "fn x() {}" > src/lib.rs
    git add . && git commit -q -m "chore(gaps): file TEST-001 + bonus src change"
    echo "$tmp"
}

fixture_scratch_commits_or_mass_delete() {
    local tmp; tmp="$(mktemp -d -t gate-fixture-scratch.XXXXXX)"
    cd "$tmp"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    mkdir -p src docs/gaps
    for i in $(seq 1 50); do echo "line $i" >> src/lib.rs; done
    echo "feature one" > docs/feature.md
    git add . && git commit -q -m "initial seed"
    git checkout -q -b scratch-disaster
    : > src/lib.rs
    git add . && git commit -q -m "first"
    rm docs/feature.md
    git add . && git commit -q -m "unrelated change"
    echo "$tmp"
}

fixture_state_db_with_ghost_closed_pr() {
    local tmp; tmp="$(mktemp -d -t gate-fixture-premature.XXXXXX)"
    mkdir -p "$tmp/.chump"
    sqlite3 "$tmp/.chump/state.db" <<'SQL'
CREATE TABLE gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, description TEXT,
    priority TEXT, effort TEXT, status TEXT, acceptance_criteria TEXT,
    depends_on TEXT, notes TEXT, source_doc TEXT,
    created_at INTEGER NOT NULL DEFAULT 0, closed_at INTEGER,
    opened_date TEXT NOT NULL DEFAULT '', closed_date TEXT NOT NULL DEFAULT '',
    closed_pr INTEGER, skills_required TEXT NOT NULL DEFAULT '',
    preferred_backend TEXT NOT NULL DEFAULT '', preferred_machine TEXT NOT NULL DEFAULT '',
    estimated_minutes TEXT NOT NULL DEFAULT '', required_model TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps(id, domain, title, status, priority, effort, closed_pr)
VALUES ('TEST-001', 'TEST', 't', 'done', 'P1', 's', 999999);
SQL
    cd "$tmp"
    git init -q && git config user.email t@t.t && git config user.name t
    git commit --allow-empty -q -m "init"
    echo "$tmp"
}

fixture_in_script_self_test() {
    echo "$REPO_ROOT"
}

fixture_cognition_src_change_without_prereg() {
    local tmp; tmp="$(mktemp -d -t gate-fixture-prereg.XXXXXX)"
    cd "$tmp"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    mkdir -p src docs/eval/preregistered
    echo "// reflection" > src/reflection_db.rs
    git add . && git commit -q -m "initial"
    git checkout -q -b cognition-feature
    echo "// added neuromod tuning" >> src/reflection_db.rs
    git add . && git commit -q -m "feat(COG-XXX): tune neuromod kappa"
    echo "$tmp"
}

prepare_fixture() {
    local kind="$1"
    case "$kind" in
        pr-title-vs-diff) fixture_pr_title_vs_diff ;;
        scratch-commits-or-mass-delete) fixture_scratch_commits_or_mass_delete ;;
        state.db-with-ghost-closed-pr) fixture_state_db_with_ghost_closed_pr ;;
        in-script-self-test) fixture_in_script_self_test ;;
        cognition-src-change-without-prereg) fixture_cognition_src_change_without_prereg ;;
        *) echo ""; return 1 ;;
    esac
}

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

while IFS='|' read -r gate_id check_script expected_nonzero fixture_kind; do
    if [[ -n "$target_gate" && "$gate_id" != "$target_gate" ]]; then
        continue
    fi
    total=$((total + 1))

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

    fixture_root="$(prepare_fixture "$fixture_kind" 2>/dev/null)" || true
    if [[ -z "$fixture_root" ]]; then
        skipped=$((skipped + 1))
        info "$gate_id — SKIP (no fixture preparer for kind='$fixture_kind')"
        continue
    fi
    [[ "$fixture_root" != "$REPO_ROOT" ]] && fixtures_to_clean+=("$fixture_root")

    pushd "$fixture_root" >/dev/null
    set +e
    bash "$REPO_ROOT/$check_script" >/dev/null 2>&1
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
printf '   total=%d  passed=%d  failed=%d  skipped=%d\n' "$total" "$passed" "$failed" "$skipped"

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
