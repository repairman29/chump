#!/usr/bin/env bash
# cross-build-linux.sh — INFRA-2105
#
# One command: cross-build a chump workspace package for Linux aarch64
# in Docker. Handles the sccache-wrapper-vs-container-missing-binary
# friction (INFRA-2104 RCA) by setting CARGO_BUILD_RUSTC_WRAPPER=""
# automatically. Uses an isolated target dir so partial state from
# failed runs doesn't leak between attempts.
#
# Why this exists:
#   .cargo/config.toml is per-machine (.gitignore'd) and sets
#   rustc-wrapper to either /opt/homebrew/bin/sccache (older
#   install-sccache.sh) or just "sccache" (current). In a Linux
#   container that wrapper path/binary doesn't exist, so cargo errors
#   before doing anything useful. The first failed attempt leaves
#   corrupted intermediate state in the target dir, which then
#   surfaces as confusing errors on the second attempt. The fix is
#   simple — disable the wrapper for the container build and use a
#   fresh target dir — but it took us an hour to root-cause the first
#   time. This script captures the working incantation so the next
#   operator (or curator) doesn't repeat the investigation.
#
# Usage:
#   bash scripts/dev/cross-build-linux.sh                 # build -p chump-coord (all 3 bins)
#   bash scripts/dev/cross-build-linux.sh -p some-package # build a different workspace package
#   bash scripts/dev/cross-build-linux.sh --bin chump-worker  # build only the named bin
#   bash scripts/dev/cross-build-linux.sh --target-dir /tmp/foo  # override target dir
#   bash scripts/dev/cross-build-linux.sh --clean         # rm -rf target dir before build
#
# Companion: docs/strategy/NATS_A2A_DEMO_2026-05-28.md (the Phase-2
# appendix where this came from).

set -euo pipefail

# Defaults
PACKAGE="chump-coord"
BIN=""
TARGET_DIR="/tmp/chump-cross-build-linux"
CLEAN=0
RUST_IMAGE="rust:1.95-slim"

usage() {
    cat <<'USAGE'
cross-build-linux.sh — one command cross-builds a chump workspace package
                       for Linux aarch64 in Docker.

Defaults to building `chump-coord` (all 3 bins). Sets CARGO_BUILD_RUSTC_WRAPPER=""
automatically to override the Mac sccache wrapper in .cargo/config.toml.

Flags:
    -p, --package NAME    workspace package to build (default: chump-coord)
    --bin NAME            build only this bin target (default: all bins)
    --target-dir DIR      cargo target dir on host (default: /tmp/chump-cross-build-linux)
    --clean               rm -rf target dir before build (use after a failed run)
    --image IMG           Docker rust image (default: rust:1.95-slim)
    -h, --help            show this help

Example:
    bash scripts/dev/cross-build-linux.sh                      # build chump-coord
    bash scripts/dev/cross-build-linux.sh -p chump-coord --bin chump-worker
    bash scripts/dev/cross-build-linux.sh --clean              # nuke + rebuild

Companion: docs/strategy/NATS_A2A_DEMO_2026-05-28.md (Phase-2 appendix).
USAGE
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -p|--package) PACKAGE="$2"; shift 2 ;;
        --bin) BIN="$2"; shift 2 ;;
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --image) RUST_IMAGE="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Docker Desktop on macOS hides the credential helper in a non-PATH location.
# Splice it in so `docker pull` against Docker Hub doesn't fail with
# "executable file not found: docker-credential-desktop".
if [ -d "/Applications/Docker.app/Contents/Resources/bin" ]; then
    PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
    export PATH
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[cross-build] docker not on PATH" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "[cross-build] docker daemon not running — start Docker Desktop or your container runtime first" >&2
    exit 1
fi

if [ "$CLEAN" -eq 1 ] && [ -d "$TARGET_DIR" ]; then
    echo "[cross-build] --clean: removing $TARGET_DIR"
    rm -rf "$TARGET_DIR"
fi
mkdir -p "$TARGET_DIR"

CARGO_FLAGS="--release -p $PACKAGE"
if [ -n "$BIN" ]; then
    CARGO_FLAGS="$CARGO_FLAGS --bin $BIN"
fi

echo "[cross-build] image: $RUST_IMAGE"
echo "[cross-build] package: $PACKAGE${BIN:+, bin=$BIN}"
echo "[cross-build] target dir: $TARGET_DIR"
echo "[cross-build] cargo flags: $CARGO_FLAGS"
echo ""

# CARGO_BUILD_RUSTC_WRAPPER="" overrides the per-machine .cargo/config.toml
# rustc-wrapper that points to a Mac-only sccache binary. CARGO_TARGET_DIR
# isolates build state so partial failures don't leak between runs.
START=$(date +%s)
docker run --rm \
    -v "$REPO_ROOT:/src:ro" \
    -v "$TARGET_DIR:/target" \
    -w /src \
    -e CARGO_BUILD_RUSTC_WRAPPER="" \
    -e CARGO_TARGET_DIR=/target \
    "$RUST_IMAGE" \
    sh -c "
        set -e
        apt-get update -qq
        apt-get install -y -qq pkg-config libssl-dev cmake >/dev/null
        cargo build $CARGO_FLAGS
    "
ELAPSED=$(( $(date +%s) - START ))

echo ""
echo "[cross-build] OK in ${ELAPSED}s"
echo "[cross-build] binaries:"
# -perm +111 works on both BSD find (macOS) and GNU find (Linux); -executable
# is GNU-only and breaks on the host this script usually runs from.
find "$TARGET_DIR/release" -maxdepth 1 -type f -perm +111 -not -name "*.d" 2>/dev/null \
    | xargs -I{} sh -c 'printf "  %s  (%s)\n" "{}" "$(du -h "{}" | cut -f1)"'
