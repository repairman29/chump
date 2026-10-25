#!/usr/bin/env bash
# test-resilient-1650-noncanonical-store-check.sh — RESILIENT-1650 (Phase R R4)
#
# Verifies:
#   AC1: runtime check (chump fleet doctor / chump health / fleet-doctor-strict)
#        lists every gap store it can find for the node (CHUMP_STATE_DB, repo
#        .chump/state.db, ~/.chump/state.db, scan) and reports each as
#        canonical, non-canonical (NONCANONICAL marker beside it) or UNMARKED.
#   AC2: an unmarked non-canonical store is a warning with its path; a marked
#        one is reported as expected.
#   AC3: nothing in the check or any organ syncs, restores or copies a marked
#        non-canonical store toward the canonical one (both runtime inspection
#        and `chump store reconcile` / `chump gap sync --push` refuse to copy
#        from a NONCANONICAL-marked store).
#   AC4: hermetic fixture with one canonical store, one marked copy and one
#        unmarked copy + mutant verification.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

echo "=== RESILIENT-1650 non-canonical gap-store runtime check ==="

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    for cand in \
        "$REPO_ROOT/target/release/chump" \
        "$REPO_ROOT/target/debug/chump" \
        "$HOME/.cargo/chump-shared-target/debug/chump" \
        "$HOME/.cargo/chump-shared-target/release/chump" \
        "$HOME/.cargo/bin/chump"; do
        if [[ -x "$cand" ]]; then
            CHUMP_BIN="$cand"
            break
        fi
    done
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  [build] cargo build --bin chump..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q
    CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/resilient-1650.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
CANON_REPO="$HOME_DIR/chump"
MARKED_DIR="$HOME_DIR/replica/.chump"
UNMARKED_DIR="$HOME_DIR/.chump"

mkdir -p "$CANON_REPO/.git" "$CANON_REPO/.chump" "$MARKED_DIR" "$UNMARKED_DIR"

CANON_DB="$CANON_REPO/.chump/state.db"
MARKED_DB="$MARKED_DIR/state.db"
UNMARKED_DB="$UNMARKED_DIR/state.db"

printf 'canonical-store-payload-v1\n' > "$CANON_DB"
printf 'marked-noncanonical-payload-v1\n' > "$MARKED_DB"
printf 'expected non-canonical replica for RESILIENT-1650 fixture\n' > "$MARKED_DIR/NONCANONICAL"
printf 'unmarked-second-store-payload-v1\n' > "$UNMARKED_DB"

# ── 1. Runtime check via chump fleet doctor --json & human output (AC1, AC2, AC4) ──
DOC_JSON="$(cd "$CANON_REPO" && HOME="$HOME_DIR" CHUMP_REPO="$CANON_REPO" CHUMP_HOME="$CANON_REPO" \
    "$CHUMP_BIN" fleet doctor --json 2>/dev/null || true)"

python3 - "$DOC_JSON" "$CANON_DB" "$MARKED_DB" "$UNMARKED_DB" <<'PY'
import json, sys
raw, canon_db, marked_db, unmarked_db = sys.argv[1:5]
data = json.loads(raw)
gs = data["gap_stores"]
stores = {s["path"]: s for s in gs["stores"]}
assert canon_db in stores, f"canonical store missing from {stores}"
assert marked_db in stores, f"marked store missing from {stores}"
assert unmarked_db in stores, f"unmarked store missing from {stores}"

assert stores[canon_db]["status"] == "canonical", stores[canon_db]
assert stores[canon_db]["expected"] is True, stores[canon_db]

assert stores[marked_db]["status"] == "non-canonical", stores[marked_db]
assert stores[marked_db]["expected"] is True, stores[marked_db]
assert "expected" in stores[marked_db]["summary"], stores[marked_db]

assert stores[unmarked_db]["status"] == "UNMARKED", stores[unmarked_db]
assert stores[unmarked_db]["expected"] is False, stores[unmarked_db]

warnings = gs["warnings"]
assert len(warnings) == 1 and unmarked_db in warnings[0], f"expected warning naming {unmarked_db}, got {warnings}"
PY
ok "AC1/AC2/AC4: chump fleet doctor --json classifies canonical, non-canonical (expected), and UNMARKED (with path warning)"

