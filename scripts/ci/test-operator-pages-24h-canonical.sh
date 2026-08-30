#!/usr/bin/env bash
# scripts/ci/test-operator-pages-24h-canonical.sh — INFRA-3848 (parent INFRA-3841)
#
# Proves the "reconcile 5/9" claim: scripts/ops/vital-signs.sh (sign
# human_intervention) and scripts/ops/faculty-collector.sh (faculty
# communicate) both report the IDENTICAL operator_pages_24h count when
# pointed at the same fixture ambient log, using the same kind-set
# {operator_page, operator_paged, pager_notified}. Self-contained + offline:
# a synthetic ambient.jsonl is populated with a known mix of page kinds (some
# inside the 24h window, some outside, some other kinds as a negative
# control) so no network call is needed.

set -uo pipefail   # NOT -e: we assert exit codes / values explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/operator-pages-24h.sh"
VITAL="$REPO_ROOT/scripts/ops/vital-signs.sh"
FACULTY="$REPO_ROOT/scripts/ops/faculty-collector.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$LIB" "$VITAL" "$FACULTY"; do
  [[ -f "$f" ]] || { printf 'FATAL: %s not found\n' "$f" >&2; exit 1; }
done

# ── fixture: mix of page kinds inside/outside the 24h window ─────────────────
DATA_ROOT="$TMP/data"
mkdir -p "$DATA_ROOT/.chump" "$DATA_ROOT/.chump-locks" "$DATA_ROOT/scripts/ops"
: > "$DATA_ROOT/scripts/ops/organ-manifest.txt"
NOW_EPOCH="$(date -u +%s)"
in_1h="$(date -u -d "@$((NOW_EPOCH - 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
out_3d="$(date -u -d "@$((NOW_EPOCH - 259200))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"

AMBIENT="$DATA_ROOT/.chump-locks/ambient.jsonl"
cat > "$AMBIENT" <<JSONL
{"ts":"$in_1h","kind":"operator_page","reason":"fixture 1"}
{"ts":"$in_1h","kind":"operator_paged","reason":"fixture 2"}
{"ts":"$in_1h","kind":"pager_notified","reason":"fixture 3"}
{"ts":"$out_3d","kind":"operator_page","reason":"fixture outside window"}
{"ts":"$in_1h","kind":"something_else","reason":"fixture non-page kind"}
JSONL

EXPECT=3

# ── 1. the shared lib directly ────────────────────────────────────────────────
echo "[test-operator-pages-24h-canonical] lib helper"
source "$LIB"
cutoff="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
lib_val="$(operator_pages_24h "$AMBIENT" "$cutoff")"
[[ "$lib_val" == "$EXPECT" ]] \
  && _ok "operator_pages_24h() == $EXPECT (got $lib_val)" \
  || _fail "operator_pages_24h() expected $EXPECT, got '$lib_val'"

# ── 2. vital-signs.sh --dry-run, sign human_intervention.value ───────────────
echo "[test-operator-pages-24h-canonical] vital-signs.sh"
vital_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_VITALS_OUT="$TMP/vitals-out.json" \
  CHUMP_AMBIENT_LOG="$AMBIENT" \
  CHUMP_GH_REPO="repairman29/chump" \
  bash "$VITAL" --dry-run 2>/dev/null)"
vital_val="$(printf '%s' "$vital_json" | jq -r '.signs[] | select(.key=="human_intervention") | .value')"
[[ "$vital_val" == "$EXPECT" ]] \
  && _ok "vital-signs human_intervention.value == $EXPECT (got $vital_val)" \
  || _fail "vital-signs human_intervention.value expected $EXPECT, got '$vital_val'"

# ── 3. faculty-collector.sh --dry-run, faculty communicate ───────────────────
echo "[test-operator-pages-24h-canonical] faculty-collector.sh"
faculty_json="$(CHUMP_REPO_ROOT="$DATA_ROOT" REPO_ROOT="$DATA_ROOT" \
  CHUMP_FACULTY_OUT="$TMP/faculty-out.json" \
  CHUMP_AMBIENT_LOG="$AMBIENT" \
  CHUMP_GH_REPO="repairman29/chump" \
  CHUMP_ALMANAC_REPO="$TMP/no-almanac" \
  CHUMP_ALMANAC_BIN="$TMP/no-almanac/target/release/almanac" \
  bash "$FACULTY" --dry-run 2>/dev/null)"
faculty_val="$(printf '%s' "$faculty_json" | jq -r '.faculties[] | select(.key=="communicate") | .value')"
[[ "$faculty_val" == "$EXPECT" ]] \
  && _ok "faculty-collector communicate.value == $EXPECT (got $faculty_val)" \
  || _fail "faculty-collector communicate.value expected $EXPECT, got '$faculty_val'"

# ── 4. both readers agree with each other (the actual reconcile assertion) ───
[[ "$vital_val" == "$faculty_val" ]] \
  && _ok "vital-signs and faculty-collector agree ($vital_val == $faculty_val)" \
  || _fail "DRIFT: vital-signs=$vital_val faculty-collector=$faculty_val"

echo
echo "[test-operator-pages-24h-canonical] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
