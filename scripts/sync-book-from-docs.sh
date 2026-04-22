#!/usr/bin/env bash
# Copy canonical docs/ markdown into book/src/ for mdBook (GitHub Pages + local serve).
# dissertation.md and architecture.md stay authoritative in book/src/ — never overwritten here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cp docs/CHUMP_PROJECT_BRIEF.md book/src/project-brief.md
cp docs/EXTERNAL_GOLDEN_PATH.md book/src/getting-started.md
cp docs/OPERATIONS.md book/src/operations.md
cp docs/RUST_INFRASTRUCTURE.md book/src/rust-infrastructure.md
cp docs/METRICS.md book/src/metrics.md
cp docs/CHUMP_TO_COMPLEX.md book/src/chump-to-complex.md
cp docs/ROADMAP.md book/src/roadmap.md
cp docs/research/consciousness-framework-paper.md book/src/research-paper.md
cp docs/research/RESEARCH_COMMUNITY.md book/src/research-community.md
cp docs/RESEARCH_INTEGRITY.md book/src/research-integrity.md
cp docs/OOPS.md book/src/oops.md
