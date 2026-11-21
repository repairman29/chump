#!/usr/bin/env bash
# INFRA-8045: organ-reconcile re-rewrites installed units carrying /root paths on non-root nodes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sd" "$T/home"
printf 'enabled  chump-conductor.timer  role=brain\n' > "$T/manifest"
printf '[Service]\nWorkingDirectory=/root/chump\nExecStart=/bin/bash -c "exec /root/.cargo/bin/chump x"\n' > "$T/sd/chump-conductor.service"
printf '#!/bin/bash\nexit 0\n' > "$T/systemctl"; chmod +x "$T/systemctl"
CHUMP_RUN_USER="$(id -un)" CHUMP_ORGAN_MANIFEST="$T/manifest" CHUMP_ORGAN_RECONCILE_SYSTEMD_DIR="$T/sd" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$T/systemctl" CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$T/bo" CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_STATE_DIR="$T/home" HOME="$T/home" NODE_AMBIENT="$T/amb.jsonl" bash "$REPO/scripts/ops/organ-reconcile.sh" --apply >"$T/out" 2>&1 || true
if [[ "$(getent passwd "$(id -un)" | cut -d: -f6)" == "/root" ]]; then echo "SKIP (running as root home)"; exit 0; fi
grep -q "REPAIRED root-path drift" "$T/out" || { cat "$T/out"; echo "FAIL: no repair"; exit 1; }
! grep -q '/root' "$T/sd/chump-conductor.service" || { echo "FAIL: /root remains"; exit 1; }
echo "PASS"
