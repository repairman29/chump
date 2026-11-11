#!/usr/bin/env bash
# test-cloud-shift-doorbell.sh — INFRA-8070 smoke test for the cloud-shift doorbell.
set -u
cd "$(git rev-parse --show-toplevel)"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
export CHUMP_DOORBELL_STATE_DIR=$S/st CHUMP_AMBIENT_LOG=$S/amb.jsonl
export CHUMP_DOORBELL_WORK_CMD="echo 2" CHUMP_DOORBELL_REPLY_CMD="echo 0"
printf '#!/bin/sh\necho x >>%s/fires\n' "$S" >"$S/fire.sh"; chmod +x "$S/fire.sh"; export CHUMP_DOORBELL_FIRE_CMD="$S/fire.sh"
D=scripts/coord/cloud-shift-doorbell.sh
fires() { wc -l <"$S/fires" 2>/dev/null || echo 0; }
FAIL=0; chk() { [ "$2" = "$3" ] && echo "[PASS] $1" || { echo "[FAIL] $1 ($2 != $3)"; FAIL=1; }; }

CHUMP_DOORBELL_NOW=1000 bash $D tick >/dev/null; chk "fires on eligible work" "$(fires)" 1
CHUMP_DOORBELL_NOW=1100 bash $D tick >/dev/null; chk "min gap enforced" "$(fires)" 1
CHUMP_DOORBELL_NOW=2000 CHUMP_DOORBELL_WORK_CMD="echo 0" bash $D tick >/dev/null; chk "idle -> no fire" "$(fires)" 1
CHUMP_DOORBELL_NOW=2000 CHUMP_DOORBELL_WORK_CMD="echo 0" CHUMP_DOORBELL_REPLY_CMD="echo 1" bash $D tick >/dev/null; chk "queued reply fires" "$(fires)" 2
CHUMP_DOORBELL_NOW=9000 FLEET_DISPATCH_PAUSED=1 bash $D tick >/dev/null; chk "kill switch halts" "$(fires)" 2
for _ in 1 2 3; do bash $D record junk; done
CHUMP_DOORBELL_NOW=9000 bash $D tick >/dev/null; chk "3 consecutive junk stops fires" "$(fires)" 2
bash $D reset; CHUMP_DOORBELL_NOW=9000 bash $D tick >/dev/null; chk "reset re-arms" "$(fires)" 3
exit $FAIL
