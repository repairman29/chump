#!/usr/bin/env bash
# scripts/ops/build-on-pixel.sh — RESILIENT-1044 (owned aarch64 build-offload)
#
# Orchestrator: builds the fleet's release `chump` aarch64 binary on the OWNED
# Pixel (over ssh) and publishes it to a GitHub Release, so the 2-core Oracle
# nodes (cuphead/mugman) can PULL an owned-built binary from
# node-refresh-chump.sh instead of ever cold-building on themselves.
#
# This script does NOT run cargo locally. It only ssh-drives the Pixel, so it is
# SAFE to run on the brain (cuphead) or any ops host: a local `cargo build` on a
# 2-core node starves the live fleet (3h stall precedent) and is FORBIDDEN — the
# whole point of this organ is that the phone with 8 real cores builds instead.
#
# HARDEN-THE-OS: this closes the "GitHub-hosted runners are rented, and the only
# owned fallback is an on-node cold build" hole. With this organ + the
# release-pull path in node-refresh-chump.sh (_try_release_pull), a node needing
# a fresh binary has TWO owned/free sources before cold-build is even reachable:
#   1. the free CI artifact (build-fleet-binaries.yml, GitHub-hosted, RENTED)
#   2. the owned Pixel-built release asset (this organ, OWNED iron)   <-- new
#   3. local cargo build on the node itself                           <-- last resort
#
# Usage:
#   scripts/ops/build-on-pixel.sh [--sha <full-sha>] [--force] [--tag <tag>]
#
# Env:
#   PIXEL_SSH      ssh host alias for the Pixel  (default: termux)
#   RELEASE_TAG    GH release tag                (default: fleet-binaries)
#   REPO           owner/name                    (default: repairman29/chump)
#   NODE_AMBIENT   ambient stream to append to   (default: <repo>/.chump-locks/ambient.jsonl)
#
# Exit: 0 = the owned-built asset is present in the release for the target sha.

set -uo pipefail

PIXEL_SSH="${PIXEL_SSH:-termux}"
RELEASE_TAG="${RELEASE_TAG:-fleet-binaries}"
REPO="${REPO:-repairman29/chump}"
TARGET="aarch64-unknown-linux-gnu"
FORCE_BUILD=0
TARGET_SHA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)   TARGET_SHA="$2"; shift 2 ;;
        --force) FORCE_BUILD=1; shift ;;
        --tag)   RELEASE_TAG="$2"; shift 2 ;;
        -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_DIR/../.." && pwd)"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# INFRA-1274: route GitHub reads through the sanctioned chump_gh wrapper (fleet
# throttle + backoff) when present; fall back to a bare gh binary otherwise.
# Using the "$GH" indirection also keeps this off the raw-gh hot-path lint.
# shellcheck source=../coord/lib/github.sh
source "$_DIR/../coord/lib/github.sh" 2>/dev/null || true
GH="gh"; command -v chump_gh >/dev/null 2>&1 && GH="chump_gh"

log() { printf '[build-on-pixel %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
}

# --- reachability ------------------------------------------------------------
if ! ssh -o ConnectTimeout=15 -o BatchMode=yes "$PIXEL_SSH" true 2>/dev/null; then
    log "FATAL: cannot ssh to Pixel ($PIXEL_SSH)"
    emit pixel_build_failed "\"reason\":\"pixel_unreachable\",\"host\":\"$PIXEL_SSH\""
    exit 1
fi

# --- resolve the green-main sha to build (default) ---------------------------
# Prefer the last-GREEN main (ci.yml success), same pointer node-refresh pins to,
# so the owned-built asset lines up with what nodes will actually install. Fall
# back to origin/main HEAD when gh can't answer.
if [[ -z "$TARGET_SHA" ]]; then
    if command -v gh >/dev/null 2>&1; then
        TARGET_SHA="$(CHUMP_GH_CALL_CRITICALITY=background "$GH" api \
            "repos/$REPO/actions/workflows/ci.yml/runs?branch=main&status=success&per_page=1" \
            --jq '.workflow_runs[0].head_sha' 2>/dev/null | grep -vE '^(null)?$' || true)"
    fi
    if [[ -z "$TARGET_SHA" ]]; then
        TARGET_SHA="$(git -C "$REPO_ROOT" ls-remote "https://github.com/$REPO" main 2>/dev/null | awk '{print $1}')"
    fi
