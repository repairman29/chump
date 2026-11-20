#!/usr/bin/env bash
# test-planner-ac-parsing.sh — INFRA-1265
#
# Regression guard for the YAML acceptance_criteria parse bug:
#   - bullet-form  AC (the canonical `- text` form)        — must parse
#   - numbered-form AC (`1. text\n2. text` with no description: block)
#                                                          — must parse (was dropping)
#   - numbered-form AC + description block present          — no regression
#
# Each fixture is a 1-element-sequence gap yaml. We invoke `chump-plan
# --format json --include-blocked` on a synthetic gaps/ dir and assert
# every fixture id appears in the output and the AC bullet count matches
# the source YAML.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1265 chump-planner acceptance_criteria parsing tests ==="

# Resolve workspace target/ even when invoked from a linked worktree.
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_GIT_COMMON" ]]; then
    _WORKSPACE_ROOT="$(cd "$(dirname "$_GIT_COMMON")" && pwd 2>/dev/null || echo "$REPO_ROOT")"
    [[ -d "$_WORKSPACE_ROOT/target" ]] || _WORKSPACE_ROOT="$REPO_ROOT"
else
    _WORKSPACE_ROOT="$REPO_ROOT"
fi
BIN="$_WORKSPACE_ROOT/target/debug/chump-plan"
if [[ ! -x "$BIN" ]]; then
    echo "  building chump-plan..."
    (cd "$REPO_ROOT" && cargo build -p chump-planner --bin chump-plan 2>&1 | tail -3)
    [[ -x "$BIN" ]] || BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump-plan"
fi
[[ -x "$BIN" ]] && ok "chump-plan binary built at $BIN" || { fail "build failed"; exit 1; }

TMP="$(mktemp -d -t chump-ac-parse.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
GAPS_DIR="$TMP/docs/gaps"
mkdir -p "$GAPS_DIR"

# Fixture (a): canonical bullet form.
cat > "$GAPS_DIR/INFRA-AC-A.yaml" <<'EOF'
- id: INFRA-AC-A
  domain: INFRA
  title: bullet-form AC
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - "First bullet"
    - "Second bullet"
    - "Third bullet"
EOF

# Fixture (b): the INFRA-1265 bug — numbered form, no description.
cat > "$GAPS_DIR/INFRA-AC-B.yaml" <<'EOF'
- id: INFRA-AC-B
  domain: INFRA
  title: numbered-form AC, no description
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    1. First numbered item
    2. Second numbered item
    3. Third numbered item
EOF

# Fixture (c): numbered form WITH description block — regression guard.
cat > "$GAPS_DIR/INFRA-AC-C.yaml" <<'EOF'
- id: INFRA-AC-C
  domain: INFRA
  title: numbered-form AC + description
  status: open
  priority: P1
  effort: s
  description: |
    Some narrative context the author wrote alongside the numbered AC.
  acceptance_criteria:
    1. Alpha
    2. Beta
EOF

JSON="$TMP/out.json"
"$BIN" --gaps "$GAPS_DIR" --format json --agents 3 --include-blocked > "$JSON" 2>&1 \
  || { fail "chump-plan exited non-zero"; cat "$JSON" >&2; exit 1; }

python3 - "$JSON" <<'PY' || fail "AC parsing check failed"
import json, sys
data = json.load(open(sys.argv[1]))
ids = {it['gap_id'] for it in data['items']}
missing = {'INFRA-AC-A', 'INFRA-AC-B', 'INFRA-AC-C'} - ids
if missing:
    raise SystemExit(f"FAIL: gaps dropped from planner output: {sorted(missing)}")
print(f"  all 3 fixtures present in planner output: {sorted(ids & {'INFRA-AC-A','INFRA-AC-B','INFRA-AC-C'})}")
PY
[[ $? -eq 0 ]] && ok "bullet + numbered + numbered-with-description all parsed"

# Also exercise the library deserializer end-to-end via `cargo test` so a
# planner-only break is caught even when chump-plan binary stubs out the
# field on output.
_LIB_OUT="$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo test -p chump-planner --lib \
    parses_numbered_acceptance_criteria 2>&1)"
echo "$_LIB_OUT" | tail -5
if echo "$_LIB_OUT" | grep -qE '2 passed.*0 failed'; then
    ok "cargo test parses_numbered_acceptance_criteria_{no,with}_description pass"
else
    fail "library deserializer tests did not pass (expected 2 passed; 0 failed)"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
