#!/usr/bin/env bash
# test-refresh-almanac-binary.sh — INFRA-3639
#
# Proves scripts/setup/refresh-almanac-binary.sh:
#   1. is a true no-op on a healthy binary + fresh index (no rebuild, no
#      reindex, verdict=healthy)
#   2. self-heals a VANISHED binary (the exact "tonight-blindness" incident
#      from the gap) — rebuild runs, `almanac --version` works again, and
#      the post-remediation `almanac_health` line shows recovery
#   3. self-heals an EMPTY index — reindex runs, index_rows goes from 0 to
#      >0, and the post-remediation line shows recovery
#   4. reports failure (non-zero exit) when the almanac repo isn't checked
#      out at all, instead of silently doing nothing
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d -t refresh-almanac-binary-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO_ROOT="$TMP/chump-repo"
mkdir -p "$REPO_ROOT/.chump-locks"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"

# --- fake sibling almanac repo (origin + clone, like a real ~/Projects/almanac) ---
ALMANAC_ORIGIN="$TMP/almanac-origin.git"
ALMANAC_REPO="$TMP/almanac"
git init --quiet --bare "$ALMANAC_ORIGIN"
git init --quiet "$ALMANAC_REPO"
git -C "$ALMANAC_REPO" config user.email "test@example.com"
git -C "$ALMANAC_REPO" config user.name "Test"
echo "v1" > "$ALMANAC_REPO/src.rs"
git -C "$ALMANAC_REPO" add src.rs
git -C "$ALMANAC_REPO" commit --quiet -m "v1"
git -C "$ALMANAC_REPO" branch -M main
git -C "$ALMANAC_REPO" remote add origin "$ALMANAC_ORIGIN"
git -C "$ALMANAC_REPO" push --quiet origin main

ALMANAC_BIN="$TMP/bin/almanac"
ALMANAC_BUILT_BIN="$TMP/built/almanac"
ALMANAC_INDEX_DB="$TMP/index/chump.db"
mkdir -p "$(dirname "$ALMANAC_BIN")" "$(dirname "$ALMANAC_BUILT_BIN")" "$(dirname "$ALMANAC_INDEX_DB")"

write_fake_binary() {  # write_fake_binary <path> <version-sha>
    cat > "$1" <<EOF
#!/bin/sh
echo "almanac 0.1.0 ($2 built test)"
EOF
    chmod +x "$1"
}

write_fresh_index() {
    sqlite3 "$ALMANAC_INDEX_DB" "CREATE TABLE files (path TEXT); INSERT INTO files VALUES ('a'),('b'),('c');"
}

REBUILD_LOG="$TMP/rebuild-calls.log"
BUILD_CMD="echo ran >> '$REBUILD_LOG'; mkdir -p '$(dirname "$ALMANAC_BUILT_BIN")'; printf '#!/bin/sh\necho \"almanac 0.1.0 (deadbeefcafe built test)\"\n' > '$ALMANAC_BUILT_BIN'; chmod +x '$ALMANAC_BUILT_BIN'"

REINDEX_LOG="$TMP/reindex-calls.log"
REINDEX_CMD="echo ran >> '$REINDEX_LOG'; sqlite3 '$ALMANAC_INDEX_DB' \"CREATE TABLE files (path TEXT); INSERT INTO files VALUES ('a'),('b');\""

run_refresh() {
    CHUMP_REPO_ROOT="$REPO_ROOT" \
    ALMANAC_REPO="$ALMANAC_REPO" \
    ALMANAC_BIN="$ALMANAC_BIN" \
    ALMANAC_BUILT_BIN="$ALMANAC_BUILT_BIN" \
    ALMANAC_INDEX_DB="$ALMANAC_INDEX_DB" \
    ALMANAC_STALE_S=172800 \
    ALMANAC_BUILD_CMD="$BUILD_CMD" \
    ALMANAC_REINDEX_CMD="$REINDEX_CMD" \
        bash scripts/setup/refresh-almanac-binary.sh
}

last_health_field() {  # last_health_field <phase> <field>
    tail -20 "$AMBIENT" | grep "\"kind\":\"almanac_health\"" | grep "\"phase\":\"$1\"" | tail -1 \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['$2'])"
}

