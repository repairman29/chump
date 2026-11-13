#!/usr/bin/env bash
# test-registry-snapshot.sh — RESILIENT-1902. Hermetic: snapshot -> refs/stash/registry/<date>
# on a bare "origin", restore rebuilds the registry (row count matches), fleet-doctor
# check goes RED on a backdated snapshot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SNAP="$ROOT/scripts/ops/registry-snapshot.sh"
DOCTOR="$ROOT/scripts/coord/fleet-doctor-strict.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 missing"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git init -q "$T/repo"; git -C "$T/repo" remote add origin "$T/origin.git"
mkdir -p "$T/repo/.chump"
sqlite3 "$T/repo/.chump/state.db" "CREATE TABLE gaps(id TEXT); INSERT INTO gaps VALUES ('A-1'),('A-2'),('A-3');"

# Hermetic: never inherit the operator's real registry path.
export CHUMP_STATE_DB="$T/repo/.chump/state.db"
export CHUMP_REPO_ROOT="$T/repo" CHUMP_SNAPSHOT_DIR="$T/snaps" HOME="$T/home"
bash "$SNAP" snapshot >/dev/null
D="$(date -u +%Y-%m-%d)"
[[ -f "$T/snaps/state-$D.db" ]] || fail "local snapshot missing"
git -C "$T/origin.git" rev-parse -q --verify "refs/stash/registry/$D" >/dev/null || fail "ref not pushed to origin"

# restore from the origin ref into a fresh hub
T2="$T/hub"; mkdir -p "$T2"; git init -q "$T2"; git -C "$T2" remote add origin "$T/origin.git"
CHUMP_REPO_ROOT="$T2" CHUMP_STATE_DB="$T2/.chump/state.db" bash "$SNAP" restore "refs/stash/registry/$D" >/dev/null
[[ "$(sqlite3 "$T2/.chump/state.db" 'SELECT count(*) FROM gaps')" == "3" ]] || fail "restored row count mismatch"
# restore from a plain file too
CHUMP_STATE_DB="$T/other.db" bash "$SNAP" restore "$T/snaps/state-$D.db" >/dev/null
[[ "$(sqlite3 "$T/other.db" 'SELECT count(*) FROM gaps')" == "3" ]] || fail "file restore mismatch"

# restore must refuse to clobber a populated registry
if CHUMP_STATE_DB="$T/other.db" bash "$SNAP" restore "$T/snaps/state-$D.db" >/dev/null 2>&1; then
    fail "restore overwrote a populated registry without FORCE"
fi

# doctor: fresh = pass, backdated 40h = fail
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"
check_registry_snapshot_fresh
[[ "${STATUSES[-1]}" == "pass" ]] || fail "fresh snapshot should pass: ${DETAILS[-1]}"
touch -d '40 hours ago' "$T/snaps/state-$D.db"
check_registry_snapshot_fresh
[[ "${STATUSES[-1]}" == "fail" ]] || fail "40h-old snapshot should be RED"
echo "PASS: test-registry-snapshot"
