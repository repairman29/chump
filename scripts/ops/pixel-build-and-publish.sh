#!/usr/bin/env bash
# scripts/ops/pixel-build-and-publish.sh — RESILIENT-1044 (owned aarch64 builder)
#
# Runs ON the Pixel (Termux), driven by scripts/ops/build-on-pixel.sh. Builds the
# fleet's release `chump` aarch64 binary on OWNED iron and publishes it to a
# GitHub Release so the 2-core Oracle nodes (cuphead/mugman) can PULL an
# owned-built binary instead of ever cold-building `cargo build --release` on
# themselves (which starved the live fleet for 3h once — FORBIDDEN, see
# mac-evacuated-cuphead-canonical / node-fabric productization notes).
#
# WHY a proot glibc rootfs, not a native Termux build (the load-bearing fact):
#   The Pixel's native rustc host is `aarch64-linux-android` (Android/bionic
#   libc). A binary built there links bionic and will NOT run on the Oracle
#   nodes, which are Ubuntu 22.04 / glibc 2.35 — it is the same arch but a
#   different C ABI. So we build inside an Ubuntu 22.04 proot-distro container
#   (glibc 2.35), which produces a genuine `aarch64-unknown-linux-gnu` binary
#   whose glibc floor MATCHES the nodes (and matches CI's pinned ubuntu-22.04 in
#   .github/workflows/build-fleet-binaries.yml, chosen for the same
#   RESILIENT-1038 glibc-floor reason). Building in a newer distro (24.04/26.04,
#   glibc 2.39/2.43) would reproduce the "GLIBC_x not found" trap that makes a
#   binary refuse to run on the nodes.
#
# CONTRACT (matches build-fleet-binaries.yml so node-refresh-chump.sh's existing
# integrity/version checks accept both sources identically):
#   - artifact/asset name: chump-<target>-<full-sha>   (target = aarch64-unknown-linux-gnu)
#   - CHUMP_BUILD_SHA=<full-sha> forces the --version string SHA (build.rs)
#   - a sibling <asset>.sha256 (sha256sum, column 1 = hash) rides along
#
# IDEMPOTENT: if the release already holds the asset for TARGET_SHA (and not
# FORCE_BUILD=1), it verifies + exits 0 without invoking cargo at all.
#
# Env:
#   TARGET_SHA        full commit sha to build   (default: origin/main HEAD)
#   RELEASE_TAG       GH release tag to publish to (default: fleet-binaries)
#   REPO              owner/name                 (default: repairman29/chump)
#   PROOT_CONTAINER   proot-distro container     (default: ubuntu2204)
#   FORCE_BUILD=1     rebuild + re-upload even if the asset exists
#   KEEP_ASSETS       prune to the newest N chump-* assets (default: 20; 0 = off)
#
# Exit: 0 = asset present in the release for TARGET_SHA (built or already there).

set -uo pipefail

RELEASE_TAG="${RELEASE_TAG:-fleet-binaries}"
REPO="${REPO:-repairman29/chump}"
PROOT_CONTAINER="${PROOT_CONTAINER:-ubuntu2204}"
TARGET="aarch64-unknown-linux-gnu"
KEEP_ASSETS="${KEEP_ASSETS:-20}"
FORCE_BUILD="${FORCE_BUILD:-0}"
STAGE="$HOME/pixel-build"
mkdir -p "$STAGE"

