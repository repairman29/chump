# MISSION-122 — closed as duplicate of already-shipped work

**Finding:** all 4 acceptance criteria for MISSION-122 ("Integration test:
auto-size prevents build-storm overload") are already satisfied on `main` by
PR #5222 (commit `e098d95a5`, merged 2026-10-09T23:43Z — before this gap was
claimed), which added `scripts/ci/test-mission-122-build-storm-autosize.sh`:

1. **AC1** — simulates a node with auto-size enabled by sourcing
   `scripts/ops/node-orchestrator.sh` in lib-only mode (no live daemon loop).
2. **AC2** — reproduces the exact 2026-08-22 CJ incident numbers: 14 workers x
   `CARGO_BUILD_JOBS=4` = 56 rustc threads on a 4-core box = 1400%/core load,
   exceeding the prior overload threshold.
3. **AC3** — verifies `enforce_cap()` / `cargo_jobs_cap()` / `scale()` shed
   excess workers down to `effective_max()` (cores-1) and cap build
   parallelism, bringing load back from 1400%/core to 75%/core; also proves
   `scale()` keeps shedding under sustained pressure rather than granting new
   build capacity.
4. **AC4** — control case: a healthy-load run issues no shed/stop, proving
   the test isn't just always failing/always shedding.

Verified green locally in this session: `bash
scripts/ci/test-mission-122-build-storm-autosize.sh` → 11 passed, 0 failed.

No new code needed — this gap is closed as a duplicate rather than
re-implementing the same coverage a second time. Precedent:
RESILIENT-1215/1216 (#5228/#5229) closed the same way for already-shipped
organ-merge/install wiring.
