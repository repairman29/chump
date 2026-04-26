#!/usr/bin/env bash
# Emit verifiable repo stats for product reviews, slide decks, and CI logs.
# Run from repo root. Requires: find, wc, date; for test count: cargo (pre-built test binary is fine).
#
# Usage:
#   ./scripts/print-repo-metrics.sh           # human-readable Markdown block
#   ./scripts/print-repo-metrics.sh --json    # one-line JSON (no jq)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GENERATED_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

RUST_LINES=0
if [[ -n "$(find src -name '*.rs' 2>/dev/null | head -n 1)" ]]; then
  RUST_LINES="$(find src -name '*.rs' -print0 2>/dev/null | xargs -0 wc -l 2>/dev/null | tail -n 1 | awk '{print $1}')"
fi

DOC_COUNT="$(find docs -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')"

TEST_COUNT=0
if command -v cargo >/dev/null 2>&1; then
  # Ensures test binary exists; ok if already built.
  cargo test -p chump --no-run -q 2>/dev/null || true
  if OUT="$(cargo test -p chump -- --list 2>/dev/null)"; then
    TEST_COUNT="$(printf '%s\n' "$OUT" | grep -c ': test$' || true)"
  fi
fi

if [[ "${1:-}" == "--json" ]]; then
  printf '{"generatedUtc":"%s","rustSrcLoc":%s,"rustAgentTests":%s,"docsMarkdownFiles":%s}\n' \
    "$GENERATED_UTC" "$RUST_LINES" "$TEST_COUNT" "$DOC_COUNT"
  exit 0
fi

cat <<EOF
## Repo metrics (machine-generated)

**Do not hand-edit these numbers in reviews** — re-run this script (or copy from CI: **External golden path smoke** prints this block via \`verify-external-golden-path.sh\`).

| Metric | Value |
|--------|-------|
| Generated (UTC) | \`${GENERATED_UTC}\` |
| Rust \`src/**/*.rs\` LOC (\`wc -l\`) | **${RUST_LINES}** |
| \`cargo test -p chump -- --list\` | **${TEST_COUNT}** tests |
| \`docs/**/*.md\` files | **${DOC_COUNT}** |

**Canonical onboarding plan:** [docs/DAILY_DRIVER_95_STEPS.md](docs/DAILY_DRIVER_95_STEPS.md) — **95 steps over ~3 weeks** (not a separate “15-day” plan unless you map days explicitly).

**Cold path / evidence:** [docs/process/EXTERNAL_GOLDEN_PATH.md](docs/process/EXTERNAL_GOLDEN_PATH.md), \`./scripts/verify-external-golden-path.sh\`, [docs/process/ONBOARDING_FRICTION_LOG.md](docs/process/ONBOARDING_FRICTION_LOG.md).

EOF
