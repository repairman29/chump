#!/usr/bin/env bash
# INFRA-8049: organ-reconcile re-places a chump-*.service that names a /root
# path on a non-root node, and surfaces one it cannot re-place.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "  ✗ $*" >&2; exit 1; }
RUN_USER="$(id -un)"
[[ "$RUN_USER" == root ]] && { echo "SKIP: root run user"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/sys" "$TMP/locks"
printf '#!/usr/bin/env bash\necho "$@" >> "%s/calls"\ncase "$1" in daemon-reload|restart) exit 0;; esac\nexit 1\n' "$TMP" > "$TMP/systemctl"
chmod +x "$TMP/systemctl"
printf 'enabled chump-nonexistent-xyz.timer\n' > "$TMP/manifest.txt"

cat > "$TMP/sys/chump-duty-officer.service" <<'UNIT'
[Service]
User=root
Environment=HOME=/root
WorkingDirectory=/root/.chumpnode/repo
ExecStart=/bin/true
UNIT
cat > "$TMP/sys/chump-no-template-xyz.service" <<'UNIT'
[Service]
User=root
WorkingDirectory=/root/.chumpnode/repo
ExecStart=/bin/true
UNIT

CHUMP_ORGAN_RECONCILE_SYSTEMD_DIR="$TMP/sys" \
CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$TMP/systemctl" \
CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
CHUMP_ORGAN_RECONCILE_FARMER_HEARTBEAT="$TMP/hb" \
CHUMP_ORGAN_RECONCILE_FARMER_HEARTBEAT_DURABLE="$TMP/hb2" \
CHUMP_ORGAN_MANIFEST="$TMP/manifest.txt" \
CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
NODE_AMBIENT="$TMP/locks/ambient.jsonl" \
  bash "$REPO_ROOT/scripts/ops/organ-reconcile.sh" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "reconcile exited non-zero"; }

U="$TMP/sys/chump-duty-officer.service"
grep -q "^User=$RUN_USER" "$U" || fail "User not rewritten"
! grep -q "^Environment=HOME=/root" "$U" || fail "HOME not rewritten"
grep -vE "^[[:space:]]*#" "$U" | grep -q "/root" && fail "unit still names /root"
grep -q '^WorkingDirectory=' "$U" || fail "no WorkingDirectory"
grep -q 'organ_unit_identity_drift_repaired' "$TMP/locks/ambient.jsonl" || fail "no repaired event"
grep -q 'organ_unit_identity_drift_unrepaired.*chump-no-template-xyz' "$TMP/locks/ambient.jsonl" || fail "no unrepaired event"
grep -q 'daemon-reload' "$TMP/calls" || fail "no daemon-reload"
echo "PASS: test-organ-reconcile-identity-drift (INFRA-8049)"
