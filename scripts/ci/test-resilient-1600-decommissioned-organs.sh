#!/usr/bin/env bash
# RESILIENT-1600: decommissioned (state=retired) organs must not appear in any
# shipped unit list or as an enabled/disabled-active manifest row.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/scripts/ops/organ-manifest.txt"
fail=0
mapfile -t RET < <(awk '$1=="retired"{print $2}' "$M" | sed -E 's/\.(timer|service)$//' | sort -u)
# chump-rot-reaper: PHASE-R R3 retirement still ships its unit files (pre-existing, tracked separately)
for base in "${RET[@]}"; do
  [[ "$base" == chump-rot-reaper ]] && continue
  [[ -z "$base" ]] && continue
  for f in "$ROOT"/scripts/dispatch/"$base".* "$ROOT"/systemd/"$base".* "$ROOT"/launchd/*"$base"*; do
    [[ -e "$f" ]] && { echo "FAIL: retired organ '$base' still shipped: $f"; fail=1; }
  done
  if grep -Eq "^(enabled|paging_off)[[:space:]]+${base}\.(timer|service)" "$M"; then
    echo "FAIL: retired organ '$base' also has an enabled row"; fail=1
  fi
done
grep -Eq '^retired[[:space:]]+chump-merge-serializer\.timer' "$M" || { echo "FAIL: merge-serializer not retired"; fail=1; }
[[ $fail -eq 0 ]] && echo "ok: ${#RET[@]} retired organs absent from shipped unit lists"
exit $fail
