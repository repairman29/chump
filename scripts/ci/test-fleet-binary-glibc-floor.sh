#!/usr/bin/env bash
# scripts/ci/test-fleet-binary-glibc-floor.sh — RESILIENT-1038
#
# Regression guard for the "artifact-pull ALWAYS falls back to cargo build"
# bug: build-fleet-binaries.yml built on `runs-on: ubuntu-latest`, which
# GitHub silently rolls forward to newer Ubuntu releases (and therefore newer
# glibc) over time. VERIFIED live: a binary built on an ubuntu-latest runner
# (glibc 2.39, Ubuntu 24.04+) refuses to even execute on a glibc-2.35 node
# (Ubuntu 22.04, the class closetjunky + mugman/Oracle-Ampere run) — `--version`
# exits 1 with "GLIBC_2.39 not found". node-refresh-chump.sh's artifact-pull
# version-check (_try_artifact_pull) treats that as an unrunnable/mismatched
# binary and falls back to a ~30min local `cargo build --release`, which is
# exactly the cold-build-starves-the-2-core-brain symptom this gap describes.
# The workflow's own CI stays green throughout because its version-check step
# runs the native binary on the SAME (newer) runner — this breakage is
# invisible to build-fleet-binaries.yml itself and only bites on the real
# fleet nodes.
#
# The fix pins `runs-on:` to a specific LTS (ubuntu-22.04) instead of the
# rolling `ubuntu-latest` alias, so the glibc floor stays fixed at what the
# fleet's nodes actually ship. This test guards against someone reintroducing
# `ubuntu-latest` (or any other rolling alias) on the build job.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKFLOW="$REPO_ROOT/.github/workflows/build-fleet-binaries.yml"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"

# The build job must NOT use a rolling runner alias — that's exactly what let
# the glibc floor drift upward silently.
if grep -qE '^\s*runs-on:\s*ubuntu-latest\s*$' "$WORKFLOW"; then
    fail "build-fleet-binaries.yml pins the build job to 'ubuntu-latest' — this rolls the glibc floor forward and breaks artifact-pull on older-glibc fleet nodes (see RESILIENT-1038)"
fi
ok "build-fleet-binaries.yml does not use the rolling 'ubuntu-latest' alias"

# It must instead pin an explicit, versioned runner image.
grep -qE '^\s*runs-on:\s*ubuntu-[0-9]{2}\.[0-9]{2}\s*$' "$WORKFLOW" \
  || fail "build-fleet-binaries.yml does not pin an explicit ubuntu-NN.NN runner for the build job"
ok "build-fleet-binaries.yml pins an explicit versioned ubuntu runner"

exit 0
