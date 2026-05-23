#!/usr/bin/env bash
# behavior_gap_set_pipe_escape.sh — INFRA-1799
#
# Verifies `chump gap set --acceptance-criteria` handles AC values that
# legitimately contain '|' characters. Today's parser splits unconditionally
# on '|' and produces malformed YAML when the value contains a literal pipe
# (Rust generics like Type1|Type2, recipient syntax <gap-id|session-id|all-opus>,
# regex alternation, etc.). On 2026-05-23 this cascaded through gaps-integrity
# CI on 5+ PRs and caused an 8-hour fleet wedge.
#
# This test covers:
#   1. Repeated --acceptance-criteria flags → each value is one bullet, no split,
#      and pipes inside any one value survive intact.
#   2. Legacy single-flag form "a|b|c" still works (back-compat) AND emits
#      kind=chump_gap_set_legacy_delim to ambient.jsonl.
#   3. The resulting per-file YAML parses cleanly via python yaml.safe_load.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Prefer release binary (bot-merge builds it); fall back to debug.
CHUMP="$REPO_ROOT/target/release/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    echo "FATAL: chump binary not built; run 'cargo build --bin chump' first"
    exit 2
fi

echo "=== INFRA-1799 chump gap set --acceptance-criteria pipe escape test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/docs/gaps" "$FAKE/.chump" "$FAKE/.chump-locks"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
git -C "$FAKE" commit --allow-empty -q -m seed

cd "$FAKE"

# ─── Test 1: repeated --acceptance-criteria flags preserve pipes ─────────
RESERVE_OUT=$(CHUMP_REPO="$FAKE" "$CHUMP" gap reserve --force --domain TEST --priority P2 --effort xs --title "INFRA-1799 multi-flag test $(date +%s)" 2>&1)
GAP_ID_A=$(echo "$RESERVE_OUT" | grep -oE 'TEST-[0-9]+' | head -1)
if [[ -z "$GAP_ID_A" ]]; then
    cd "$REPO_ROOT"
    echo "FATAL: chump gap reserve A did not produce a gap ID. Output: $RESERVE_OUT"
    exit 2
fi

PIPE_BULLET='recipient <gap-id|session-id|all-opus> resolves correctly'
PLAIN_BULLET='plain second bullet with no special characters'

CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID_A" \
    --acceptance-criteria "$PIPE_BULLET" \
    --acceptance-criteria "$PLAIN_BULLET" \
    >/dev/null 2>&1

YAML_A="$FAKE/docs/gaps/${GAP_ID_A}.yaml"
if [[ ! -f "$YAML_A" ]]; then
    fail "expected YAML at $YAML_A — gap reserve/set did not regenerate"
    cd "$REPO_ROOT"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# Confirm YAML parses cleanly
if python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$YAML_A" 2>/dev/null; then
    ok "repeated-flag YAML parses cleanly via yaml.safe_load"
else
    fail "repeated-flag YAML at $YAML_A does NOT parse — pipe-split bug still present"
    echo "    YAML content:"
    sed 's/^/      /' "$YAML_A"
fi

# Per-file YAMLs from `chump gap reserve` are list-of-one — peel off the
# outer list before reading fields.

# Confirm the pipe-containing bullet survived intact (no splitting on |)
if python3 - "$YAML_A" "$PIPE_BULLET" <<'PY'
import sys, yaml
yaml_path, expected = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(yaml_path))
if isinstance(doc, list):
    doc = doc[0] if doc else {}
acs = (doc or {}).get("acceptance_criteria") or []
found = any(expected in (ac if isinstance(ac, str) else "") for ac in acs)
sys.exit(0 if found else 1)
PY
then
    ok "pipe-containing AC bullet preserved intact (no mid-value split)"
else
    fail "AC bullet with literal '|' was split — parser still broken"
    echo "    Parsed ACs:"
    python3 - "$YAML_A" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
if isinstance(doc, list):
    doc = doc[0] if doc else {}
for ac in (doc or {}).get("acceptance_criteria") or []:
    print("      -", ac)
PY
fi

# Confirm we got exactly 2 bullets (not 4 from a split-on-pipe)
N_BULLETS=$(python3 - "$YAML_A" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
if isinstance(doc, list):
    doc = doc[0] if doc else {}
print(len((doc or {}).get("acceptance_criteria") or []))
PY
)
if [[ "$N_BULLETS" == "2" ]]; then
    ok "got exactly 2 AC bullets (one per --acceptance-criteria flag)"
