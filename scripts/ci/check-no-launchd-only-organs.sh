#!/usr/bin/env bash
# INFRA-8188: fail when a PR ADDS a launchd/*.plist with no systemd unit/timer
# (or cron) equivalent. The fleet runs on Linux/systemd; a launchd-only organ
# never runs. Existing plists are grandfathered (only newly-added files are
# checked; porting them is INFRA-8103/8126).
#
# Env: LAUNCHD_GUARD_ROOT (repo root, default: git toplevel)
#      LAUNCHD_GUARD_BASE (base ref, default: origin/main)
set -euo pipefail

ROOT="${LAUNCHD_GUARD_ROOT:-$(git rev-parse --show-toplevel)}"
BASE="${LAUNCHD_GUARD_BASE:-origin/main}"
EXEMPT="$ROOT/scripts/ci/launchd-only-exempt.txt"
cd "$ROOT"

if ! git rev-parse --verify -q "$BASE" >/dev/null; then
  echo "SKIP: base ref $BASE not found (shallow clone?)"
  exit 0
fi

added=$(git diff --name-only --diff-filter=A "$BASE"...HEAD -- 'launchd/*.plist' || true)
[ -z "$added" ] && { echo "OK: no new launchd plists"; exit 0; }

fail=0
while IFS= read -r plist; do
  [ -z "$plist" ] && continue
  base=$(basename "$plist" .plist)
  stem=${base#com.chump.}
  if [ -f "$EXEMPT" ] && grep -Eq "^(${base}|${stem})(\.plist)?([[:space:]]|$)" "$EXEMPT"; then
    echo "OK (exempt): $plist"; continue
  fi
  found=$(git ls-files -- "*chump-${stem}.service" "*chump-${stem}.timer" \
            "*${stem}.service" "*${stem}.timer" "*cron.d/*${stem}*" | head -1)
  if [ -n "$found" ]; then
    echo "OK: $plist -> $found"
  else
    fail=1
    echo "FAIL (INFRA-8188): $plist adds a launchd-only organ with no Linux equivalent." >&2
    echo "  The fleet runs on Linux/systemd; this would never run. Add a sibling" >&2
    echo "  chump-${stem}.service (+ .timer) under scripts/dispatch/ (see chump-farmer.service)," >&2
    echo "  or a cron.d entry. Last resort: list '${base}' in scripts/ci/launchd-only-exempt.txt with a reason." >&2
  fi
done <<< "$added"
exit $fail
