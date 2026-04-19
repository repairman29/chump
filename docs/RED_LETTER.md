# Red Letter

> Cold Water — adversarial weekly review. No praise.

---

## Issue #1 — 2026-04-19

### The Looming Ghost

We are failing at basic secrets hygiene. Commit `fba4b11` ("Add config/config.yaml") added `config/config.yaml` to version control — a file that contains a live Together.ai API key: `tgp_v1_Z_OJykKz-DGyKlp9lCPiX6hhVmwNLz8-p6nrWuhN1ik`. That key is now in git history permanently, visible to every collaborator, CI runner, and future auditor with read access to this repo. `config/` is not in `.gitignore`. The ANTHROPIC_API_KEY appeared in `config/prod.yaml` across four separate commits (`86cc884`, `e618bb0`, `cf05ce5`, `62db274`) by the same `Your Name <you@example.com>` actor — an unidentified non-bot agent operating entirely outside the coordination system, bypassing every pre-commit hook.

We are failing at production safety. The lessons block in `src/reflection_db.rs:94` (`reflection_injection_enabled()`) is gated only by an env flag that defaults ON. The documented finding from the n=100 A/B sweep is that unconditional injection increases fake tool-call emission by +0.14 mean — 10.7× the A/A noise floor. Gap COG-016 (P1, effort M) names the exact fix — a model-tier predicate in `reflection_db.rs` and an anti-hallucination guard in the injected lessons block — and it has been sitting unstarted since it was filed. We are actively shipping a hallucination amplifier to every production session that runs on a weak model.

We are failing at Rust reliability. There are 946 `unwrap()` calls across 157 source files. `src/reflection_db.rs` alone has 31. These are unconditional panics in production code running against a SQLite database. A corrupted row, a missing `sessions/` directory, or an unexpected NULL triggers a thread panic with no recovery path.

### The Opportunity Cost

We are failing to act on our own findings. EVAL-023 — "Cross-family judge run — break Anthropic-only judge bias" — is P1, effort S, and has been open since `d6c389d` (filed 2026-04-17). Every insight from the 100+ completed A/B trials (COG-001 through EVAL-022) used claude-sonnet as the sole judge. EVAL-010 already showed 38–63% per-trial agreement between two Anthropic judges — at or below chance. Every headline delta (+0.14, +0.12, -0.30 on gotchas) may be systematically inflated by single-family judge autocorrelation. We have not run a single cross-family validation. The A/B harness already supports Ollama judges (`--judges` flag, PR #83). The cost of one cross-family n=100 sweep is ~$1.62. We have not done it.

We are failing to close our own housekeeping. COMP-005 ("Voice/Vision/Browser") carries `status: open` even though every sub-gap (`COMP-005a`, `COMP-005a-fe`, `COMP-005b`, `COMP-005c`) shipped. The parent gap is an orphaned tracker entry that misleads the coordination tooling and pollutes the open-gap list.

We are failing to close the North Star gap. `docs/CHUMP_PROJECT_BRIEF.md` defines the North Star as "understanding the user in Discord and acting on intent." Zero commits this week addressed Discord intent parsing. Instead, 50 commits landed — of which 11 were Cargo.lock repairs, 7 were crate extraction PRs, and 5 were coordination tooling additions. The stated product goal advanced zero points.

### The Complexity Trap

We are failing to justify the TDA module. `src/tda_blackboard.rs` is 310 lines implementing persistent homology on blackboard traffic (FRONTIER-002). Its only entry in `src/main.rs` is a `mod tda_blackboard;` declaration. There are no callsites outside the module. It has no downstream consumers in the agent loop, no A/B result, no eval fixture. It is dead weight shipping in every production binary.

We are failing to recognize when coordination infrastructure has become the product. The multi-agent coordination system now includes: `musher.sh` (574 lines), `war-room.sh`, `broadcast.sh`, `gap-preflight.sh`, `gap-claim.sh`, `bot-merge.sh`, `worktree-prune.sh`, `stale-pr-reaper.sh`, `cost_ledger.py`, the five-job pre-commit hook, and `ambient.jsonl` peripheral vision. The ambient stream collected exactly **one event** in the most recent observable period: a single `session_start`. The peripheral vision system for which FLEET-004a through FLEET-004d were filed, and which consumes CLAUDE.md space in every session preamble, is detecting nothing because there is nothing to detect. The coordination system is built for a fleet scale that does not currently exist. Its maintenance cost is real; its product value is theoretical.

We are failing to contain documentation sprawl. The `docs/` directory has 66 files. `docs/SESSION_2026-04-18_SYNTHESIS.md` exists as a permanent artifact. So do `MARKET_RESEARCH_EVIDENCE_LOG.md`, `NEUROMODULATION_HEURISTICS.md`, `MISTRALRS_CAPABILITY_MATRIX.md`, and `MISTRALRS_BENCHMARKS.md` — for an upstream `REL-002` that is blocked with no ETA. Sixty-six docs files for a codebase whose North Star is a Discord chatbot is a surface area problem, not a knowledge management success.

### The Reality Check

We are failing to ship against our own priority stack. The three remaining open gaps are: COMP-005 (a stale tracker entry), COG-016 (P1 production harm, unstarted), and EVAL-023 (P1 eval validity, unstarted). Both P1 gaps are M/S effort — one is a single-file Rust change. They have been open for at least two days each. Meanwhile this week's commits included three separate Cargo.lock repair commits (`6cd96d3`, `4652612`, `304c07c`) and a "Fixed Cargo.lock" commit that is itself a symptom of the multi-agent push protocol failing.

We are failing at identity coherence. `docs/CHUMP_PROJECT_BRIEF.md` says the project is a Discord bot that understands intent. `docs/CHUMP_TO_COMPLEX.md` describes it as a cognitive architecture research platform. The gaps registry has 13 FRONTIER-* entries (quantum cognition, TDA, autopoiesis), 9 FLEET-* entries (mutual supervision, workspace merge), and an active push to publish 10 crates to crates.io. These are three different products. Velocity measured against any one definition looks weak because the effort is diffused across all three simultaneously.

We are failing to enforce the `"Your Name <you@example.com>"` actor boundary. Thirteen commits on main this week originated from that identity — outside the coordination system, with no gap IDs, no pre-commit hooks, and no lease files. Commits `bb56775` ("Write SQL"), `7ded18b` ("Propose schema changes"), `b226514` ("Added architecture.md") reference paths like `repos/chump/` and `repos/chump/wiki/` that do not exist in the repository root. This is a foreign agent or a human operating without the project's own rules applied to them. The CLAUDE.md coordination contract is not actually being enforced on all writers.

**THE ONE BIG THING:** A live Together.ai API key (`tgp_v1_Z_OJykKz-DGyKlp9lCPiX6hhVmwNLz8-p6nrWuhN1ik`) is permanently committed to `config/config.yaml` (commit `fba4b11`) and will remain in git history even if the file is deleted today. This key must be rotated immediately at the Together.ai dashboard. Beyond the immediate credential, `config/` is not in `.gitignore`, four ANTHROPIC_API_KEY writes hit `config/prod.yaml` history across one day, and the committer (`Your Name <you@example.com>`) is an unidentified actor who bypassed every coordination guard this project has built. The combination of a credential-leaking foreign actor operating unchecked on main, a production hallucination amplifier (COG-016) sitting unpatched at P1, and 946 `unwrap()` calls in the Rust binary means the project's security posture, AI safety posture, and reliability posture are simultaneously unacceptable.

---
