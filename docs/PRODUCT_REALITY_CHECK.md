---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Product Reality Check

Honest current-state assessment — what works, what's rough, and where the gaps between vision and reality are largest. See [RED_LETTER.md](RED_LETTER.md) for the adversarial weekly review.

## What works well

**Memory system** — The graph + FTS5 + semantic RRF retrieval is the clearest differentiation. Entity resolution (linking "Alice" to "my coworker Alice"), confidence tracking, and expiry work in production. No comparable open-source agent has this.

**Consciousness framework** — Surprise tracker, neuromodulation, precision controller, and belief state are implemented and A/B-tested. The COG-016 lessons block finding (10.7× noise floor, n=100) is the most rigorous empirical result in the codebase.

**Eval harness** — Property-based A/B testing with Wilson 95% CIs, A/A noise floor calibration, cost ledger, and multi-axis scoring (`did_attempt` / `hallucinated_tools` / `is_correct`) are production-ready. ~1,620 trials run, ~$14 total cost.

**Single Rust binary** — `cargo build --release` produces a self-contained binary with no Python env drift, no `curl | bash` install, no dependency hell. In-process SQLite, embedded FTS5. Starts cold in <1s.

**Provider cascade** — 8 cloud providers (~72k free RPD) with priority-ordered fallthrough. Local model served on 8000 (vLLM-MLX) with automatic Ollama fallback.

**Multi-agent coordination** — Lease files, gap registry, worktree isolation, pre-commit hooks, and the ship pipeline (`bot-merge.sh`) prevent the most common multi-agent failure modes (silent stomps, duplicate work, broken-compile commits landing on main).

## What's rough

**Narrow North Star coverage** — The stated product goal (understanding the user in Discord, acting on intent) has received minimal direct commits. Most recent work concentrated on coordination tooling, crate extraction, and eval infrastructure.

**COG-016 is unpatched in production** — The n=100 A/B finding shows the lessons block unconditionally increases fake tool-call emission by +0.14 on weak models. `reflection_injection_enabled()` in `src/reflection_db.rs:94` defaults ON regardless of model tier. This is an active hallucination amplifier. Fix is P1/effort-M: model-tier predicate + anti-hallucination guard.

**946 `unwrap()` calls** — Unconditional panics across 157 source files. `src/reflection_db.rs` alone has 31. Thread panics on corrupted SQLite rows or missing directories have no recovery path.

**Published benchmarks pending** — `docs/BENCHMARKS.md` has an empty results table. The benchmark script (`scripts/chump-bench.sh`) exists but no results have been committed. The OpenJarvis comparison baseline is unpublished.

**Single-family judge bias** — All 100+ A/B trials used Claude-Sonnet as the sole judge. EVAL-010 showed 38–63% per-trial agreement between two Anthropic judges (at or below chance). Cross-family validation (EVAL-023, P1/S-effort, ~$1.62 cost) has not been run. Every headline delta may be systematically inflated.

**Documentation sprawl** — `docs/` has 66+ files for a codebase whose North Star is a Discord bot. Several high-value docs were stubs until recently. Some files reference conventions that have since changed (e.g., `status: in_progress` in gaps.yaml — that field is gone).

**TDA module is dead code** — `src/tda_blackboard.rs` (310 lines, persistent homology) has no callsites outside the module. Ships in every production binary with no downstream consumers.

## Identity and scope tensions

The project is simultaneously:
1. A Discord bot for intent-driven personal assistance (the stated North Star in `CHUMP_PROJECT_BRIEF.md`)
2. A cognitive architecture research platform (CHUMP_TO_COMPLEX.md)
3. A distributed fleet OS for personal compute nodes (FLEET_ROLES.md, INFERENCE_MESH.md)

These are three different products. Velocity measured against any single definition looks weak because effort is diffused across all three. The `FRONTIER-*` gap backlog (quantum cognition, TDA, autopoiesis, 13 entries) reflects the research platform axis; the `FLEET-*` backlog (mutual supervision, workspace merge, 9 entries) reflects the fleet OS axis. The Discord intent parsing axis has the fewest open gaps — and the least recent commits.

## Priority corrections needed

1. **Rotate the Together.ai key** in `config/config.yaml` (committed in `fba4b11`) — in git history permanently, must be rotated at provider dashboard regardless of file deletion.
2. **Patch COG-016** — model-tier predicate in `reflection_db.rs` to gate lessons injection; estimated single-file, medium-effort change.
3. **Run EVAL-023** — one cross-family n=100 sweep to validate or invalidate every headline delta from the existing A/B results (~$1.62).
4. **Publish benchmarks** — run `scripts/chump-bench.sh` and commit results to `BENCHMARKS.md`.

## See Also

- [RED_LETTER.md](RED_LETTER.md) — weekly adversarial review
- [Roadmap](ROADMAP.md) — operational near-term backlog
- [Benchmarks](BENCHMARKS.md) — measurement methodology
- [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) — full A/B trial chain
- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — cognitive architecture frontier
- [External Golden Path](EXTERNAL_GOLDEN_PATH.md) — first-install experience
- [Onboarding Friction Log](ONBOARDING_FRICTION_LOG.md)
