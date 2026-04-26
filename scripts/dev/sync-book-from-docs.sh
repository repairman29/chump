#!/usr/bin/env bash
# Copy canonical docs/ markdown into book/src/ for mdBook (GitHub Pages + local serve).
# dissertation.md and architecture.md stay authoritative in book/src/ — never overwritten here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

cp docs/briefs/CHUMP_PROJECT_BRIEF.md book/src/project-brief.md
cp docs/process/EXTERNAL_GOLDEN_PATH.md book/src/getting-started.md
cp docs/operations/OPERATIONS.md book/src/operations.md
cp docs/architecture/RUST_INFRASTRUCTURE.md book/src/rust-infrastructure.md
cp docs/operations/METRICS.md book/src/metrics.md
cp docs/strategy/CHUMP_TO_CHAMP.md book/src/chump-to-champ.md
cp docs/strategy/ROADMAP.md book/src/roadmap.md
cp docs/research/consciousness-framework-paper.md book/src/research-paper.md
cp docs/research/RESEARCH_COMMUNITY.md book/src/research-community.md
cp docs/process/RESEARCH_INTEGRITY.md book/src/research-integrity.md
cp docs/operations/OOPS.md book/src/oops.md
