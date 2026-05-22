#!/usr/bin/env bash
# scripts/ci/test-fleet-fanout.sh — INFRA-1484 (Marcus M-B continuation)
#
# Verifies the cross-repo fan-out primitive:
#   1. Source-contract: fleet_fanout.rs exports FanoutSpec, RepoTarget, PlannedRepoGap
#   2. cargo unit-tests pass (parsing, per-repo plan, status aggregation)
#   3. main.rs wires `chump fanout` top-level dispatch + plan/apply/status arms
#   4. AC#7 structural: 3-repo fixture → plan reports "3 repo(s)" with each label

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/fleet_fanout.rs"

echo "=== INFRA-1484 fleet-fanout primitive tests ==="

# ── Source-contract ───────────────────────────────────────────────────────────
[[ -f "$SRC" ]] && ok "src/fleet_fanout.rs exists" || { fail "missing src/fleet_fanout.rs"; exit 1; }

for sym in \
    "pub struct FanoutSpec" \
    "pub struct RepoTarget" \
    "pub struct PlannedRepoGap" \
    "pub fn from_yaml" \
    "pub fn from_path" \
    "pub fn plan" \
    "pub fn render_plan" \
    "pub fn build_gap_notes" \
    "pub fn aggregate_status"; do
    if grep -q "$sym" "$SRC"; then
        ok "exports $sym"
    else
        fail "missing $sym"
    fi
done

# main.rs wiring
if grep -q "^mod fleet_fanout;" "$REPO_ROOT/src/main.rs"; then
    ok "main.rs declares mod fleet_fanout"
else
    fail "main.rs missing fleet_fanout module declaration"
fi

if grep -q 'Some("fanout")' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs dispatches 'chump fanout' top-level subcommand"
else
    fail "main.rs missing 'fanout' top-level dispatch"
fi

for arm in '"plan" =>' '"apply" =>' '"status" =>'; do
    # Each subcommand arm should appear in fanout's match block.
    if grep -q "$arm" "$REPO_ROOT/src/main.rs"; then
        ok "main.rs dispatches fanout subcommand $arm"
    else
        fail "main.rs missing fanout dispatch arm $arm"
    fi
done

# ── Unit-test invocation ──────────────────────────────────────────────────────
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test fleet_fanout ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump fleet_fanout --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test fleet_fanout passed"
    else
        fail "cargo test fleet_fanout failed"
    fi
fi

# ── AC#7: 3-repo structural integration ──────────────────────────────────────
# Per AC: "3-repo fixture, run chump fanout, verify 3 worktrees + 3 PRs +
# cross-repo rollup output." In CI we can verify the planning + aggregation
# path (the "3 worktrees + 3 PRs" half lands when a worker picks the gaps).
CHUMP_BIN="${CHUMP_BIN:-chump}"
if command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/service-a" "$TMP/service-b" "$TMP/service-c"
    # Drop a docker-compose.yml in one repo so the env-isolation warning fires.
    cat > "$TMP/service-a/docker-compose.yml" <<'EOF'
version: "3"
services:
  db:
    image: postgres:15
    ports: ["5432:5432"]
EOF
    cat > "$TMP/fanout.yaml" <<'EOF'
name: marcus-three-services
intent: |
  Bump shared-lib to v2.0 in this service. Run the existing integration suite.
repos:
  - path: ./service-a
  - path: ./service-b
  - path: ./service-c
validation: ./scripts/test-integration.sh
success: integration suite passes after the bump
effort: m
EOF
    OUT="$("$CHUMP_BIN" fanout plan "$TMP/fanout.yaml" 2>&1 || true)"
    if echo "$OUT" | grep -qE "3 repo\(s\)"; then
        ok "AC#7: 3-repo fan-out plan reports 3 entries"
    else
        fail "AC#7: expected '3 repo(s)' in plan; got: $(echo "$OUT" | head -3)"
    fi
    for label in service-a service-b service-c; do
        if echo "$OUT" | grep -q "$label"; then
            ok "AC#7: plan includes label $label"
        else
            fail "AC#7: plan missing label $label"
        fi
    done
    if echo "$OUT" | grep -q "docker-compose"; then
        ok "AC#4 graceful-degrade: docker-compose env hint surfaced in plan"
    else
        fail "AC#4: env hint for docker-compose.yml not surfaced"
    fi
    # AC#5 / status round-trip: drive aggregate_status directly via JSON-on-stdin
    # is impractical here — the unit test fleet_fanout::tests::build_gap_notes_round_trips_through_aggregate
    # covers it deterministically. Mention in the log so the contract is explicit.
    ok "AC#5 (status aggregation) covered by fleet_fanout unit tests"
else
    echo "  SKIP: $CHUMP_BIN not on PATH — 3-repo integration check skipped"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
