#!/usr/bin/env bash
# scripts/ci/test-daemon-contract.sh — INFRA-2356 (META-269 sub-7)
#
# Cross-daemon contract test: verifies the ambient event kinds a launchd
# daemon is EXPECTED to emit (scripts/coord/daemon-expectations.yaml, the
# source daemon-silence-monitor.sh already reads) actually appear as a
# literal `kind=X` / `"kind":"X"` string in the daemon's own emitter
# script. Catches contract drift: an expectation is added/renamed in the
# yaml but the emitter never shipped the matching literal (or vice versa
# — the emitter was refactored and the kind string silently dropped).
#
# Resolution path per daemon:
#   1. daemon-expectations.yaml → daemon label + expected_kinds
#   2. label suffix (text after "dev.chump." / "com.chump.") → find the
#      launchd plist whose Label ends in ".chump.<suffix>" (dev./com.
#      prefix drift between the yaml and the plist is tolerated — it is
#      a separate, already-known inconsistency, not what this test
#      guards against)
#   3. plist ProgramArguments → emitter script path (scripts/.../*.sh)
#   4. grep the emitter script for each expected kind as a literal
#      "kind":"<kind>" or kind=<kind> substring
#
# Exit codes:
#   0 — every expected kind is grep-able in its daemon's emitter script
#   1 — contract drift: missing plist, missing script, or missing kind
#
# Override for testing: CHUMP_DAEMON_CONTRACT_EXPECTATIONS,
# CHUMP_DAEMON_CONTRACT_PLIST_DIRS (colon-separated).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

EXPECTATIONS="${CHUMP_DAEMON_CONTRACT_EXPECTATIONS:-$REPO_ROOT/scripts/coord/daemon-expectations.yaml}"
PLIST_DIRS="${CHUMP_DAEMON_CONTRACT_PLIST_DIRS:-$REPO_ROOT/launchd:$REPO_ROOT/scripts/plists:$REPO_ROOT/scripts/launchd}"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2356 cross-daemon contract test ==="
echo

if [ ! -f "$EXPECTATIONS" ]; then
  echo "FATAL: expectations file missing: $EXPECTATIONS" >&2
  exit 2
fi

# ── Parse daemon-expectations.yaml — same minimal format as
# daemon-silence-monitor.sh's parse_expectations(). Output:
# daemon|kind1,kind2,...
parse_expectations() {
  local cur_daemon="" cur_kinds="" in_kinds=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      "  - daemon: "*)
        if [ -n "$cur_daemon" ]; then
          printf '%s|%s\n' "$cur_daemon" "$cur_kinds"
        fi
        cur_daemon="${line#"  - daemon: "}"
        cur_kinds=""
        in_kinds=0
        ;;
      "    expected_kinds:"*)
        in_kinds=1
        ;;
      "      - "*)
        if [ "$in_kinds" = "1" ]; then
          local k="${line#"      - "}"
          if [ -n "$cur_kinds" ]; then
            cur_kinds="${cur_kinds},${k}"
          else
            cur_kinds="$k"
          fi
        fi
        ;;
      "    min_per_hour: "*|"    eligibility: "*|"    description:"*)
        in_kinds=0
        ;;
    esac
  done < "$EXPECTATIONS"
  if [ -n "$cur_daemon" ]; then
    printf '%s|%s\n' "$cur_daemon" "$cur_kinds"
  fi
}

# Find the plist whose Label ends in ".chump.<suffix>" where suffix is
# the daemon name with any leading "dev." or "com." prefix stripped.
find_plist_for_daemon() {
  local daemon="$1"
  local suffix="${daemon#dev.chump.}"
  suffix="${suffix#com.chump.}"
  local IFS=':'
  for dir in $PLIST_DIRS; do
    [ -d "$dir" ] || continue
    local f
    for f in "$dir"/*.plist; do
      [ -f "$f" ] || continue
      if grep -qE "<string>(dev|com)\.chump\.${suffix}</string>" "$f" 2>/dev/null; then
        echo "$f"
        return 0
      fi
    done
  done
  return 1
}

# Extract the emitter script path (relative, "scripts/.../*.sh") from a
# plist's ProgramArguments block specifically — some plists carry a
# leading comment referencing an *installer* script (e.g.
# install-trunk-sentinel.sh) which is NOT the emitter and must be
# ignored.
extract_script_from_plist() {
  local plist="$1"
  awk '/<key>ProgramArguments<\/key>/{f=1} f{print} f && /<\/array>/{exit}' "$plist" 2>/dev/null \
    | grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' | head -1
}

# ── Main scan ─────────────────────────────────────────────────────────
daemon_count=0
while IFS='|' read -r daemon kinds; do
  [ -z "$daemon" ] && continue
  daemon_count=$((daemon_count + 1))
  echo "--- daemon: $daemon ---"

  plist="$(find_plist_for_daemon "$daemon")"
  if [ -z "$plist" ]; then
    fail "$daemon: no launchd plist found (expected Label ending in .chump.<suffix>)"
    continue
  fi

  script="$(extract_script_from_plist "$plist")"
  if [ -z "$script" ]; then
    fail "$daemon: plist $plist has no resolvable *.sh ProgramArguments entry"
    continue
  fi

  script_path="$REPO_ROOT/$script"
  if [ ! -f "$script_path" ]; then
    fail "$daemon: emitter script $script (from $plist) does not exist"
    continue
  fi

  IFS=',' read -ra kind_list <<< "$kinds"
  for kind in "${kind_list[@]}"; do
    [ -z "$kind" ] && continue
    # Accept the canonical "kind":"X" / kind=X literal forms, plus a
    # bare quoted "X" — some emitters pass the kind as a positional
    # argument to a helper (e.g. `emit_ambient "disk_critical" ...`)
    # rather than inlining a "kind=" literal.
    if grep -qE "\"kind\":\"${kind}\"|kind=${kind}([^A-Za-z0-9_]|\$)|\"${kind}\"" "$script_path" 2>/dev/null; then
      ok "$daemon: $script emits kind=$kind"
    else
      fail "$daemon: $script never emits expected kind=$kind (contract drift — daemon-expectations.yaml vs source)"
    fi
  done
done < <(parse_expectations)

if [ "$daemon_count" -eq 0 ]; then
  echo "FATAL: no daemons parsed from $EXPECTATIONS" >&2
  exit 2
fi

# ── Summary ───────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ($daemon_count daemons scanned) ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
