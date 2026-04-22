# Chump project brief

Used with the published Roadmap chapter (`./roadmap.md`). Canonical doc index: [`docs/README.md`](https://github.com/repairman29/chump/blob/main/docs/README.md). Read by the self-improve heartbeat (work, opportunity, cursor_improve, sprint_synthesis), the Discord bot, and Claude agents to stay focused. The roadmap holds prioritized goals and unchecked items; this brief holds conventions and current focus.

**Read [`docs/NORTH_STAR.md`](https://github.com/repairman29/chump/blob/main/docs/NORTH_STAR.md) first.** It is the founder's statement — the thing every decision is measured against. This brief and the roadmap are subordinate to it.

## Current focus

- **North star:** Build the gold standard autonomous agent framework in Rust — local-first, air-gapped capable, runs on consumer hardware without frontier models. The cognitive architecture (surprise tracking, belief state, neuromodulation, precision weighting, memory graphs) is the mechanism that makes autonomy real. The near-term product target is a first-run experience: one command → PWA → model selection → MCP marketplace → goal-setting with the user. See [`docs/NORTH_STAR.md`](https://github.com/repairman29/chump/blob/main/docs/NORTH_STAR.md) for the full vision.
- **Roadmap:** Read the published Roadmap chapter (`./roadmap.md`) for what to work on. Pick from unchecked items, the task queue, or codebase scans (TODOs, clippy, tests). Do not invent your own roadmap. At the start of work, opportunity, and cursor_improve rounds, read `./roadmap.md` and this brief so choices align with current focus and conventions.
- **Discord intent:** Infer user intent from natural language; take action (task create, run_cli, memory store, etc.) when clear; only ask when genuinely ambiguous. See [`docs/INTENT_ACTION_PATTERNS.md`](https://github.com/repairman29/chump/blob/main/docs/INTENT_ACTION_PATTERNS.md) for intent→action examples.
- Add or update tasks in Discord: "Create a task: …" — Chump picks them up in the next heartbeat round.
- **GitHub integration (optional):** Add a repo to `CHUMP_GITHUB_REPOS` and set `GITHUB_TOKEN` (see `.env.example`). The bot can then push branches and open PRs autonomously.
- **Push and self-reboot:** To have the bot push to the Chump repo and restart with new capabilities: add the repo to `CHUMP_GITHUB_REPOS`, set `GITHUB_TOKEN`, set `CHUMP_AUTO_PUSH=1`. After pushing bot-affecting changes, the bot may run `scripts/self-reboot.sh` (or the user can say "reboot yourself"). See the Roadmap chapter (`./roadmap.md`) section “Push to Chump repo and self-reboot”.
- **Roles should be running:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender (navbar app → Roles tab). Schedule them with launchd/cron for 24/7 help; see the Operations chapter (`./operations.md`).
- **Fleet symbiosis:** Mutual supervision, single report, hybrid inference, peer_sync loop, Mabel self-heal — see ROADMAP "Fleet / Mabel–Chump symbiosis".

## Cognitive architecture research

Chump runs nine cognitive modules in the agent loop: surprise tracker, belief state, blackboard/global workspace, neuromodulation, precision controller, memory graph, counterfactual reasoning, phi proxy, and holographic workspace. **These are under active empirical study** — not verified improvements. See the Research integrity chapter (`./research-integrity.md`) before citing results.

**Validated finding (cite freely):** Instruction injection at inference time has tier-dependent effects. The lessons block improves task performance on haiku-4-5 (reflection fixture, EVAL-025, n=100, cross-family judge), but actively harms sonnet-4-5 (+0.33 hallucination rate, EVAL-027c, n=100). The harm mechanisms are diagnosable: conditional-chain dilution and trivial-token contamination (EVAL-030).

**Individual modules are not yet validated (do not claim otherwise):**
- **Surprisal EMA:** EVAL-011..015 show deltas ≈ 0 on qwen2.5:7b and −0.10 to −0.30 on second-LLM rescore. Marked preliminary pending EVAL-043 (ablation).
- **Neuromodulation:** EVAL-029 shows net-negative cross-architecture signal (−0.10 to −0.16 mean delta). Task-class-aware gating (EVAL-030) is shipped but not yet cross-validated.
- **Belief state:** No isolation eval exists. EVAL-035 is the planned ablation.
- **Broader architecture:** "Cognitive architecture is validated" is a prohibited claim until EVAL-043 (full ablation suite) ships.

Key infrastructure findings:
- **Scaffolding U-curve** (1B–14B local models): 1B/14B benefit from scaffolding (+10pp), 3B/7B are hurt (−5pp), 8B is neutral. Larger models (32B/70B) untested.
- **Lessons block / hallucination channel**: Pre-fix lessons block increased fake tool-call emission by +0.14 mean — 10.7× the A/A noise floor. **COG-016 (PR #114) shipped the fix** — model-tier gate + anti-hallucination directive. EVAL-025 validated the fix at haiku-4-5: delta dropped to −0.003 mean. The harm channel is closed for haiku-4-5 in production; sonnet-4-5 required a separate carve-out (COG-023).

See the Research integrity chapter (`./research-integrity.md`) for the full accuracy policy, the Chump-to-Champ roadmap chapter (`./chump-to-complex.md`) for the architecture vision, and [`docs/CONSCIOUSNESS_AB_RESULTS.md`](https://github.com/repairman29/chump/blob/main/docs/CONSCIOUSNESS_AB_RESULTS.md) for raw A/B data.

## Conventions

- **Git branches:** `claude/<codename>` or `chump/<codename>`. PRs into main; never push directly to main.
- **Commits:** Use `scripts/chump-commit.sh <files> -m "msg"` (not raw `git add && git commit`) to avoid cross-agent staging drift.
- **Tests:** New behavior → test. Config/ops change → doc.
- **PR descriptions and handoff summaries** (to Chump or another agent) should be clear: what changed, outcome, and suggested next steps.
- **Roadmap edits:** Change `- [ ]` to `- [x]` when an item is done. Do not add new items without checking gaps.yaml for an existing gap ID.