else
    fail "expected 2 bullets, got $N_BULLETS"
fi

# ─── Test 2: legacy single-flag delimiter still works + emits ambient ────
RESERVE_OUT_B=$(CHUMP_REPO="$FAKE" "$CHUMP" gap reserve --force --domain TEST --priority P2 --effort xs --title "INFRA-1799 legacy delim test $(date +%s)" 2>&1)
GAP_ID_B=$(echo "$RESERVE_OUT_B" | grep -oE 'TEST-[0-9]+' | head -1)
if [[ -z "$GAP_ID_B" ]]; then
    cd "$REPO_ROOT"
    echo "FATAL: chump gap reserve B did not produce a gap ID."
    exit 2
fi

# Snapshot the ambient line count before the call.
AMBIENT_FILE="$FAKE/.chump-locks/ambient.jsonl"
BEFORE_LINES=$(wc -l <"$AMBIENT_FILE" 2>/dev/null || echo 0)
BEFORE_LINES=${BEFORE_LINES// /}

CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID_B" \
    --acceptance-criteria "alpha|beta|gamma" \
    >/dev/null 2>&1

YAML_B="$FAKE/docs/gaps/${GAP_ID_B}.yaml"
if python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$YAML_B" 2>/dev/null; then
    ok "legacy delimiter YAML parses cleanly"
else
    fail "legacy delimiter YAML at $YAML_B does NOT parse"
fi

# Should produce 3 bullets from "alpha|beta|gamma"
N_BULLETS_B=$(python3 - "$YAML_B" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
if isinstance(doc, list):
    doc = doc[0] if doc else {}
print(len((doc or {}).get("acceptance_criteria") or []))
PY
)
if [[ "$N_BULLETS_B" == "3" ]]; then
    ok "legacy delim form still splits into 3 bullets (backward compat)"
else
    fail "legacy split produced $N_BULLETS_B bullets, expected 3"
fi

# Ambient event must have been emitted
if [[ -f "$AMBIENT_FILE" ]] && grep -q '"event":"chump_gap_set_legacy_delim"' "$AMBIENT_FILE"; then
    ok "kind=chump_gap_set_legacy_delim emitted to ambient.jsonl"
else
    fail "ambient event chump_gap_set_legacy_delim NOT emitted"
    if [[ -f "$AMBIENT_FILE" ]]; then
        echo "    Recent ambient lines:"
        tail -5 "$AMBIENT_FILE" | sed 's/^/      /'
    else
        echo "    ambient.jsonl missing entirely"
    fi
fi

# ─── Test 3: single flag with no pipe → 1 bullet, no deprecation ─────────
RESERVE_OUT_C=$(CHUMP_REPO="$FAKE" "$CHUMP" gap reserve --force --domain TEST --priority P2 --effort xs --title "INFRA-1799 single nopipe test $(date +%s)" 2>&1)
GAP_ID_C=$(echo "$RESERVE_OUT_C" | grep -oE 'TEST-[0-9]+' | head -1)

# Count deprecation events before
DEP_BEFORE=$(grep -c '"event":"chump_gap_set_legacy_delim"' "$AMBIENT_FILE" 2>/dev/null || echo 0)
DEP_BEFORE=${DEP_BEFORE// /}

CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID_C" \
    --acceptance-criteria "single bullet no pipes here" \
    >/dev/null 2>&1

YAML_C="$FAKE/docs/gaps/${GAP_ID_C}.yaml"
N_BULLETS_C=$(python3 - "$YAML_C" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
if isinstance(doc, list):
    doc = doc[0] if doc else {}
print(len((doc or {}).get("acceptance_criteria") or []))
PY
)
if [[ "$N_BULLETS_C" == "1" ]]; then
    ok "single-flag no-pipe value becomes exactly 1 bullet"
else
    fail "single no-pipe value produced $N_BULLETS_C bullets, expected 1"
fi

DEP_AFTER=$(grep -c '"event":"chump_gap_set_legacy_delim"' "$AMBIENT_FILE" 2>/dev/null || echo 0)
DEP_AFTER=${DEP_AFTER// /}
if [[ "$DEP_BEFORE" == "$DEP_AFTER" ]]; then
    ok "no-pipe single flag does NOT emit deprecation event"
else
    fail "no-pipe single flag falsely emitted deprecation event ($DEP_BEFORE -> $DEP_AFTER)"
fi

cd "$REPO_ROOT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
