#!/usr/bin/env bash
# test-event-registry-coverage.sh — INFRA-1237
#
# Audit EVENT_REGISTRY.yaml for drift:
#   - Detects emit-without-register kinds (code emits but not in registry)
#   - Detects register-without-emit kinds (registry lists but code never emits)
#   - Exits 1 if any drift found; 0 if clean
#
# Bypass: CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1 for emergency merges
#         (must include rationale in commit body: 'Event-Registry-Drift-Bypass: <text>')

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

cd "$REPO_ROOT" || fail "Cannot cd to $REPO_ROOT"

# ─ Extract all "kind":"..." literals from code ─────────────────────────────────
# Careful grep to avoid false positives (logs, error messages, variable refs)
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "[*] Scanning codebase for kind emissions..."
grep -rho '"kind" *: *"[a-z_]*"' src/ crates/ scripts/ 2>/dev/null \
  | grep -o '[a-z_]*"$' | tr -d '"' | sort | uniq > "$TMP_DIR/emitted.txt" \
  || true

# ─ Extract all 'kind:' entries from EVENT_REGISTRY.yaml ─────────────────────────
echo "[*] Reading EVENT_REGISTRY.yaml..."
grep '^\s*- kind:' "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
  | sed 's/.*- kind: //; s/"//g; s/[[:space:]]*$//' | sort | uniq > "$TMP_DIR/registered.txt" \
  || true

# ─ Detect emit-without-register ────────────────────────────────────────────────
echo "[*] Checking for emitted kinds not in registry..."
EMIT_NOT_REG="$(comm -23 "$TMP_DIR/emitted.txt" "$TMP_DIR/registered.txt" || true)"
if [ -n "$EMIT_NOT_REG" ]; then
  COUNT=$(echo "$EMIT_NOT_REG" | wc -l)
  warn "Found $COUNT kinds emitted but not registered:"
  echo "$EMIT_NOT_REG" | sed 's/^/  /' >&2
else
  pass "All emitted kinds are registered"
fi

# ─ Detect register-without-emit ────────────────────────────────────────────────
echo "[*] Checking for registered kinds never emitted..."
REG_NOT_EMIT="$(comm -13 "$TMP_DIR/emitted.txt" "$TMP_DIR/registered.txt" || true)"
if [ -n "$REG_NOT_EMIT" ]; then
  COUNT=$(echo "$REG_NOT_EMIT" | wc -l)
  warn "Found $COUNT kinds registered but never emitted:"
  echo "$REG_NOT_EMIT" | sed 's/^/  /' >&2
else
  pass "All registered kinds are emitted"
fi

# ─ Final verdict ───────────────────────────────────────────────────────────────
if [ -n "$EMIT_NOT_REG" ] || [ -n "$REG_NOT_EMIT" ]; then
  if [ "${CHUMP_EVENT_REGISTRY_ALLOW_DRIFT:-0}" = "1" ]; then
    warn "EVENT_REGISTRY drift detected but allowed via CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1"
    pass "Drift check bypassed (audit required in commit body)"
    exit 0
  else
    fail "EVENT_REGISTRY drift detected. Register missing emitters or remove orphans."
  fi
else
  pass "EVENT_REGISTRY is clean (zero drift)"
  exit 0
fi