# Also verify CHUMP_STATE_DB override classification (AC1)
ENV_DB="$TMP/custom-env-store/state.db"
mkdir -p "$(dirname "$ENV_DB")"
printf 'env-store-payload\n' > "$ENV_DB"
DOC_ENV_JSON="$(cd "$CANON_REPO" && HOME="$HOME_DIR" CHUMP_STATE_DB="$ENV_DB" \
    "$CHUMP_BIN" fleet doctor --json 2>/dev/null || true)"
python3 - "$DOC_ENV_JSON" "$ENV_DB" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
env_db = sys.argv[2]
stores = {s["path"]: s for s in data["gap_stores"]["stores"]}
assert env_db in stores and stores[env_db]["status"] == "canonical" and stores[env_db]["origin"] == "CHUMP_STATE_DB", stores
PY
ok "AC1: CHUMP_STATE_DB store is discovered and reported with origin=CHUMP_STATE_DB"

# ── 2. Runtime check via chump health --json & text (AC1, AC2) ────────────────
HEALTH_JSON="$(cd "$CANON_REPO" && HOME="$HOME_DIR" CHUMP_REPO="$CANON_REPO" CHUMP_HOME="$CANON_REPO" \
    "$CHUMP_BIN" health --json 2>/dev/null || true)"
python3 - "$HEALTH_JSON" "$CANON_DB" "$MARKED_DB" "$UNMARKED_DB" <<'PY'
import json, sys
raw, canon_db, marked_db, unmarked_db = sys.argv[1:5]
data = json.loads(raw)
stores = {s["path"]: s for s in data["gap_stores"]}
assert stores[canon_db]["status"] == "canonical"
assert stores[marked_db]["status"] == "non-canonical" and stores[marked_db]["expected"] is True
assert stores[unmarked_db]["status"] == "UNMARKED" and stores[unmarked_db]["expected"] is False
sigs = [s for s in data["signals"] if s["name"] == "unmarked_gap_store"]
assert len(sigs) == 1 and unmarked_db in sigs[0]["detail"], f"expected unmarked_gap_store signal with path, got {sigs}"
PY
ok "AC1/AC2: chump health --json reports gap_stores and emits unmarked_gap_store warning signal with path"

# ── 3. fleet-doctor-strict.sh check_single_store (AC1, AC2, AC4 + mutant M1) ─
st_with_unmarked="$(FLEET_DOCTOR_SOURCED=1 HOME="$HOME_DIR" bash -c 'source "$0"; check_single_store; printf "%s|%s" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"' "$DOCTOR" 2>/dev/null)"
if [[ "${st_with_unmarked%%|*}" == "fail" ]] && [[ "$st_with_unmarked" == *"WARN:$UNMARKED_DB=UNMARKED"* ]] && [[ "$st_with_unmarked" == *"$MARKED_DB=non-canonical(expected)"* ]]; then
    ok "fleet-doctor-strict check_single_store flags UNMARKED store and reports NONCANONICAL store as expected"
else
    bad "fleet-doctor-strict check_single_store unexpected output with unmarked store: $st_with_unmarked"
fi

# Remove the unmarked store so only 1 canonical + 1 NONCANONICAL-marked copy remain.
rm -f "$UNMARKED_DB"
st_marked_only="$(FLEET_DOCTOR_SOURCED=1 HOME="$HOME_DIR" bash -c 'source "$0"; check_single_store; printf "%s|%s" "${STATUSES[-1]:-}" "${DETAILS[-1]:-}"' "$DOCTOR" 2>/dev/null)"
if [[ "${st_marked_only%%|*}" == "pass" ]] && [[ "$st_marked_only" == *"$MARKED_DB=non-canonical(expected)"* ]]; then
    ok "fleet-doctor-strict check_single_store PASSes with 1 canonical + 1 NONCANONICAL-marked copy"
else
    bad "fleet-doctor-strict check_single_store did NOT pass with 1 canonical + 1 marked copy: $st_marked_only"
fi

