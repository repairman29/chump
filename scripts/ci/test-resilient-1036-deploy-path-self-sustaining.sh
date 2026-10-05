#!/usr/bin/env bash
# scripts/ci/test-resilient-1036-deploy-path-self-sustaining.sh — RESILIENT-1036
#
# Proves the two halves of "the 1035 auto-deploy organ can cleanly self-deploy
# a node with zero operator hand" that were VERIFIED broken on mugman:
#
#   (a) BINARY phase must prefer a prebuilt/provenance-verified binary over a
#       cold source build. ensure_binary() in chump-node-install.sh tries
#       fetch_ci_artifact_binary then fetch_release_binary BEFORE
#       build_binary_from_repo — if either fetch succeeds, the cold build must
#       NEVER run. Without this ordering every deploy pays a multi-minute
#       (or, on a 2-core box, timing-out) cargo build.
#
#   (b) organ-reconcile's role-scoped DRIFT-REMOVAL pass (RESILIENT-1016 part
#       a) must actually disable+reap a live chump unit that is out-of-role /
#       no longer in the manifest, not just skip it as "not applicable". A
#       role-scoped reconcile that only skips future enables but never reaps
#       existing strays leaves cruft units running (and re-failing) forever —
#       the 28-unit hand-reap this gap documents on mugman.
#
# Both code paths already exist in the tree (fetch_ci_artifact_binary /
# fetch_release_binary / build_binary_from_repo in chump-node-install.sh; the
# "3) Drift-REMOVAL pass" block in organ-reconcile.sh) — this test is the
# missing regression proof that nothing before wired into CI: neither
# test-node-install-binary-provenance.sh nor test-organ-reconcile.sh exercises
# the fetch-before-build ordering or the drift-removal pass, so either could
# silently regress (e.g. a refactor that calls build_binary_from_repo first,
# or a role-scoped reconcile that stops reaping) with no test noticing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-resilient-1036-deploy-path-self-sustaining.sh (RESILIENT-1036) ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Part (a): BINARY phase prefers prebuilt fetch over cold build ───────────
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[[ -f "$INSTALLER" ]] || fail "installer not found: $INSTALLER"

export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin"

# Source without triggering an install run (BASH_SOURCE guard in the script).
set --
# shellcheck disable=SC1090
. "$INSTALLER"

BUILD_MARKER="$TMP/build-was-called"

# 1) fetch succeeds -> build_binary_from_repo must NEVER run.
rm -f "$BUILD_MARKER" "$BIN" "$BIN.provenance"
fetch_ci_artifact_binary() {
    mkdir -p "$(dirname "$BIN")"
    printf '#!/usr/bin/env bash\necho "chump 0.9.0 (fetched)"\n' > "$BIN"
    chmod +x "$BIN"
    printf 'source=release\ntag=v0.9.0\ntriple=x86_64-unknown-linux-gnu\nbinsha256=%s\n' \
        "$(sha256_hex "$BIN")" > "$BIN.provenance"
    return 0
}
fetch_release_binary() { fail "fetch_release_binary should not run when the CI-artifact fetch already succeeded"; }
build_binary_from_repo() { touch "$BUILD_MARKER"; return 1; }

ensure_binary || fail "ensure_binary should succeed when the prebuilt fetch succeeds"
[[ -f "$BUILD_MARKER" ]] && fail "cold build ran even though the prebuilt fetch succeeded — the ~5min mugman timeout regression"
pass "a1: ensure_binary skips the cold build entirely when the CI-artifact fetch succeeds"

# 2) both fetches miss -> build_binary_from_repo IS the fallback (still wired).
rm -f "$BUILD_MARKER" "$BIN" "$BIN.provenance"
fetch_ci_artifact_binary() { return 1; }
fetch_release_binary() { return 1; }
build_binary_from_repo() { touch "$BUILD_MARKER"; return 1; }

ensure_binary && fail "ensure_binary should fail here (build stub returns 1) — a pass means the fallback wasn't actually invoked"
[[ -f "$BUILD_MARKER" ]] || fail "build_binary_from_repo must still run as the last-resort fallback when both fetches miss"
pass "a2: ensure_binary falls back to build-from-source only when both prebuilt fetches miss"

