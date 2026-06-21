#!/usr/bin/env bash
# INFRA-471: test model-class-aware fleet routing.
#
# Verifies that:
#   1. haiku workers skip effort=m/l/xl gaps at pick time
#   2. sonnet workers skip effort=xs gaps at pick time
#   3. _resolve_model.py returns the correct model class per routing.yaml
#
# Exit 0 = all checks pass; exit 1 = any failure.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PICK_SCRIPT="$REPO_ROOT/scripts/dispatch/_pick_gap.py"
RESOLVE_SCRIPT="$REPO_ROOT/scripts/dispatch/_resolve_model.py"
PASS=0
FAIL=0

ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# ── Test fixture: fake gap JSON with various effort levels ─────────────────
GAP_JSON='[
  {"id":"TEST-001","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1},
  {"id":"TEST-002","domain":"INFRA","priority":"P1","effort":"s", "status":"open","created_at":2},
  {"id":"TEST-003","domain":"INFRA","priority":"P1","effort":"m", "status":"open","created_at":3},
  {"id":"TEST-004","domain":"INFRA","priority":"P1","effort":"l", "status":"open","created_at":4},
  {"id":"TEST-005","domain":"INFRA","priority":"P1","effort":"xl","status":"open","created_at":5}
]'

run_picker() {
    # Run _pick_gap.py with given FLEET_MODEL; prints picked gap ID or empty.
    local model="$1"
    local tmpfile
    tmpfile="$(mktemp -t routing-test.XXXXXX)"
    printf '%s' "$GAP_JSON" > "$tmpfile"
    result="$(GAP_JSON_FILE="$tmpfile" \
        FLEET_MODEL="$model" \
        FLEET_PRIORITY_FILTER="P0,P1" \
        FLEET_DOMAIN_FILTER="" \
        FLEET_EFFORT_FILTER="xs,s,m,l,xl" \
        EXCLUDE_RE="^$" \
        ACTIVE_GAPS="" \
        WORKER_INDEX="1" \
        COOLDOWN_DIR="" \
        python3 "$PICK_SCRIPT" 2>/dev/null || true)"
    rm -f "$tmpfile"
    printf '%s' "$result"
}

# ── 1. haiku refuses m/l/xl ─────────────────────────────────────────────────
# With haiku, only TEST-001 (xs) and TEST-002 (s) are eligible.
# Picker sorts by effort rank then created_at → should pick TEST-001 (xs, rank=0).
picked="$(run_picker haiku)"
if [[ "$picked" == "TEST-001" ]] || [[ "$picked" == "TEST-002" ]]; then
    ok "haiku picks xs/s (picked=$picked)"
else
    fail "haiku should pick xs/s but got: '$picked'"
fi

# Verify haiku does NOT pick m
GAP_JSON_M='[{"id":"TEST-M","domain":"INFRA","priority":"P1","effort":"m","status":"open","created_at":1}]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$GAP_JSON_M" > "$tmpf"
haiku_m="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=haiku FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ -z "$haiku_m" ]]; then
    ok "haiku refuses effort=m"
else
    fail "haiku should refuse effort=m but picked: '$haiku_m'"
fi

# Verify haiku does NOT pick l
GAP_JSON_L='[{"id":"TEST-L","domain":"INFRA","priority":"P1","effort":"l","status":"open","created_at":1}]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$GAP_JSON_L" > "$tmpf"
haiku_l="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=haiku FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ -z "$haiku_l" ]]; then
    ok "haiku refuses effort=l"
else
    fail "haiku should refuse effort=l but picked: '$haiku_l'"
fi

# ── 2. sonnet refuses xs ────────────────────────────────────────────────────
GAP_JSON_XS='[{"id":"TEST-XS","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1}]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$GAP_JSON_XS" > "$tmpf"
sonnet_xs="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=sonnet FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ -z "$sonnet_xs" ]]; then
    ok "sonnet refuses effort=xs"
else
    fail "sonnet should refuse effort=xs but picked: '$sonnet_xs'"
fi

# sonnet accepts m
GAP_JSON_SM='[{"id":"TEST-SM","domain":"INFRA","priority":"P1","effort":"m","status":"open","created_at":1}]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$GAP_JSON_SM" > "$tmpf"
sonnet_m="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=sonnet FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$sonnet_m" == "TEST-SM" ]]; then
    ok "sonnet picks effort=m"
