#!/usr/bin/env bash
# scripts/ci/test-r2-sccache-lifecycle.sh — INFRA-2450
#
# Structural smoke for the R2 sccache lifecycle policy + cost-model doc.
# Can't exercise wrangler itself (needs Cloudflare auth, not available in CI),
# so it asserts the invariants that make the policy correct + discoverable.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
S=scripts/ops/r2-sccache-lifecycle.sh
D=docs/process/SCCACHE_R2_CACHE.md
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-r2-sccache-lifecycle.sh (INFRA-2450) ==="

[[ -f "$S" ]] && p "ops script present" || f "ops script MISSING ($S)"
[[ -x "$S" ]] && p "ops script executable" || f "ops script not executable"
grep -q -- '--expire-days' "$S" 2>/dev/null && p "applies object expiry (--expire-days)" || f "no --expire-days in script"
grep -q -- '--abort-multipart-days' "$S" 2>/dev/null && p "aborts incomplete multipart uploads" || f "no --abort-multipart-days"
grep -qF 'chump-sccache chump-sccache-ci' "$S" 2>/dev/null && p "covers BOTH buckets by default" || f "default bucket list isn't both buckets"
grep -qiE 'wrangler login|whoami' "$S" 2>/dev/null && p "auth preflight present (whoami/login)" || f "no wrangler auth check"

grep -q 'Cost model + eviction' "$D" 2>/dev/null && p "doc has 'Cost model + eviction' section" || f "doc missing cost-model section"
{ grep -q '0.015' "$D" && grep -q '4.50' "$D"; } 2>/dev/null && p "doc carries pricing rates (storage + Class A)" || f "doc missing pricing rates"
grep -q 'r2-sccache-lifecycle.sh' "$D" 2>/dev/null && p "doc references the apply script" || f "doc doesn't reference the script"

echo ""
echo "=== $P passed, $F failed ==="
[[ "$F" -eq 0 ]] || exit 1