# --- Case 1: healthy binary + fresh index -> true no-op -------------------
write_fake_binary "$ALMANAC_BIN" "abc123def456"
write_fresh_index
run_refresh
VERDICT1="$(last_health_field pre verdict)"
[ "$VERDICT1" = "healthy" ] || { echo "FAIL: case1 expected verdict=healthy, got $VERDICT1"; exit 1; }
[ -f "$REBUILD_LOG" ] && { echo "FAIL: case1 must not rebuild a healthy binary"; exit 1; }
[ -f "$REINDEX_LOG" ] && { echo "FAIL: case1 must not reindex a fresh index"; exit 1; }
echo "OK case1: healthy binary + fresh index is a true no-op"

# --- Case 2: binary VANISHES (the exact tonight-blindness incident) -------
rm -f "$ALMANAC_BIN"
set +e
run_refresh
RC2=$?
set -e
[ "$RC2" -eq 0 ] || { echo "FAIL: case2 expected exit 0 after successful self-heal, got $RC2"; exit 1; }
PRE_VERDICT2="$(last_health_field pre verdict)"
[ "$PRE_VERDICT2" = "binary_missing" ] || { echo "FAIL: case2 expected pre verdict=binary_missing, got $PRE_VERDICT2"; exit 1; }
POST_VERDICT2="$(last_health_field post verdict)"
[ "$POST_VERDICT2" = "healthy" ] || { echo "FAIL: case2 expected post verdict=healthy (recovered), got $POST_VERDICT2"; exit 1; }
[ -x "$ALMANAC_BIN" ] || { echo "FAIL: case2 binary not reinstalled at $ALMANAC_BIN"; exit 1; }
OUT="$("$ALMANAC_BIN" --version)"
echo "$OUT" | grep -q deadbeefcafe || { echo "FAIL: case2 reinstalled binary is not the freshly-built one: $OUT"; exit 1; }
grep -q "almanac_binary_refreshed" "$AMBIENT" || { echo "FAIL: case2 missing almanac_binary_refreshed emission"; exit 1; }
CALLS2=$(wc -l < "$REBUILD_LOG")
[ "$CALLS2" -eq 1 ] || { echo "FAIL: case2 expected exactly 1 rebuild call, got $CALLS2"; exit 1; }
echo "OK case2: vanished binary self-heals — rebuild + almanac --version works + recovery line emitted"

# --- Case 3: EMPTY index (binary healthy) ----------------------------------
rm -f "$ALMANAC_INDEX_DB"
set +e
run_refresh
RC3=$?
set -e
[ "$RC3" -eq 0 ] || { echo "FAIL: case3 expected exit 0 after successful self-heal, got $RC3"; exit 1; }
PRE_VERDICT3="$(last_health_field pre verdict)"
[ "$PRE_VERDICT3" = "index_empty" ] || { echo "FAIL: case3 expected pre verdict=index_empty, got $PRE_VERDICT3"; exit 1; }
POST_VERDICT3="$(last_health_field post verdict)"
[ "$POST_VERDICT3" = "healthy" ] || { echo "FAIL: case3 expected post verdict=healthy (recovered), got $POST_VERDICT3"; exit 1; }
[ -f "$ALMANAC_INDEX_DB" ] || { echo "FAIL: case3 index db not recreated"; exit 1; }
ROWS3="$(sqlite3 "$ALMANAC_INDEX_DB" "SELECT COUNT(*) FROM files;")"
[ "$ROWS3" -gt 0 ] || { echo "FAIL: case3 reindexed db has 0 rows"; exit 1; }
grep -q "almanac_reindex_triggered" "$AMBIENT" || { echo "FAIL: case3 missing almanac_reindex_triggered emission"; exit 1; }
echo "OK case3: empty index self-heals — reindex runs and recovery line emitted"

# --- Case 4: almanac repo not checked out at all -> honest failure --------
rm -f "$ALMANAC_BIN"
set +e
CHUMP_REPO_ROOT="$REPO_ROOT" \
ALMANAC_REPO="$TMP/does-not-exist" \
ALMANAC_BIN="$ALMANAC_BIN" \
    bash scripts/setup/refresh-almanac-binary.sh
RC4=$?
set -e
[ "$RC4" -ne 0 ] || { echo "FAIL: case4 expected non-zero exit when almanac repo absent"; exit 1; }
grep -q "\"reason\":\"almanac_repo_absent\"" "$AMBIENT" || { echo "FAIL: case4 missing almanac_repo_absent emission"; exit 1; }
echo "OK case4: absent almanac repo fails loudly instead of silently no-op'ing"

echo "OK: refresh-almanac-binary.sh self-heals vanished binary + empty index, no-ops when healthy, fails loudly when unrecoverable"
