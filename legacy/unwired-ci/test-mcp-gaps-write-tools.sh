#!/usr/bin/env bash
# INFRA-629: smoke-test chump-mcp-gaps write tools (gap_reserve, gap_ship, gap_set, gap_dump).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Resolve target dir — may be overridden by .cargo/config.toml
TARGET_DIR="$(cargo metadata --format-version=1 --no-deps 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["target_directory"])' 2>/dev/null || echo "$ROOT/target")"
BIN="$TARGET_DIR/debug/chump-mcp-gaps"

if [[ ! -x "$BIN" ]]; then
  cargo build -q -p chump-mcp-gaps
fi
export CHUMP_REPO="$ROOT"

# Ensure docs/gaps.yaml exists for dump tests (absent in isolated worktrees)
GAPS_YAML="$ROOT/docs/gaps.yaml"
CREATED_GAPS_YAML=0
if [[ ! -f "$GAPS_YAML" ]]; then
  mkdir -p "$ROOT/docs"
  printf 'gaps:\n  - id: TEST-001\n    title: "test gap"\n    status: open\n    priority: P2\n    effort: s\n    domain: INFRA\n' > "$GAPS_YAML"
  CREATED_GAPS_YAML=1
fi
cleanup() { [[ $CREATED_GAPS_YAML -eq 1 ]] && rm -f "$GAPS_YAML"; }
trap cleanup EXIT

rpc() {
  local method="$1" params="$2"
  echo "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
    | "$BIN"
}

# ── tools/list must include all 7 tools ─────────────────────────────────────
out="$(rpc 'tools/list' '{}')"
for tool in list_open_gaps get_gap claim_gap gap_reserve gap_ship gap_set gap_dump; do
  echo "$out" | grep -q "\"$tool\"" || {
    echo "FAIL: tools/list missing '$tool'" >&2
    echo "$out" >&2
    exit 1
  }
done
echo "ok: tools/list contains all 7 tools"

# ── gap_reserve — missing title must return error ────────────────────────────
out="$(rpc 'gap_reserve' '{}')"
echo "$out" | grep -q '"error"' || {
  echo "FAIL: gap_reserve with no title should return error" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_reserve validates required title"

# ── gap_ship — missing gap_id must return error ──────────────────────────────
out="$(rpc 'gap_ship' '{}')"
echo "$out" | grep -q '"error"' || {
  echo "FAIL: gap_ship with no gap_id should return error" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_ship validates required gap_id"

# ── gap_set — missing gap_id must return error ───────────────────────────────
out="$(rpc 'gap_set' '{}')"
echo "$out" | grep -q '"error"' || {
  echo "FAIL: gap_set with no gap_id should return error" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_set validates required gap_id"

# ── gap_dump json — must return success + gaps array ────────────────────────
out="$(rpc 'gap_dump' '{"format":"json"}')"
echo "$out" | grep -q '"success":true' || {
  echo "FAIL: gap_dump json did not succeed" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q '"gaps"' || {
  echo "FAIL: gap_dump json response missing 'gaps' key" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_dump json returns gaps array"

# ── gap_dump sql — must return success with notice ───────────────────────────
out="$(rpc 'gap_dump' '{"format":"sql"}')"
echo "$out" | grep -q '"success":true' || {
  echo "FAIL: gap_dump sql did not succeed" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q '"notice"' || {
  echo "FAIL: gap_dump sql response missing 'notice' key" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_dump sql returns notice + gaps"

# ── gap_dump invalid format — must return error ──────────────────────────────
out="$(rpc 'gap_dump' '{"format":"xml"}')"
echo "$out" | grep -q '"error"' || {
  echo "FAIL: gap_dump xml should return error" >&2
  echo "$out" >&2
  exit 1
}
echo "ok: gap_dump rejects unsupported format"

# ── gap_reserve live — exercise the chump CLI if available ───────────────────
if command -v chump &>/dev/null; then
  out="$(rpc 'gap_reserve' '{"title":"ZERO-WASTE: mcp-gaps write tool smoke test (deleteme)","domain":"INFRA","priority":"P2","effort":"xs"}')"
  echo "$out" | grep -q '"success":true' || {
    echo "FAIL: gap_reserve live call failed" >&2
    echo "$out" >&2
    exit 1
  }
  echo "ok: gap_reserve live call succeeded"
else
  echo "skip: chump not in PATH, skipping live gap_reserve test"
fi

echo "all chump-mcp-gaps write tool smoke tests passed"