log() { printf '[pixel-build %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "FATAL: $*"; echo "PIXEL_BUILD_RESULT=fatal"; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh not on PATH (Termux)"
command -v proot-distro >/dev/null 2>&1 || die "proot-distro not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated on the Pixel"

# --- resolve TARGET_SHA ------------------------------------------------------
# Normally passed in by scripts/ops/build-on-pixel.sh. Fallback resolves
# origin/main HEAD via git ls-remote (no `gh api` — keeps this Pixel-side script
# off the INFRA-1274 raw-gh hot-path lint and dependency-free on the phone).
if [[ -z "${TARGET_SHA:-}" ]]; then
    TARGET_SHA="$(git ls-remote "https://github.com/$REPO" main 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$TARGET_SHA" && "$TARGET_SHA" != "unknown" ]] || die "could not resolve TARGET_SHA"
SHORT_SHA="${TARGET_SHA:0:12}"
ASSET="chump-${TARGET}-${TARGET_SHA}"
log "target sha=$SHORT_SHA  asset=$ASSET  release=$RELEASE_TAG  repo=$REPO"

# --- ensure the release exists (rolling prerelease, tagged on main) ----------
if ! gh release view "$RELEASE_TAG" -R "$REPO" >/dev/null 2>&1; then
    log "creating release $RELEASE_TAG (rolling prerelease of owned-built fleet binaries)"
    gh release create "$RELEASE_TAG" -R "$REPO" --prerelease --target main \
        --title "Fleet binaries (owned-built)" \
        --notes "Rolling store of owned-iron-built fleet binaries (RESILIENT-1044). Assets are chump-<target>-<sha> built on the Pixel's Ubuntu 22.04 (glibc 2.35) proot so Oracle nodes never cold-build. Managed by scripts/ops/build-on-pixel.sh." \
        >/dev/null 2>&1 || die "could not create release $RELEASE_TAG"
fi

# --- idempotency: asset already published for this sha? ----------------------
asset_present() {
    gh release view "$RELEASE_TAG" -R "$REPO" --json assets \
        --jq '.assets[].name' 2>/dev/null | grep -qx "$ASSET"
}
if [[ "$FORCE_BUILD" != "1" ]] && asset_present; then
    log "asset $ASSET already in release $RELEASE_TAG — nothing to build (idempotent)"
    echo "PIXEL_BUILD_RESULT=already_present sha=$SHORT_SHA asset=$ASSET"
    exit 0
fi

# --- ensure the glibc build container + toolchain exist (bootstrap once) -----
ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/$PROOT_CONTAINER"
if [[ ! -d "$ROOTFS" ]]; then
    log "proot container $PROOT_CONTAINER missing — installing Ubuntu 22.04 (glibc 2.35)"
    yes | proot-distro install ubuntu:22.04 --name "$PROOT_CONTAINER" >/dev/null 2>&1 || true
    [[ -d "$ROOTFS" ]] || die "failed to provision $PROOT_CONTAINER"
fi

log "provisioning toolchain in $PROOT_CONTAINER (idempotent) + building at $SHORT_SHA"
BUILD_LOG="$STAGE/build-$SHORT_SHA.log"
proot-distro login "$PROOT_CONTAINER" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v gcc >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq build-essential git curl ca-certificates pkg-config
fi
if [ ! -x $HOME/.cargo/bin/cargo ]; then
  curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
fi
. $HOME/.cargo/env
mkdir -p /root/build && cd /root/build
if [ ! -d chump/.git ]; then
  git clone --filter=blob:none https://github.com/'"$REPO"'.git chump
fi
cd chump
git fetch origin --quiet
git checkout -q '"$TARGET_SHA"'
export CHUMP_BUILD_SHA='"$TARGET_SHA"'
cargo build --release --bin chump
BIN=target/release/chump
test -x "$BIN"
"$BIN" --version
' 2>&1 | tee "$BUILD_LOG"
rc="${PIPESTATUS[0]}"
[[ "$rc" == "0" ]] || die "cargo build inside $PROOT_CONTAINER failed (see $BUILD_LOG)"

# --- copy the built binary out of the proot rootfs to Termux fs --------------
BUILT="$ROOTFS/root/build/chump/target/release/chump"
[[ -x "$BUILT" ]] || die "built binary not found at $BUILT"
STAGED_BIN="$STAGE/$ASSET"
cp -f "$BUILT" "$STAGED_BIN"
chmod +x "$STAGED_BIN"

# --- verify the binary embeds the sha we intended (contract check) -----------
VER="$("$STAGED_BIN" --version 2>/dev/null || echo unrunnable)"
case "$VER" in
    *"$SHORT_SHA"*) log "version check ok: $VER" ;;
    *) die "built --version '$VER' does not embed $SHORT_SHA (build.rs / CHUMP_BUILD_SHA mismatch)" ;;
esac

# sha256 sidecar (column 1 = hash; node-refresh reads awk '{print $1}')
sha256sum "$STAGED_BIN" | awk '{print $1}' > "$STAGED_BIN.sha256"

# --- publish to the release (clobber = overwrite if FORCE re-upload) ---------
log "uploading $ASSET (+ .sha256) to $RELEASE_TAG"
gh release upload "$RELEASE_TAG" "$STAGED_BIN" "$STAGED_BIN.sha256" \
    -R "$REPO" --clobber >/dev/null 2>&1 || die "gh release upload failed"

# --- prune old assets (keep newest KEEP_ASSETS chump-* binaries) -------------
if [[ "$KEEP_ASSETS" -gt 0 ]]; then
    mapfile -t old < <(gh release view "$RELEASE_TAG" -R "$REPO" \
        --json assets --jq '.assets | sort_by(.createdAt) | reverse | .[].name' 2>/dev/null \
        | grep -E "^chump-${TARGET}-[0-9a-f]+$" | tail -n +"$((KEEP_ASSETS+1))")
    for a in "${old[@]:-}"; do
        [[ -z "$a" ]] && continue
        gh release delete-asset "$RELEASE_TAG" "$a" -R "$REPO" --yes >/dev/null 2>&1 || true
        gh release delete-asset "$RELEASE_TAG" "$a.sha256" -R "$REPO" --yes >/dev/null 2>&1 || true
        log "pruned old asset $a"
    done
fi

log "OK: published owned-built $ASSET"
echo "PIXEL_BUILD_RESULT=published sha=$SHORT_SHA asset=$ASSET version=\"$VER\""
exit 0
