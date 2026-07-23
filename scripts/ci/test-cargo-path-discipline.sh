#!/usr/bin/env bash
# INFRA-2099: cargo-path-discipline gate. Fails if any scripts/ci/test-*.sh
# references a hardcoded $ROOT/target (or ${ROOT}/target) path.
#
# Mirror of INFRA-2096 keystone fix: scripts must resolve the target
# directory via `cargo metadata --no-deps --format-version 1` with
# env+default fallback rather than baking in $ROOT/target. This guard
# prevents the same path-bug class from re-emerging when new test
# scripts are added.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

bad=0
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"
    echo "  FAIL: $file:$lineno — hardcoded \$ROOT/target reference: $content" >&2
    bad=$((bad + 1))
done < <(grep -rEn '\$ROOT/target|\$\{ROOT\}/target' scripts/ci/test-*.sh 2>/dev/null || true)

# Also catch the REPO_ROOT variant since most scripts use $REPO_ROOT.
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"
    echo "  FAIL: $file:$lineno — hardcoded \$REPO_ROOT/target reference (must use cargo metadata): $content" >&2
    bad=$((bad + 1))
done < <(grep -rEn '\$REPO_ROOT/target|\$\{REPO_ROOT\}/target' scripts/ci/test-*.sh 2>/dev/null || true)

if [[ "$bad" -gt 0 ]]; then
    echo "INFRA-2099 cargo-path-discipline: $bad hardcoded \$ROOT/target (or \$REPO_ROOT/target) reference(s) in scripts/ci/test-*.sh" >&2
    echo "  Migrate to: cargo metadata --no-deps --format-version 1 | jq -r .target_directory" >&2
    echo "  with env+default fallback (\${CARGO_TARGET_DIR:-\$ROOT/target})." >&2
    echo "  See scripts/ci/test-mcp-coord-smoke.sh (INFRA-2096) for the reference." >&2
    exit 1
fi

echo "ok: INFRA-2099 cargo-path-discipline — no hardcoded \$ROOT/target (or \$REPO_ROOT/target) in scripts/ci/test-*.sh"