# ── Part (b): organ-reconcile drift-removal actually reaps out-of-role units ─
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
[[ -f "$RECONCILE" ]] || fail "reconcile script missing: $RECONCILE"

STATE_DIR="$TMP/organ-state"
mkdir -p "$STATE_DIR"
CALL_LOG="$TMP/calls.log"
ACTIVE_FILE="$STATE_DIR/active.txt"       # units systemctl reports is-active
ENABLED_FILE="$STATE_DIR/enabled.txt"     # units systemctl reports is-enabled
LIVE_UNITS_FILE="$STATE_DIR/live-units.txt"  # `list-unit-files` output
REMOVED_FILE="$STATE_DIR/removed.txt"
touch "$ACTIVE_FILE" "$ENABLED_FILE" "$REMOVED_FILE"

# One brain-role organ the muscle-scoped reconcile has no business managing,
# but which is stuck ACTIVE on disk (mugman's 28 cruft units) — the case the
# reconcile must reap, not merely skip.
CRUFT_UNIT="chump-cruft-brain-organ.service"
# One organ that legitimately belongs to the muscle role, must NOT be reaped.
MUSCLE_UNIT="chump-muscle-organ.service"
echo "$CRUFT_UNIT" > "$ACTIVE_FILE"
echo "$MUSCLE_UNIT" >> "$ACTIVE_FILE"
printf '%s\n%s\n' "$CRUFT_UNIT" "$MUSCLE_UNIT" > "$LIVE_UNITS_FILE"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    is-enabled)
        unit="${@: -1}"
        grep -qxF "$unit" "$ENABLED_FILE" 2>/dev/null && exit 0 || exit 1
        ;;
    list-unit-files)
        cat "$LIVE_UNITS_FILE" 2>/dev/null | awk '{print $1, "enabled"}'
        exit 0
        ;;
    enable)
        unit="${@: -1}"
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" 2>/dev/null || true
        mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE" 2>/dev/null || true
        grep -vxF "$unit" "$ENABLED_FILE" > "$ENABLED_FILE.tmp" 2>/dev/null || true
        mv "$ENABLED_FILE.tmp" "$ENABLED_FILE" 2>/dev/null || true
        echo "$unit" >> "$REMOVED_FILE"
        exit 0
        ;;
    reset-failed|stop|daemon-reload)
        exit 0
        ;;
    show)
        echo "ExecStart=/bin/true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

MANIFEST="$TMP/manifest.txt"
cat > "$MANIFEST" <<EOF
enabled  $MUSCLE_UNIT  role=muscle
EOF

AMBIENT="$TMP/ambient.jsonl"
BACKOFF_DIR="$TMP/organ-backoff"

CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
CHUMP_ORGAN_MANIFEST="$MANIFEST" \
CHUMP_ORGAN_RECONCILE_ROLE="muscle" \
NODE_AMBIENT="$AMBIENT" \
STATE_DIR="$STATE_DIR" CALL_LOG="$CALL_LOG" ACTIVE_FILE="$ACTIVE_FILE" \
ENABLED_FILE="$ENABLED_FILE" LIVE_UNITS_FILE="$LIVE_UNITS_FILE" REMOVED_FILE="$REMOVED_FILE" \
    bash "$RECONCILE" --apply > "$TMP/reconcile.out" 2>&1

grep -q "disable --now $CRUFT_UNIT" "$CALL_LOG" \
    || fail "role-scoped reconcile did not reap the out-of-role stray unit: $(cat "$CALL_LOG")"
grep -qxF "$CRUFT_UNIT" "$REMOVED_FILE" \
    || fail "out-of-role stray unit was never actually disabled"
grep -q '"kind":"organ_reconcile_drift_removed"' "$AMBIENT" \
    || fail "expected organ_reconcile_drift_removed in ambient; got: $(cat "$AMBIENT" 2>/dev/null)"
grep -qxF "$MUSCLE_UNIT" "$REMOVED_FILE" \
    && fail "in-role unit was wrongly reaped alongside the out-of-role stray"
pass "b: role-scoped organ-reconcile --apply disables+reaps an out-of-role stray unit (the 28-unit mugman hand-reap this gap closes)"

echo "ALL PASS"
