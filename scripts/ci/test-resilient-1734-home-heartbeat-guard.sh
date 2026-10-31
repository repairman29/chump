#!/usr/bin/env bash
# scripts/ci/test-resilient-1734-home-heartbeat-guard.sh — RESILIENT-1734
#
# RESILIENT-1698 re-homed 4 detector organs (pr-stuck live-scan +
# cluster-detector, ci-flake-rerun, ci-health-gate) to `slim` via an
# unreviewed self-armed merge, while `slim` was offline — nothing in
# organ-reconcile.sh checked whether the new home had actually come up
# before anything stopped running on the old one, so chump-ci-health-gate
# went dark on cuphead with no fallback.
#
# This proves:
#   1. organ_home_heartbeat_fresh (organ-manifest-lib.sh): any/empty/self is
#      always fresh; a stubbed `tailscale status --json` reporting the
#      target node Online, or offline-but-LastSeen within the max-age
#      window, is fresh; offline-and-stale or a missing peer is NOT fresh;
#      a missing tailscale binary fails safe (NOT fresh, never fail-open).
#   2. organ-reconcile.sh's home-migration guard: a unit live on THIS node
#      whose manifest `home=` points elsewhere is STOPPED when the new home
#      heartbeats fresh (emits organ_reconcile_home_migrated), and LEFT
#      RUNNING (refused) when the new home has no fresh heartbeat (emits
#      organ_reconcile_home_migration_refused) — reproducing + fixing the
#      RESILIENT-1698 incident deterministically.
#   3. the real organ-manifest.txt/.yaml no longer declare any of the 4
#      detector organs `home=slim` (restored to `home=cuphead`, since slim
#      was confirmed offline at ship time).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ok $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-resilient-1734-home-heartbeat-guard.sh (RESILIENT-1734) ==="
bash -n "$LIB" || fail "organ-manifest-lib.sh bash -n"
bash -n "$RECONCILE" || fail "organ-reconcile.sh bash -n"
# shellcheck source=/dev/null
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. organ_home_heartbeat_fresh ────────────────────────────────────────
export CHUMP_ORGAN_MANIFEST_NODE=cuphead

organ_home_heartbeat_fresh "" 600 || fail "empty home must be fresh (no migration to guard)"
organ_home_heartbeat_fresh "any" 600 || fail "home=any must be fresh"
organ_home_heartbeat_fresh "cuphead" 600 || fail "home == current node must be fresh (no cross-node check)"

FAKE_TAILSCALE="$TMP/tailscale"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FIVE_MIN_AGO="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)"
ONE_DAY_AGO="$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)"

cat > "$FAKE_TAILSCALE" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "status --json")
    cat <<JSON
{"Peer":{"a":{"HostName":"slim","Online":false,"LastSeen":"$ONE_DAY_AGO"},"b":{"HostName":"mugman","Online":true,"LastSeen":"$NOW"},"c":{"HostName":"closetjunky","Online":false,"LastSeen":"$FIVE_MIN_AGO"}}}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_TAILSCALE"
export TAILSCALE_BIN="$FAKE_TAILSCALE"

organ_home_heartbeat_fresh "slim" 600 \
  && fail "slim last-seen 1 day ago must NOT be fresh"
pass "stale (1d-old) LastSeen is correctly NOT fresh"

organ_home_heartbeat_fresh "closetjunky" 600 \
  || fail "closetjunky last-seen 5 min ago must be fresh (within 600s window)"
pass "recent (5m-old) LastSeen is correctly fresh"

organ_home_heartbeat_fresh "mugman" 600 \
  || fail "mugman reported Online:true must be fresh regardless of LastSeen"
pass "Online:true is fresh regardless of LastSeen"

organ_home_heartbeat_fresh "nowhere-node" 600 \
  && fail "a peer absent from the tailnet must NOT be fresh"
pass "absent peer is correctly NOT fresh"

export TAILSCALE_BIN="$TMP/does-not-exist-tailscale"
organ_home_heartbeat_fresh "slim" 600 \
  && fail "a missing tailscale binary must fail SAFE (not fresh), never fail-open"
pass "missing tailscale binary fails safe (not fresh)"
unset TAILSCALE_BIN CHUMP_ORGAN_MANIFEST_NODE

# ── 2. organ-reconcile.sh home-migration guard (end-to-end) ─────────────────
M="$TMP/manifest.txt"
cat > "$M" <<'EOF'
enabled  chump-migrates-when-fresh.service    role=brain home=slim
enabled  chump-stays-when-stale.service       role=brain home=slim
enabled  chump-local.service                  role=brain home=cuphead
EOF