# Mutant M1: if check_single_store ignores NONCANONICAL marker, 1 canonical + 1 marked copy false-REDs.
MUT_DOC="$TMP/mutant-fleet-doctor-strict.sh"
sed 's/\[\[ -e "\$d\/NONCANONICAL" \]\]/false/' "$DOCTOR" > "$MUT_DOC"
chmod +x "$MUT_DOC"
st_mut1="$(FLEET_DOCTOR_SOURCED=1 HOME="$HOME_DIR" bash -c 'source "$0"; check_single_store; printf "%s" "${STATUSES[-1]:-}"' "$MUT_DOC" 2>/dev/null)"
if [[ "$st_mut1" == "fail" ]]; then
    ok "Mutant M1 KILLED: removing NONCANONICAL marker handling causes 1-canonical + 1-marked fixture to fail"
else
    bad "Mutant M1 SURVIVED: expected fail without NONCANONICAL handling, got $st_mut1"
fi

# ── 4. AC3: nothing syncs, restores, or copies a marked non-canonical store ──
if [[ "$(cat "$CANON_DB")" == "canonical-store-payload-v1" ]] && [[ "$(cat "$MARKED_DB")" == "marked-noncanonical-payload-v1" ]]; then
    ok "AC3: runtime checks left canonical and NONCANONICAL-marked stores byte-unchanged"
else
    bad "AC3: runtime checks mutated canonical or marked store bytes"
fi

# Verify `chump store reconcile --from <marked> --into <canonical>` and
# `chump gap sync --push --state-db <marked>` both refuse (exit non-zero) and
# leave the canonical store byte-unchanged.
rc_rec=0
rec_out="$("$CHUMP_BIN" store reconcile --from "$MARKED_DB" --into "$CANON_DB" --force-offline 2>&1)" || rc_rec=$?
if [[ "$rc_rec" -ne 0 ]] && [[ "$rec_out" == *"RESILIENT-1650"* ]] && [[ "$(cat "$CANON_DB")" == "canonical-store-payload-v1" ]]; then
    ok "AC3: chump store reconcile refuses --from a NONCANONICAL-marked store and leaves canonical store byte-unchanged"
else
    bad "AC3: chump store reconcile did not refuse NONCANONICAL store (rc=$rc_rec, out=$rec_out)"
fi

MARKED_SQLITE_DIR="$TMP/marked-sqlite/.chump"
mkdir -p "$MARKED_SQLITE_DIR" "$TMP/gaps-out"
MARKED_SQLITE_DB="$MARKED_SQLITE_DIR/state.db"
CHUMP_STATE_DB="$MARKED_SQLITE_DB" "$CHUMP_BIN" gap list --quiet >/dev/null 2>&1 || true
printf 'expected non-canonical sqlite replica\n' > "$MARKED_SQLITE_DIR/NONCANONICAL"
rc_sync=0
sync_out="$("$CHUMP_BIN" gap sync --push --state-db "$MARKED_SQLITE_DB" --gaps-dir "$TMP/gaps-out" 2>&1)" || rc_sync=$?
if [[ "$rc_sync" -ne 0 ]] && [[ "$sync_out" == *"RESILIENT-1650"* ]]; then
    ok "AC3: chump gap sync --push refuses a NONCANONICAL-marked store"
else
    bad "AC3: chump gap sync --push did not refuse NONCANONICAL store (rc=$rc_sync, out=$sync_out)"
fi

# Mutant M2: source guard — removing `has_noncanonical_marker` check from reconcile.rs must be caught.
check_reconcile_guard() {
    local target_file="$1"
    grep -q "has_noncanonical_marker(&opts.from)" "$target_file"
}
if check_reconcile_guard "$REPO_ROOT/crates/chump-gap-store/src/reconcile.rs"; then
    ok "AC3 source guard: reconcile.rs checks has_noncanonical_marker(&opts.from)"
else
    bad "AC3 source guard: reconcile.rs missing has_noncanonical_marker(&opts.from)"
fi
MUT_REC="$TMP/mutant-reconcile.rs"
grep -v "has_noncanonical_marker" "$REPO_ROOT/crates/chump-gap-store/src/reconcile.rs" > "$MUT_REC"
if ! check_reconcile_guard "$MUT_REC"; then
    ok "Mutant M2 KILLED: removing has_noncanonical_marker from reconcile.rs fails guard"
else
    bad "Mutant M2 SURVIVED: guard passed without has_noncanonical_marker"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