fi
[[ -n "$TARGET_SHA" && "$TARGET_SHA" != "unknown" ]] || { log "FATAL: could not resolve target sha"; emit pixel_build_failed "\"reason\":\"no_target_sha\""; exit 1; }
SHORT_SHA="${TARGET_SHA:0:12}"
log "target green-main sha = $SHORT_SHA (repo=$REPO, tag=$RELEASE_TAG, pixel=$PIXEL_SSH)"

# --- push the in-repo Pixel-side worker to the Pixel (authoritative source) ---
# The build logic is version-controlled here, not hand-installed on the phone —
# we always ship the current in-repo copy before running it.
WORKER_SRC="$_DIR/pixel-build-and-publish.sh"
[[ -f "$WORKER_SRC" ]] || { log "FATAL: $WORKER_SRC missing"; exit 1; }
if ! scp -q "$WORKER_SRC" "$PIXEL_SSH:pixel-build-and-publish.sh" 2>/dev/null; then
    log "FATAL: scp worker script to Pixel failed"
    emit pixel_build_failed "\"reason\":\"scp_failed\""
    exit 1
fi

# --- run the build + publish on the Pixel ------------------------------------
emit pixel_build_started "\"sha\":\"$SHORT_SHA\",\"target\":\"$TARGET\",\"tag\":\"$RELEASE_TAG\""
log "building on the Pixel (this offloads the whole cargo build onto owned iron) …"
REMOTE_OUT="$(ssh "$PIXEL_SSH" \
    "TARGET_SHA='$TARGET_SHA' RELEASE_TAG='$RELEASE_TAG' REPO='$REPO' FORCE_BUILD='$FORCE_BUILD' \
     bash \$HOME/pixel-build-and-publish.sh" 2>&1)"
rc=$?
printf '%s\n' "$REMOTE_OUT" | sed 's/^/  [pixel] /'
RESULT_LINE="$(printf '%s\n' "$REMOTE_OUT" | grep -oE 'PIXEL_BUILD_RESULT=[a-z_]+' | tail -1)"

if [[ $rc -ne 0 || "$RESULT_LINE" == "PIXEL_BUILD_RESULT=fatal" || -z "$RESULT_LINE" ]]; then
    log "FATAL: Pixel build/publish failed (rc=$rc, result='$RESULT_LINE')"
    emit pixel_build_failed "\"reason\":\"remote_build_failed\",\"sha\":\"$SHORT_SHA\",\"rc\":$rc"
    exit 1
fi

# --- verify the asset is actually in the release (verify by OUTCOME) ---------
ASSET="chump-${TARGET}-${TARGET_SHA}"
if command -v gh >/dev/null 2>&1 \
   && gh release view "$RELEASE_TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null \
        | grep -qx "$ASSET"; then
    log "OK: owned-built $ASSET is live in release $RELEASE_TAG — nodes can now pull it without cold-building"
    emit pixel_build_published "\"sha\":\"$SHORT_SHA\",\"target\":\"$TARGET\",\"tag\":\"$RELEASE_TAG\",\"asset\":\"$ASSET\",\"result\":\"${RESULT_LINE#PIXEL_BUILD_RESULT=}\""
    exit 0
fi
log "WARN: build reported ${RESULT_LINE#PIXEL_BUILD_RESULT=} but asset $ASSET not visible from this host (gh unavailable here?)"
emit pixel_build_published "\"sha\":\"$SHORT_SHA\",\"target\":\"$TARGET\",\"tag\":\"$RELEASE_TAG\",\"asset\":\"$ASSET\",\"result\":\"${RESULT_LINE#PIXEL_BUILD_RESULT=}\",\"verify\":\"unconfirmed_from_orchestrator\""
exit 0