STUB="$TMP/systemctl"; CALLS="$TMP/calls.log"; ACTIVE="$TMP/active.txt"
printf 'chump-migrates-when-fresh.service\nchump-stays-when-stale.service\nchump-local.service\n' > "$ACTIVE"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
  is-active) grep -qxF "\${@: -1}" "$ACTIVE" && exit 0 || exit 3 ;;
  is-enabled) grep -qxF "\${@: -1}" "$ACTIVE" && exit 0 || exit 1 ;;
  is-failed) echo "active"; exit 0 ;;
  enable) echo "\${@: -1}" >> "$ACTIVE"; exit 0 ;;
  disable) sed -i.bak "/^\${@: -1}\$/d" "$ACTIVE" 2>/dev/null || true; exit 0 ;;
  show) echo "ExecStart=/bin/true"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

FAKE_TAILSCALE2="$TMP/tailscale2"
cat > "$FAKE_TAILSCALE2" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "status --json")
    cat <<JSON
{"Peer":{"a":{"HostName":"slim","Online":true,"LastSeen":"$NOW"}}}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_TAILSCALE2"

AMBIENT="$TMP/ambient.jsonl"
: > "$CALLS"
out="$(CHUMP_ORGAN_MANIFEST="$M" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST_PLATFORM=systemd \
  CHUMP_ORGAN_MANIFEST_NODE=cuphead \
  TAILSCALE_BIN="$FAKE_TAILSCALE2" \
  NODE_AMBIENT="$AMBIENT" \
  bash "$RECONCILE" --apply 2>&1)"

echo "$out" | grep -q "HOME-MIGRATE: chump-migrates-when-fresh.service" \
  || fail "unit whose new home (fresh heartbeat) should have been migrated away; got: $out"
grep -q '"kind":"organ_reconcile_home_migrated".*chump-migrates-when-fresh.service' "$AMBIENT" \
  || fail "organ_reconcile_home_migrated event missing for the fresh-home unit; ambient: $(cat "$AMBIENT" 2>/dev/null)"
pass "unit migrates away (stops) when its new home has a fresh heartbeat"

# chump-stays-when-stale.service's home=slim, but FAKE_TAILSCALE2 only knows
# about "slim" as Online:true — so BOTH units share the same (fresh) home in
# this fixture. Re-run with a tailscale stub that reports slim OFFLINE/stale
# to prove the refusal path independently.
FAKE_TAILSCALE3="$TMP/tailscale3"
cat > "$FAKE_TAILSCALE3" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "status --json")
    cat <<JSON
{"Peer":{"a":{"HostName":"slim","Online":false,"LastSeen":"$ONE_DAY_AGO"}}}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_TAILSCALE3"

printf 'chump-stays-when-stale.service\nchump-local.service\n' > "$ACTIVE"
AMBIENT2="$TMP/ambient2.jsonl"
: > "$CALLS"
out2="$(CHUMP_ORGAN_MANIFEST="$M" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff2" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST_PLATFORM=systemd \
  CHUMP_ORGAN_MANIFEST_NODE=cuphead \
  TAILSCALE_BIN="$FAKE_TAILSCALE3" \
  NODE_AMBIENT="$AMBIENT2" \
  bash "$RECONCILE" --apply 2>&1)"

echo "$out2" | grep -q "HOME-MIGRATE-REFUSED: chump-stays-when-stale.service" \
  || fail "unit whose new home has a stale/offline heartbeat must be REFUSED (left running); got: $out2"
grep -q '"kind":"organ_reconcile_home_migration_refused".*chump-stays-when-stale.service' "$AMBIENT2" \
  || fail "organ_reconcile_home_migration_refused event missing; ambient: $(cat "$AMBIENT2" 2>/dev/null)"
grep -qxF "chump-stays-when-stale.service" "$ACTIVE" \
  || fail "refused unit must still be in the active set (left running, not stopped)"
pass "unit stays running (refused) when its new home has no fresh heartbeat — the RESILIENT-1698 fix"

# ── 3. real manifest no longer re-homes the 4 detectors to an offline slim ──
REAL="$REPO_ROOT/scripts/ops/organ-manifest.txt"
for unit in chump-ci-flake-rerun.timer chump-ci-health-gate.timer chump-pr-stuck-live-scan.service chump-pr-stuck-cluster-detector.service; do
  line="$(grep -E "^enabled[[:space:]]+${unit//./\\.}[[:space:]]" "$REAL")"
  [[ -n "$line" ]] || fail "real manifest missing enabled line for $unit"
  echo "$line" | grep -q 'home=slim' && fail "$unit is still home=slim (slim was confirmed offline at ship time) — restore home=cuphead or prove slim is back up"
done
pass "real organ-manifest.txt no longer re-homes the 4 detector organs to offline slim"

echo "PASS test-resilient-1734-home-heartbeat-guard"
