#!/usr/bin/env bash
# test-flake-catalog-tracking.sh — INFRA-1866 CI guard + smoke test.
#
# Two-in-one:
#   (a) CI guard mode (default): runs against the REAL KNOWN_FLAKES.yaml in
#       this repo, fails if any entry lacks tracking_gap. Catches catalog
#       drift before it lands in main.
#   (b) Smoke test mode (--smoke): exercises audit-flake-catalog.sh with
#       synthetic fixture YAMLs to verify the audit logic.
#
# Usage:
#   test-flake-catalog-tracking.sh           # CI guard
#   test-flake-catalog-tracking.sh --smoke   # all-mode unit smoke

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/audit-flake-catalog.sh"
REAL_YAML="$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml"

MODE="${1:-guard}"

if [[ "$MODE" == "--smoke" || "$MODE" == "smoke" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    AMBIENT="$TMP/ambient.jsonl"
    touch "$AMBIENT"
    export CHUMP_AMBIENT_LOG="$AMBIENT"

    # ── Smoke 1: empty file → 0 entries → rc=0 ─────────────────────────────
    echo "Smoke 1: empty YAML → 0 entries"
    : > "$TMP/empty.yaml"
    out=$(CHUMP_KNOWN_FLAKES="$TMP/empty.yaml" "$SCRIPT" --json 2>&1) && rc=0 || rc=$?
    if echo "$out" | grep -q '"total_entries":0' && echo "$out" | grep -q '"orphan_count":0' && [[ "$rc" -eq 0 ]]; then
        echo "  PASS"
    else
        echo "  FAIL: rc=$rc out=$out"; exit 1
    fi

    # ── Smoke 2: all tracked → rc=0 ──────────────────────────────────────
    echo "Smoke 2: 2 entries all tracked → rc=0"
    cat > "$TMP/clean.yaml" <<EOF
flakes:
  - test: mod::tests::a
    tracking_gap: INFRA-100
    added: 2026-05-23
  - test: mod::tests::b
    tracking_gap: INFRA-101
    added: 2026-05-23
EOF
    out=$(CHUMP_KNOWN_FLAKES="$TMP/clean.yaml" "$SCRIPT" --json 2>&1) && rc=0 || rc=$?
    if echo "$out" | grep -q '"total_entries":2' && echo "$out" | grep -q '"orphan_count":0' && [[ "$rc" -eq 0 ]]; then
        echo "  PASS"
    else
        echo "  FAIL: rc=$rc out=$out"; exit 1
    fi

    # ── Smoke 3: 1 orphan → rc=1 + emit ───────────────────────────────────
    echo "Smoke 3: 1 orphan → rc=1 + ambient emit"
    cat > "$TMP/orphan.yaml" <<EOF
flakes:
  - test: mod::tests::tracked
    tracking_gap: INFRA-200
    added: 2026-05-23
  - test: mod::tests::orphan_one
    added: 2026-05-22
    last_observed: 2026-05-23
EOF
    > "$AMBIENT"
    out=$(CHUMP_KNOWN_FLAKES="$TMP/orphan.yaml" "$SCRIPT" 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "1 of 2 entries missing tracking_gap"; then
        echo "  PASS (rc=1 + summary message)"
    else
        echo "  FAIL: rc=$rc out=$out"; exit 1
    fi

    if grep -q '"kind":"flake_catalog_orphan"' "$AMBIENT" && grep -q '"test":"mod::tests::orphan_one"' "$AMBIENT"; then
        echo "  PASS (ambient emit)"
    else
        echo "  FAIL: ambient missing expected emit"
        cat "$AMBIENT"
        exit 1
    fi

    # ── Smoke 4: --dry-run skips emit ─────────────────────────────────────
    echo "Smoke 4: --dry-run skips emit"
    > "$AMBIENT"
    CHUMP_KNOWN_FLAKES="$TMP/orphan.yaml" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || true
    if [[ ! -s "$AMBIENT" ]]; then
        echo "  PASS"
    else
        echo "  FAIL: ambient written on --dry-run"
        cat "$AMBIENT"
        exit 1
    fi

    # ── Smoke 5: bypass env ──────────────────────────────────────────────
    echo "Smoke 5: CHUMP_AUDIT_FLAKE_CATALOG=0 bypasses"
    out=$(CHUMP_AUDIT_FLAKE_CATALOG=0 CHUMP_KNOWN_FLAKES="$TMP/orphan.yaml" "$SCRIPT" 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 0 && "$out" == *"bypassed"* ]]; then
        echo "  PASS"
    else
        echo "  FAIL: rc=$rc out=$out"; exit 1
    fi

    echo
    echo "All 5 audit-flake-catalog smoke tests passed."
    exit 0
fi

# ── CI guard mode ────────────────────────────────────────────────────────────
# Run the audit against the real catalog; fail the build if any orphan exists.
echo "[test-flake-catalog-tracking] running CI guard against $REAL_YAML"
if "$SCRIPT" --json > /tmp/flake-catalog-audit.json 2>&1; then
    total=$(python3 -c "import json; print(json.load(open('/tmp/flake-catalog-audit.json'))['total_entries'])")
    echo "  OK — $total entries, 0 orphans."
    exit 0
fi
# rc=1 → orphans present.
echo "[test-flake-catalog-tracking] FAIL — catalog has orphan entries" >&2
python3 -c "
import json
d = json.load(open('/tmp/flake-catalog-audit.json'))
print(f\"Orphans ({d['orphan_count']} of {d['total_entries']}):\", file=__import__('sys').stderr)
for o in d['orphans']:
    print(f\"  - {o['test']}  added={o['added']}  last_observed={o['last_observed']}\", file=__import__('sys').stderr)
print('', file=__import__('sys').stderr)
print('Every KNOWN_FLAKES.yaml entry must have a tracking_gap: INFRA-NNNN — see file preamble.', file=__import__('sys').stderr)
" >&2
exit 1