else
    fail "sonnet should pick effort=m but got: '$sonnet_m'"
fi

# ── 3. _resolve_model.py: effort → model class ──────────────────────────────
resolve() {
    local gap_id="$1" effort="$2" domain="$3"
    local json="[{\"id\":\"${gap_id}\",\"domain\":\"${domain}\",\"effort\":\"${effort}\",\"status\":\"open\"}]"
    printf '%s' "$json" | \
        GAP_ID="$gap_id" REPO_ROOT="$REPO_ROOT" FLEET_MODEL="sonnet" \
        python3 "$RESOLVE_SCRIPT" 2>/dev/null || true
}

# RESILIENT-154 (#3146) flipped routing.yaml xs/s from haiku → sonnet ("remove
# haiku from the fleet — sonnet is the floor"): haiku stalled ~60% of cycles and
# saves $0 on a flat subscription. _resolve_model.py now returns sonnet for xs/s.
m_for_xs="$(resolve TEST-XS xs INFRA)"
if [[ "$m_for_xs" == "sonnet" ]]; then
    ok "resolve: effort=xs → sonnet (RESILIENT-154: no haiku)"
else
    fail "resolve: effort=xs should → sonnet, got: '$m_for_xs'"
fi

m_for_s="$(resolve TEST-S s INFRA)"
if [[ "$m_for_s" == "sonnet" ]]; then
    ok "resolve: effort=s → sonnet (RESILIENT-154: no haiku)"
else
    fail "resolve: effort=s should → sonnet, got: '$m_for_s'"
fi

m_for_m="$(resolve TEST-M m INFRA)"
if [[ "$m_for_m" == "sonnet" ]]; then
    ok "resolve: effort=m → sonnet"
else
    fail "resolve: effort=m should → sonnet, got: '$m_for_m'"
fi

m_for_l="$(resolve TEST-L l INFRA)"
if [[ "$m_for_l" == "sonnet" ]]; then
    ok "resolve: effort=l → sonnet"
else
    fail "resolve: effort=l should → sonnet, got: '$m_for_l'"
fi

# ── 4. task_class routing: COG-* → cognition → sonnet ──────────────────────
m_for_cog="$(resolve COG-042 m COG)"
if [[ "$m_for_cog" == "sonnet" ]]; then
    ok "resolve: COG-* task_class=cognition → sonnet"
else
    fail "resolve: COG-* should → sonnet (cognition route), got: '$m_for_cog'"
fi

# ── 5. mixed fleet simulation: pick from shared pool ───────────────────────
# Pool has xs, s, m, l. Haiku should pick xs or s; sonnet should pick m or l.
POOL='[
  {"id":"POOL-XS","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1},
  {"id":"POOL-S", "domain":"INFRA","priority":"P1","effort":"s", "status":"open","created_at":2},
  {"id":"POOL-M", "domain":"INFRA","priority":"P1","effort":"m", "status":"open","created_at":3},
  {"id":"POOL-L", "domain":"INFRA","priority":"P1","effort":"l", "status":"open","created_at":4}
]'
tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$POOL" > "$tmpf"
haiku_pool="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=haiku FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$haiku_pool" == "POOL-XS" ]] || [[ "$haiku_pool" == "POOL-S" ]]; then
    ok "mixed pool: haiku picks xs/s (got $haiku_pool)"
else
    fail "mixed pool: haiku should pick xs/s, got: '$haiku_pool'"
fi

tmpf="$(mktemp -t routing-test.XXXXXX)"
printf '%s' "$POOL" > "$tmpf"
sonnet_pool="$(GAP_JSON_FILE="$tmpf" FLEET_MODEL=sonnet FLEET_PRIORITY_FILTER="" \
    FLEET_DOMAIN_FILTER="" FLEET_EFFORT_FILTER="" EXCLUDE_RE="^$" \
    ACTIVE_GAPS="" WORKER_INDEX=1 COOLDOWN_DIR="" \
    python3 "$PICK_SCRIPT" 2>/dev/null || true)"
rm -f "$tmpf"
if [[ "$sonnet_pool" == "POOL-S" ]] || [[ "$sonnet_pool" == "POOL-M" ]] || [[ "$sonnet_pool" == "POOL-L" ]]; then
    ok "mixed pool: sonnet picks s/m/l (got $sonnet_pool)"
else
    fail "mixed pool: sonnet should pick s/m/l, got: '$sonnet_pool'"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
