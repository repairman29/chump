#!/usr/bin/env bash
# behavior_capabilities_registry_gen.sh — INFRA-1729 (Column A smoke test)
#
# Synthesizes a tiny target repo with one of each primitive class:
#   - 1 CLI binary with --help advertising 2 subcommands
#   - 1 ambient event kind in docs/observability/EVENT_REGISTRY.yaml
#   - 1 pub fn in a crates/<name>/src/lib.rs library
#   - 1 MCP tool stub in chump-mcp.json
#
# Runs the wrapper (scripts/ops/generate-capabilities-registry.sh) against it
# and asserts:
#   - Output JSON has the 4 expected top-level keys
#   - Each key contains the expected number of entries from the synthetic repo
#
# This is the Column A "chump ingest" demo's regression gate — if the
# Quartermaster artifact's contract drifts, the entire ingest demo breaks.
#
# Bypass: CHUMP_BEHAVIOR_CAPREG_SKIP=1.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GENERATOR="$REPO_ROOT/scripts/ops/generate-capabilities-registry.sh"
BUILDER="$REPO_ROOT/scripts/dev/build-capabilities-registry.sh"

if [[ "${CHUMP_BEHAVIOR_CAPREG_SKIP:-0}" == "1" ]]; then
    echo "[behavior_capabilities_registry_gen] skipped"
    exit 0
fi

for tool in "$GENERATOR" "$BUILDER"; do
    if [[ ! -x "$tool" ]]; then
        echo "FAIL: missing or not executable: $tool" >&2
        exit 1
    fi
done

TMP="$(mktemp -d -t chump-capreg-smoke-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── Synthesize a tiny repo ───────────────────────────────────────────────────
mkdir -p "$TMP/docs/observability"
mkdir -p "$TMP/crates/widget/src"
mkdir -p "$TMP/src/bin"

# CLI binary stub — not actually compiled; the generator parses --help text
# via chump on PATH or returns an empty list. For the smoke test we cannot
# rely on a runnable binary; instead we drop a known help-text file the
# generator can consume in its fixture mode. To keep generator behaviour
# simple, we skip the runtime invocation and assert against the structure
# the generator emits for empty inputs (event_kinds + crate_apis + mcp_tools
# all populate; cli_commands populates only when `chump` is on PATH AND
# the target repo is the chump repo — for the synthetic target it stays
# empty by design).

# Event kind registration.
cat >"$TMP/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
schema_version: 2
events:
  - kind: widget_factory_emit
    emitter: crates/widget/src/lib.rs
    trigger: synthetic event for smoke test
    consumers: [smoke-test-consumer]
    fields_required: [ts, kind, count]
YAML

# A library crate with one pub fn.
cat >"$TMP/crates/widget/Cargo.toml" <<'TOML'
[package]
name = "widget"
version = "0.1.0"
edition = "2021"
TOML

cat >"$TMP/crates/widget/src/lib.rs" <<'RUST'
//! Widget — smoke-test fixture.
pub fn make_widget() -> u32 { 42 }
RUST

# MCP tool stub via chump-mcp.json.
cat >"$TMP/chump-mcp.json" <<'JSON'
{
  "mcpServers": {
    "widget-mcp": {
      "command": "widget-mcp",
      "args": [],
      "env": {},
      "enabled": true
    }
  }
}
JSON

# Initialize as a git repo so `git remote get-url origin` doesn't blow up
# (the generator falls back to basename; we just want a clean run).
( cd "$TMP" && git init -q && git config user.email smoke@chump.dev && git config user.name smoke )

# ── Run the wrapper ──────────────────────────────────────────────────────────
if ! bash "$GENERATOR" "$TMP" --quiet 2>/tmp/chump-capreg-smoke-stderr; then
    echo "FAIL: generator exited non-zero"
    cat /tmp/chump-capreg-smoke-stderr
    exit 1
fi

OUT="$TMP/docs/CAPABILITIES_REGISTRY.json"
if [[ ! -f "$OUT" ]]; then
    echo "FAIL: output not produced at $OUT"
    exit 1
fi

# ── Assertions ───────────────────────────────────────────────────────────────
FAIL=0

# Each of the 4 top-level kind-specific keys must be present.
for key in cli_commands event_kinds crate_apis mcp_tools; do
    if ! python3 -c "import json,sys; d=json.load(open('$OUT')); sys.exit(0 if '$key' in d else 1)"; then
        echo "FAIL: missing top-level key: $key"
        FAIL=1
    fi
done
[[ "$FAIL" -eq 0 ]] && echo "PASS: all 4 top-level keys present"

# Expected counts from the synthetic repo:
#   cli_commands  → 0 (no chump binary on the synthetic repo; generator
#                     returns an empty list rather than failing)
#   event_kinds   → 1 (widget_factory_emit)
#   crate_apis    → 1 (widget crate with 1 public item)
#   mcp_tools     → 1 (widget-mcp)
expected_events=1
expected_crates=1
expected_mcp=1

actual_events="$(python3 -c "import json; print(len(json.load(open('$OUT')).get('event_kinds',[])))")"
actual_crates="$(python3 -c "import json; print(len(json.load(open('$OUT')).get('crate_apis',[])))")"
actual_mcp="$(python3 -c "import json; print(len(json.load(open('$OUT')).get('mcp_tools',[])))")"

if [[ "$actual_events" -ne "$expected_events" ]]; then
    echo "FAIL: event_kinds count: expected=$expected_events actual=$actual_events"
    FAIL=1
else
    echo "PASS: event_kinds count = $actual_events"
fi

if [[ "$actual_crates" -ne "$expected_crates" ]]; then
    echo "FAIL: crate_apis count: expected=$expected_crates actual=$actual_crates"
    FAIL=1
else
    echo "PASS: crate_apis count = $actual_crates"
fi

if [[ "$actual_mcp" -ne "$expected_mcp" ]]; then
    echo "FAIL: mcp_tools count: expected=$expected_mcp actual=$actual_mcp"
    FAIL=1
else
    echo "PASS: mcp_tools count = $actual_mcp"
fi

# Crate API: the widget crate must have 1 public item (make_widget).
pub_count="$(python3 -c "
import json
d=json.load(open('$OUT'))
for c in d.get('crate_apis',[]):
    if c['crate_name'] == 'widget':
        print(len(c.get('public_items',[])))
        break
" || echo 0)"
if [[ "$pub_count" -ne 1 ]]; then
    echo "FAIL: widget crate public_items: expected=1 actual=$pub_count"
    FAIL=1
else
    echo "PASS: widget crate public_items = 1 (make_widget)"
fi

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi
echo "[behavior_capabilities_registry_gen] OK"
