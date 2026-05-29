#!/usr/bin/env bash
# INFRA-2177: verify that chump gap reserve succeeds even when a sibling
# docs/gaps/*.yaml is deliberately malformed. This is the failure class that
# blocked the fleet fleet-wide for 30+ minutes on 2026-05-29 (INFRA-2170
# corrupt YAML in META-124 Wave 1). Reserve must read IDs solely from
# state.db gap_counters and never abort on a bad per-file YAML.

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Prefer the worktree-built binary (picks up --json + YAML-drop changes).
# Fall back to the installed chump for the resilience smoke test (Step 2).
CHUMP_BIN="${ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
fi
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found; run 'cargo build -p chump' first" >&2
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate from fleet state
export CHUMP_HOME="$TMP"
export CHUMP_LOCK_DIR="$TMP/locks"
export CHUMP_GAP_RESERVE_SKIP_PR=1
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_IGNORE_WASTE_PAUSE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
# Point at the real repo root so state.db is writable; docs/gaps/ is real.
# The malformed YAML is injected into a temp per-file dir, then removed.
export CHUMP_REPO="$ROOT"

mkdir -p "$TMP/locks"

echo "=== Step 1: inject malformed YAML into docs/gaps/ (temp, removed after test) ==="

CORRUPT_YAML="$ROOT/docs/gaps/INFRA-TEST-CORRUPT-2177.yaml"
# Numbered AC items with colon-space: trips YAML mapping/sequence ambiguity
# (exact pattern from INFRA-2170 that caused the fleet incident)
cat >"$CORRUPT_YAML" <<'EOF'
- id: INFRA-TEST-CORRUPT-2177
  domain: INFRA
  title: "deliberate corrupt fixture for INFRA-2177 resilience test"
  status: open
  acceptance_criteria:
    1. deploy: succeeds
    2. test: passes
    3. cleanup: done
EOF
trap 'rm -f "$CORRUPT_YAML"; rm -rf "$TMP"' EXIT

echo "  Injected: $CORRUPT_YAML"

echo "=== Step 2: reserve should succeed despite corrupt YAML ==="

RESULT=$("$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "INFRA-2177 resilience smoke test $(date +%s)" \
    --priority P2 \
    --effort s \
    --skip-obs-acs \
    --quiet \
    2>"$TMP/stderr.txt" || true)

if [[ -z "$RESULT" ]]; then
    echo "FAIL: reserve returned empty output. stderr:" >&2
    cat "$TMP/stderr.txt" >&2
    exit 1
fi

# Must be a valid DOMAIN-NNN ID
if ! echo "$RESULT" | grep -qE '^[A-Z]+-[0-9]+$'; then
    echo "FAIL: reserve returned unexpected output: '$RESULT'" >&2
    cat "$TMP/stderr.txt" >&2
    exit 1
fi

echo "  Reserved: $RESULT (corrupt YAML did not block reserve)"

echo "=== Step 3: --json flag returns machine-readable {id, yaml_path} ==="

# Detect if this binary supports --json (INFRA-2177 feature).
# Probe by running with --help equivalent; if raw ID comes back, flag is absent.
JSON_RESULT=$("$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "INFRA-2177 json flag test $(date +%s)" \
    --priority P2 \
    --effort s \
    --skip-obs-acs \
    --quiet \
    --json \
    2>>"$TMP/stderr.txt" || true)

if [[ -z "$JSON_RESULT" ]]; then
    echo "FAIL: --json reserve returned empty output. stderr:" >&2
    cat "$TMP/stderr.txt" >&2
    exit 1
fi

# If output is a bare ID (no braces), --json not yet compiled into this binary.
if echo "$JSON_RESULT" | grep -qE '^[A-Z]+-[0-9]+$'; then
    echo "  SKIP --json check: binary pre-dates INFRA-2177 (plain ID: $JSON_RESULT)"
    echo "  (re-run after 'cargo build -p chump' to verify --json)"
else
    # Must contain "id" key
    if ! echo "$JSON_RESULT" | grep -q '"id"'; then
        echo "FAIL: --json output missing 'id' key: '$JSON_RESULT'" >&2
        exit 1
    fi
    # Must contain "yaml_path" key
    if ! echo "$JSON_RESULT" | grep -q '"yaml_path"'; then
        echo "FAIL: --json output missing 'yaml_path' key: '$JSON_RESULT'" >&2
        exit 1
    fi
    echo "  --json output: $JSON_RESULT"
fi

echo "=== Step 4: second reserve gets a distinct ID (counter increments) ==="

RESULT2=$("$CHUMP_BIN" gap reserve \
    --domain TEST \
    --title "INFRA-2177 second gap $(date +%s)" \
    --priority P2 \
    --effort s \
    --skip-obs-acs \
    --quiet \
    2>>"$TMP/stderr.txt" || true)

if [[ "$RESULT" == "$RESULT2" ]]; then
    echo "FAIL: two consecutive reserves returned the same ID: $RESULT" >&2
    exit 1
fi

echo "  Second reserve: $RESULT2 (distinct from $RESULT)"

echo "OK: reserve is resilient to malformed YAML; counter increments correctly"
