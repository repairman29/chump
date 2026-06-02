#!/usr/bin/env bash
# scripts/ops/r2-sccache-lifecycle.sh — INFRA-2450
#
# Apply an object-expiry lifecycle rule to the R2 sccache buckets so the
# compile-cache can't grow unbounded. sccache never evicts on R2 (unlike the
# local ~10 GB cap), so without this the bucket accumulates forever — measured
# at 522 GB / 471k objects on 2026-06-02, climbing every build. A 30-day expiry
# caps storage at a steady state; sccache regenerates anything it still needs,
# and R2 egress is free, so eviction is pure savings.
#
# Cost model + the full pricing breakdown: docs/process/SCCACHE_R2_CACHE.md
#   → "Cost model + eviction".
#
# Requires: wrangler, authenticated via `wrangler login` (browser OAuth).
# No Cloudflare API token needed (unlike the rotation scripts).
#
# Usage:
#   bash scripts/ops/r2-sccache-lifecycle.sh                 # 30d expiry → both buckets
#   EXPIRE_DAYS=14 bash scripts/ops/r2-sccache-lifecycle.sh  # tighter expiry
#   bash scripts/ops/r2-sccache-lifecycle.sh chump-sccache   # one named bucket only
#
# Rust-First-Bypass: thin idempotent wrangler-CLI glue, operator-run ~once at
# setup, no state mutation in this repo, <200 LOC.

set -uo pipefail

EXPIRE_DAYS="${EXPIRE_DAYS:-30}"
ABORT_MPU_DAYS="${ABORT_MPU_DAYS:-1}"
RULE_NAME="sccache-expire-${EXPIRE_DAYS}d"

# Default targets both R2 sccache buckets (primary + the CI token's bucket).
if [[ $# -gt 0 ]]; then
  BUCKETS=("$@")
else
  BUCKETS=(chump-sccache chump-sccache-ci)
fi

if ! command -v wrangler >/dev/null 2>&1; then
  echo "ERROR: wrangler not installed. Install with: brew install wrangler  (or npm i -g wrangler)" >&2
  exit 2
fi

# Auth preflight — explicit negative match (whoami exits 0 even when logged out).
who="$(wrangler whoami 2>&1)"
if echo "$who" | grep -qiE 'not authenticated|please run .*login'; then
  cat >&2 <<'EOF'
ERROR: wrangler is not authenticated.
  Run once:  wrangler login    (opens a browser for Cloudflare OAuth)
  Then re-run this script. No Cloudflare API token is required.
EOF
  exit 3
fi

echo "Lifecycle rule '${RULE_NAME}': expire objects after ${EXPIRE_DAYS}d; abort incomplete multipart uploads after ${ABORT_MPU_DAYS}d."
echo ""
rc=0
for b in "${BUCKETS[@]}"; do
  echo "── bucket: ${b}"
  if wrangler r2 bucket lifecycle add "$b" "$RULE_NAME" \
       --expire-days "$EXPIRE_DAYS" \
       --abort-multipart-days "$ABORT_MPU_DAYS" \
       --force 2>&1; then
    echo "   ✓ applied to ${b}"
  else
    echo "   ✗ FAILED on ${b} — bucket missing, or token lacks lifecycle scope?" >&2
    rc=1
  fi
  echo ""
done

echo "Verify any bucket with:  wrangler r2 bucket lifecycle list <bucket>"
exit "$rc"
