#!/usr/bin/env bash
# test-index-almanac.sh — RESILIENT-404
#
# Proves scripts/ops/index-almanac.sh:
#   1. discovers every git checkout under the scan root and reindexes each
#      one via the (injectable) per-repo index command
#   2. writes the last-full-index marker + logs success on a clean sweep
#   3. one repo's index command failing doesn't abort the sweep — the rest
#      still get indexed, and the failure is counted + logged to ambient
#   4. fails loudly (non-zero exit) when the almanac binary is absent
#   5. fails loudly (non-zero exit) when zero fleet repos are discovered
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t index-almanac-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO_ROOT="$TMP/chump-repo"
mkdir -p "$REPO_ROOT/.chump-locks"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

ALMANAC_BIN="$TMP/bin/almanac"
mkdir -p "$(dirname "$ALMANAC_BIN")"
cat > "$ALMANAC_BIN" <<'EOF'
#!/bin/sh
echo "almanac 0.1.0 (test)"
EOF
chmod +x "$ALMANAC_BIN"

FLEET_ROOT="$TMP/Projects"
mkdir -p "$FLEET_ROOT"
make_repo() {  # make_repo <name>
    local d="$FLEET_ROOT/$1"
    git init --quiet "$d"
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    echo "v1" > "$d/f.txt"
    git -C "$d" add f.txt
    git -C "$d" commit --quiet -m "init"
}
make_repo alpha
make_repo bravo
make_repo charlie
mkdir -p "$FLEET_ROOT/not-a-repo"  # no .git — must be skipped

INDEX_DIR="$TMP/indexes"
MARKER="$TMP/fleet-index.last"
LOG="$TMP/fleet-index.log"

CALLS_LOG="$TMP/calls.log"

run_sweep() {
    CHUMP_REPO_ROOT="$REPO_ROOT" \
    ALMANAC_BIN="$ALMANAC_BIN" \
    ALMANAC_FLEET_ROOTS="$FLEET_ROOT" \
    ALMANAC_INDEX_DIR="$INDEX_DIR" \
    ALMANAC_INDEX_MARKER="$MARKER" \
    ALMANAC_INDEX_LOG="$LOG" \
    ALMANAC_INDEX_CMD="${1}" \
        bash scripts/ops/index-almanac.sh
}

# --- Case 1: clean sweep over 3 discovered repos ---------------------------
OK_CMD="echo indexed {name} >> '$CALLS_LOG'"
run_sweep "$OK_CMD"
CALLS="$(wc -l < "$CALLS_LOG")"
[ "$CALLS" -eq 3 ] || { echo "FAIL: case1 expected 3 index calls, got $CALLS"; exit 1; }
grep -q "indexed alpha" "$CALLS_LOG" || { echo "FAIL: case1 alpha not indexed"; exit 1; }
grep -q "indexed bravo" "$CALLS_LOG" || { echo "FAIL: case1 bravo not indexed"; exit 1; }
grep -q "indexed charlie" "$CALLS_LOG" || { echo "FAIL: case1 charlie not indexed"; exit 1; }
[ -f "$MARKER" ] || { echo "FAIL: case1 marker not written"; exit 1; }
grep -q "\"kind\":\"almanac_fleet_index_started\".*\"repo_count\":3" "$AMBIENT" || { echo "FAIL: case1 missing started emission with repo_count=3"; exit 1; }
grep -q "\"kind\":\"almanac_fleet_index_completed\".*\"ok_count\":3,\"fail_count\":0" "$AMBIENT" || { echo "FAIL: case1 missing completed emission with ok_count=3 fail_count=0"; exit 1; }
grep -q "sweep complete: 3/3 indexed OK" "$LOG" || { echo "FAIL: case1 run log missing success line"; exit 1; }
echo "OK case1: discovers 3 repos (skips non-git dir), indexes each, writes marker, logs success"

# --- Case 2: one repo's index command fails, sweep continues ---------------
rm -f "$CALLS_LOG" "$MARKER" "$AMBIENT"
FAIL_CMD="if [ '{name}' = 'bravo' ]; then exit 1; fi; echo indexed {name} >> '$CALLS_LOG'"
run_sweep "$FAIL_CMD"
CALLS2="$(wc -l < "$CALLS_LOG")"
[ "$CALLS2" -eq 2 ] || { echo "FAIL: case2 expected 2 successful index calls, got $CALLS2"; exit 1; }
grep -q "\"kind\":\"almanac_fleet_index_repo_failed\".*\"repo\":\"bravo\"" "$AMBIENT" || { echo "FAIL: case2 missing repo_failed emission for bravo"; exit 1; }
grep -q "\"kind\":\"almanac_fleet_index_completed\".*\"ok_count\":2,\"fail_count\":1" "$AMBIENT" || { echo "FAIL: case2 missing completed emission with ok_count=2 fail_count=1"; exit 1; }
[ -f "$MARKER" ] || { echo "FAIL: case2 marker should still be written on a partial sweep"; exit 1; }
echo "OK case2: one repo failing doesn't abort the sweep — rest indexed, failure counted"

# --- Case 3: almanac binary absent -> honest failure ------------------------
rm -f "$AMBIENT"
set +e
CHUMP_REPO_ROOT="$REPO_ROOT" \
ALMANAC_BIN="$TMP/does-not-exist" \
ALMANAC_FLEET_ROOTS="$FLEET_ROOT" \
    bash scripts/ops/index-almanac.sh
RC3=$?
set -e
[ "$RC3" -ne 0 ] || { echo "FAIL: case3 expected non-zero exit when almanac binary absent"; exit 1; }
grep -q "\"kind\":\"almanac_fleet_index_no_binary\"" "$AMBIENT" || { echo "FAIL: case3 missing almanac_fleet_index_no_binary emission"; exit 1; }
echo "OK case3: absent almanac binary fails loudly instead of silently no-op'ing"

# --- Case 4: zero repos discovered -> honest failure ------------------------
EMPTY_ROOT="$TMP/empty-projects"
mkdir -p "$EMPTY_ROOT"
set +e
CHUMP_REPO_ROOT="$REPO_ROOT" \
ALMANAC_BIN="$ALMANAC_BIN" \
ALMANAC_FLEET_ROOTS="$EMPTY_ROOT" \
    bash scripts/ops/index-almanac.sh
RC4=$?
set -e
[ "$RC4" -ne 0 ] || { echo "FAIL: case4 expected non-zero exit when zero repos discovered"; exit 1; }
echo "OK case4: zero discovered repos fails loudly"

echo "OK: index-almanac.sh discovers + reindexes fleet repos, survives per-repo failure, fails loudly on absent binary/empty fleet"
