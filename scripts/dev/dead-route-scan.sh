#!/usr/bin/env bash
# dead-route-scan.sh — audit src/web_server.rs /api/* routes for zero production callers.
#
# Extracts every `.route("/api/...", ...)` registration, then checks for callers in:
#   - web/v2/** (frontend fetch/XHR calls)
#   - src/**  excluding web_server.rs itself (internal Rust callers)
#   - tests/**, src/**/tests.rs, #[cfg(test)] blocks (test-only references)
#
# A route with zero frontend + zero internal-Rust + zero test hits is "dead".
# A route with zero frontend + zero internal-Rust but >=1 test hit is "test-only".
#
# Usage: scripts/dev/dead-route-scan.sh [--json]
#
# INFRA-1569
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

JSON_OUT=0
if [[ "${1:-}" == "--json" ]]; then
  JSON_OUT=1
fi

WEB_SERVER="src/web_server.rs"

# Extract registered route paths (handles both single-line and wrapped .route("path", ...) calls).
mapfile -t ROUTES < <(perl -0777 -ne 'while (/\.route\(\s*"(\/api[^"]*)"/gs) { print "$1\n" }' "$WEB_SERVER" | sort -u)

dead=()
test_only=()
live=()

for route in "${ROUTES[@]}"; do
  # Build a grep-safe pattern: escape regex metachars, then let {param} segments match any
  # path segment content (so /api/gap/{id} matches /api/gap/${id} or /api/gap/123 call sites).
  pattern=$(printf '%s' "$route" | sed -e 's/[.[\*^$]/\\&/g' -e 's/{[^}]*}/[^"'"'"'\/]*/g')

  # Frontend callers: web/v2/** excluding generated/vendor dirs.
  fe_hits=$(grep -rlE "$pattern" web/v2 --include='*.js' --include='*.ts' --include='*.html' 2>/dev/null | wc -l | tr -d ' ' || true)

  # Internal Rust callers: src/** excluding web_server.rs itself.
  rs_hits=$( (grep -rlE "$pattern" src --include='*.rs' 2>/dev/null || true) | grep -v "^${WEB_SERVER}$" | wc -l | tr -d ' ')

  # Test references: tests/** plus any #[cfg(test)] file, plus scripts/ci smoke tests.
  test_hits=$(grep -rlE "$pattern" tests 2>/dev/null | wc -l | tr -d ' ' || true)
  test_hits=$((test_hits + $(grep -rlE "$pattern" scripts/ci --include='*.sh' 2>/dev/null | wc -l | tr -d ' ' || true)))

  if [[ "$fe_hits" -gt 0 || "$rs_hits" -gt 0 ]]; then
    live+=("$route")
  elif [[ "$test_hits" -gt 0 ]]; then
    test_only+=("$route")
  else
    dead+=("$route")
  fi
done

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
total=${#ROUTES[@]}
dead_count=${#dead[@]}
test_only_count=${#test_only[@]}
live_count=${#live[@]}

if [[ "$JSON_OUT" -eq 1 ]]; then
  printf '{'
  printf '"total":%d,"dead_count":%d,"test_only_count":%d,"live_count":%d,' "$total" "$dead_count" "$test_only_count" "$live_count"
  printf '"dead":['
  for i in "${!dead[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '"%s"' "${dead[$i]}"; done
  printf '],"test_only":['
  for i in "${!test_only[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '"%s"' "${test_only[$i]}"; done
  printf ']}'
  echo
else
  echo "== dead-route-scan (INFRA-1569) =="
  echo "total registered routes: $total"
  echo "live (fe/rs callers):    $live_count"
  echo "test-only:               $test_only_count"
  echo "dead (zero callers):     $dead_count"
  echo
  echo "-- dead --"
  printf '  %s\n' "${dead[@]:-}"
  echo
  echo "-- test-only --"
  printf '  %s\n' "${test_only[@]:-}"
fi

# Emit ambient event so the fleet's picker/detectors can see scan cadence + drift.
AMBIENT_LOG=".chump-locks/ambient.jsonl"
if [[ -d "$(dirname "$AMBIENT_LOG")" ]]; then
  printf '{"ts":"%s","kind":"dead_route_scan","total":%d,"dead_count":%d,"test_only_count":%d,"live_count":%d}\n' \
    "$ts" "$total" "$dead_count" "$test_only_count" "$live_count" >> "$AMBIENT_LOG"
fi
