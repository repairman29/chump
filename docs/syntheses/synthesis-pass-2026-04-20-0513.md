# Synthesis Pass — 2026-04-20

**Generated:** 2026-04-20T05:13:06Z
**Window:** last 6h (first run — no .last-run found)
**Script:** `scripts/dev/synthesis-pass.sh`

> This is an automated data-collection pass. It does NOT call an LLM.
> Use it as a structured briefing before a deep synthesis session, or
> as a lightweight audit trail for the 6h period.

---

## Gaps closed this window

- COMP-005 (2026-04-19): Voice/Vision/Browser — voice mode, image paste, browser automation
- PRODUCT-003 (2026-04-19): User profile system — three-layer identity, context, and learned preferences
- PRODUCT-004 (2026-04-19): FTUE — first-run onboarding conversation that populates the user profile
- PRODUCT-005 (2026-04-19): scripts/eval/generate-sprint-synthesis.sh — automated synthesis generation in heartbeat
- PRODUCT-006 (2026-04-19): harvest-synthesis-lessons.sh — mine synthesis operational rules into lessons layer
- COG-016 (2026-04-19): Model-tier-aware lessons block injection
- EVAL-023 (2026-04-19): Cross-family judge run — break Anthropic-only judge bias
- EVAL-024 (2026-04-19): Multi-turn A/B re-run with v2 multi-axis scoring (compose with PR #73)
- COG-019 (2026-04-19): Context-window compaction for long --chat / --web sessions
- QUALITY-001 (2026-04-19): unwrap() audit — replace panics with graceful errors in production paths
- EVAL-025 (2026-04-19): Validate COG-016 anti-hallucination directive — rerun n=100 cross-family
- EVAL-026 (2026-04-19): Cognitive-layer U-curve at 32B — extend 1B-14B sweep upward
- EVAL-027 (2026-04-19): SAKE knowledge anchoring — apply Feb 2026 KID paper to Chump's lessons + memory
- EVAL-028 (2026-04-19): CatAttack adversarial robustness sweep on Chump fixtures
- EVAL-029 (2026-04-19): Investigate which neuromod tasks drive cross-architecture harm signal
- COG-020 (2026-04-19): DeepMind 10-faculty Chump architecture map — taxonomy alignment doc
- FRONTIER-005 (2026-04-19): goose competitive positioning + Chump differentiation strategy
- COMP-011a (2026-04-20): Adversary-mode-lite — static-rules runtime tool-action monitor
- RESEARCH-001 (2026-04-19): Public research narrative — '2000+ A/B trials' blog post / paper
- EVAL-030 (2026-04-19): Task-class-aware lessons block — fix neuromod harm at its root cause
- COMP-013 (2026-04-19): MCPwned / DNS rebinding mitigation audit on Chump MCP servers
- COMP-014 (2026-04-20): Cost ledger broken across ALL providers — recorded $0.00 across 4621 calls today
- EVAL-035 (2026-04-19): Belief-state ablation A/B — is belief_state.rs net-contributing?
- COG-023 (2026-04-19): Sonnet carve-out from cog016 directive — CONFIRMED at n=100, ship Path A
- INFRA-WORKTREE-REAPER (2026-04-19): Stale-worktree reaper — automate cleanup of merged-branch worktrees
- INFRA-PUSH-LOCK (2026-04-20): Pre-push hook blocks pushes to PRs with auto-merge armed
- INFRA-FILE-LEASE (2026-04-20): File-level path leases on top of gap-level mutex
- INFRA-BOT-MERGE-LOCK (2026-04-20): bot-merge.sh marks worktree shipped; chump-commit.sh refuses to commit after
- COG-024 (2026-04-19): Default lessons-OFF — opt-in per-model only after measurement
- INFRA-DISPATCH-POLICY (2026-04-20): musher dispatch policy — capacity-aware, priority-ordered, dependency-aware
- MEM-006 (2026-04-19): Lessons-loaded-at-spawn — agents inherit prior reflection lessons on start
- INFRA-COST-CEILING (2026-04-20): Per-session cloud spend cap — hard ceiling + soft warn
- INFRA-AGENT-CODEREVIEW (2026-04-20): code-reviewer agent in the loop for src/* PRs before auto-merge
- AUTO-013 (2026-04-19): Chump-orchestrator mode — dogfood meta-loop for self-dispatching
- INFRA-WORKTREE-REAPER-FIX (2026-04-19): stale-worktree-reaper missed long-running background bash — broke EVAL-026c sweep
- INFRA-BOT-MERGE-UNTRACKED (2026-04-20): bot-merge.sh pushes wrong diff when untracked files present in worktree
- INFRA-CHUMP-API-RETRY (2026-04-19): Spawned claude subprocess needs API-5xx retry wrapper
- INFRA-DISPATCH-FAULT-INJECTION (2026-04-20): Fault-injection test mode for chump-orchestrator dispatch
- INFRA-DISPATCH-PERMISSIONS-FLAG (2026-04-19): Spawned claude subagent stalls on permission prompts — pass --dangerously-skip-permissions
- COG-025 (2026-04-19): Dispatch-backend pluggability — route orchestrator subagents via Together (free tier)
- INFRA-GAPS-DEDUP (2026-04-20): Fix gap registry ID collision — 7 duplicate ID pairs
- RESEARCH-002 (2026-04-20): Docs thesis reframe — align all docs to tier-dependent injection finding
- MEM-009 (2026-04-20): Reflection episode quality filtering before spawn-load
- INFRA-AMBIENT-STREAM-SCALE (2026-04-20): Ambient stream retention policy + query performance at fleet scale

---

## Merged PRs this window

PR #215 [worktree-agent-a6f26571] feat(EVAL-042): cross-family judge re-run — reflection kappa=0.72 ≥ 0.70; neuromod/perception unconfirmed (kappa 0.42/0.50) — merged 2026-04-20T05:10:23Z by repairman29
PR #214 [worktree-agent-a3c5da6f] feat(MEM-010): entity resolution A/B test set, accuracy test, and results — merged 2026-04-20T05:08:40Z by repairman29
PR #213 [claude/COMP-008] chore(gaps): close 11 shipped gaps (INFRA-FILE-LEASE + PRs #136, #186, #191, #201-203, #205-206, #210-211) — merged 2026-04-20T05:11:16Z by repairman29
PR #212 [worktree-agent-ac3d2b09] feat(COG-027): task-class-aware perception clarify-directive gate — merged 2026-04-20T05:06:45Z by repairman29
PR #211 [worktree-agent-a5ad040d] feat(EVAL-044): multi-turn eval fixture design — 10-turn debug scenario with coherence + belief-drift rubrics — merged 2026-04-20T04:43:27Z by repairman29
PR #210 [worktree-agent-a7509405] feat(EVAL-043): ablation suite infra — bypass flags for belief_state, surprisal EMA, neuromod — merged 2026-04-20T04:46:02Z by repairman29
PR #209 [claude/v8-rooftop] docs(COG-031): V8 result — few-shot exemplar broke chat-default; Qwen3-Coder shipped 2 real commits — merged 2026-04-20T04:31:23Z by repairman29
PR #208 [claude/COMP-008] chore(gaps): close INFRA-DISPATCH-FAULT-INJECTION (PR #188) — merged 2026-04-20T04:32:33Z by repairman29
PR #207 [worktree-agent-ae3659e6] feat(EVAL-035): --bypass-belief-state flag + ablation eval doc — merged 2026-04-20T04:25:13Z by repairman29
PR #206 [worktree-agent-af06a6ce] feat(EVAL-032): CHUMP_BYPASS_PERCEPTION ablation flag + perception eval spec — merged 2026-04-20T04:22:25Z by repairman29
PR #205 [worktree-agent-a52621db] feat(EVAL-038): ambiguous-prompt A/B fixture + methodology for Social Cognition faculty — merged 2026-04-20T04:20:15Z by repairman29
PR #204 [claude/COMP-008] chore(gaps): close 5 shipped gaps (PRs #187, #193, #195-198) — merged 2026-04-20T04:03:27Z by repairman29
PR #203 [worktree-agent-aeef9daf] feat(COMP-010): Homebrew formula + install docs — merged 2026-04-20T04:00:57Z by repairman29
PR #202 [worktree-agent-a84f4ef9] docs(MEM-008): multi-hop QA fixture spec — three categories, 15 pilot questions — merged 2026-04-20T04:00:26Z by repairman29
PR #201 [worktree-agent-a4659bd6] fix(INFRA-CODEREVIEWER-FALSE-POSITIVES): workspace dep pre-check before flagging new Cargo.toml deps — merged 2026-04-20T04:28:13Z by repairman29
PR #200 [claude/gaps-close-2026-04-20b] chore(gaps): close INFRA-AMBIENT-STREAM-SCALE, MEM-009, INFRA-DISPATCH-POLICY — merged 2026-04-20T03:41:20Z by repairman29
PR #199 [claude/fix-ci-blocking-tests] fix(ci): unblock all PRs — sandbox git config + postconditions path — merged 2026-04-20T03:39:01Z by repairman29
PR #198 [worktree-agent-a21ec4bc] feat(INFRA-DISPATCH-POLICY): pick_gap policy + chump --pick-gap CLI — merged 2026-04-20T03:25:51Z by repairman29
PR #197 [claude/cog031-step2] feat(COG-031): step 1 — static model-shape overlay for dispatched chump-local runs — merged 2026-04-20T03:19:54Z by repairman29
PR #196 [worktree-agent-a846458b] feat(MEM-009): quality-threshold filter for load_spawn_lessons — merged 2026-04-20T03:12:41Z by repairman29
PR #195 [worktree-agent-a62da101] feat(INFRA-AMBIENT-STREAM-SCALE): ambient stream retention + query helpers — merged 2026-04-20T03:09:33Z by repairman29
PR #194 [claude/cog031-step1-result] docs(COG-031): step 1 negative result — overlay loses to instruct-tuning prior — merged 2026-04-20T03:07:53Z by repairman29
PR #193 [worktree-agent-abf7bee7] feat(COMP-011a): adversary rule engine — pre-execution tool call filtering — merged 2026-04-20T03:52:10Z by repairman29
PR #192 [worktree-agent-a29064b0] feat(INFRA-FILE-LEASE): --paths in gap-claim.sh + advisory path-lease check in chump-commit.sh — merged 2026-04-20T02:49:08Z by repairman29
PR #191 [worktree-agent-a163770e] feat(INFRA-AGENT-ESCALATION): agent escalation via ambient stream — merged 2026-04-20T04:00:08Z by repairman29
PR #189 [worktree-agent-a0fbf0eb] chore(gaps): mark INFRA-AGENT-CODEREVIEW done (shipped PR #135) — merged 2026-04-20T02:10:58Z by repairman29
PR #188 [worktree-agent-a1494adb] feat(INFRA-DISPATCH-FAULT-INJECTION): fault-injection test mode for dispatch/monitor paths — merged 2026-04-20T02:03:39Z by repairman29
PR #187 [worktree-agent-a71ad7eb] feat(INFRA-COST-CEILING): per-session cloud spend cap — hard ceiling + soft warn — merged 2026-04-20T02:05:05Z by repairman29
PR #186 [claude/cog026-v5-update] docs(COG-026): final result — V5 (Qwen3-Coder-480B) confirms post-training-shape isn't the lever — merged 2026-04-20T01:58:18Z by repairman29
PR #185 [claude/cog031-autotuner] chore(gaps): file COG-031 — model-shape autotuner ("ship on whatever LLM you have") — merged 2026-04-20T01:53:25Z by repairman29

---

## Recent commits

```
814455e chore(gaps): close COG-027 (PR #212)
6566d78 chore(gaps): close 10 shipped gaps (PRs #136, #186, #191, #201-203, #205-206, #210-211)
afc827a chore(gaps): close INFRA-FILE-LEASE (PR #192)
23a6bc6 feat(EVAL-043): ablation suite infra — bypass flags for belief_state, surprisal EMA, neuromod (#210)
f54183e feat(EVAL-044): multi-turn eval fixture design — 10-turn debug scenario with coherence + belief-drift rubrics (#211)
d909624 chore(gaps): close INFRA-DISPATCH-FAULT-INJECTION (PR #188) (#208)
cd02572 docs(COG-031): V8 result — few-shot exemplar broke chat-default; Qwen3-Coder shipped 2 real commits (#209)
94d1a6e fix(INFRA-CODEREVIEWER-FALSE-POSITIVES): workspace dep pre-check before flagging new Cargo.toml deps (#201)
26f223b feat(EVAL-035): --bypass-belief-state flag + ablation eval doc (#207)
252fcc5 feat(EVAL-032): CHUMP_BYPASS_PERCEPTION flag + perception ablation eval spec (#206)
f8e4e30 feat(EVAL-038): ambiguous-prompt A/B fixture + methodology for Social Cognition faculty (#205)
a8dafc1 chore(gaps): close 5 shipped gaps (PRs #187, #193, #195-198) (#204)
3556db2 feat(COMP-010): Homebrew formula + install docs (#203)
405078a docs(MEM-008): multi-hop QA fixture spec — three categories, 15 pilot questions (#202)
6cd45ee feat(INFRA-AGENT-ESCALATION): agent escalation via ambient stream (#191)
9bbe7d7 feat(COMP-011a): adversary rule engine — pre-execution tool call filtering (#193)
42bfb50 chore(gaps): close 3 gaps shipped 2026-04-20 (PRs #195-196, #198) (#200)
6915933 fix(ci): sandbox test needs git user config; postconditions test needs CHUMP_REPO set (#199)
b16f40e feat(INFRA-DISPATCH-POLICY): pick_gap policy + chump --pick-gap CLI (#198)
51318e5 feat(COG-031): step 1 — static model-shape overlay for dispatched chump-local runs (#197)
3c34039 feat(MEM-009): quality-threshold filter for load_spawn_lessons (#196)
8d85cd7 feat(INFRA-AMBIENT-STREAM-SCALE): ambient stream retention + query helpers (#195)
af8a638 docs(COG-031): step 1 negative result — overlay loses to instruct-tuning prior (#194)
0faf333 feat(INFRA-FILE-LEASE): --paths in gap-claim.sh + advisory path-lease check in chump-commit.sh (#192)
b7b2f2f chore(gaps): mark INFRA-AGENT-CODEREVIEW done (shipped PR #135) (#189)
95e0e76 feat(INFRA-COST-CEILING): per-session cloud spend cap — hard ceiling + soft warn (#187)
ee8cd7b feat(INFRA-DISPATCH-FAULT-INJECTION): fault-injection test mode for dispatch/monitor paths (#188)
45b19e7 docs(COG-026): final result — V5 (Qwen3-Coder-480B) confirms post-training-shape isn't the lever (#186)
4f05ffd chore(gaps): file COG-031 — model-shape autotuner ("ship on whatever LLM you have") (#185)
f0dd134 chore(gaps): fix 7 duplicate IDs (EVAL-003/COG-007-011/MEM-003 → next available) + close 6 gaps shipped 2026-04-20 (#184)
accc6aa fix(COMP-014): cost ledger $0.00 bug — Together free-tier gate + full pricing table (#183)
f71a7cb docs(COG-026): interim Together-dispatch finding + queue Qwen2.5-Coder V5 (#182)
cec8b38 feat(INFRA-BOT-MERGE-UNTRACKED): abort bot-merge when untracked source files present (#181)
e47c38d feat(INFRA-BOT-MERGE-LOCK): write .bot-merge-shipped on ship; guard in chump-commit.sh (#180)
6f507b3 fix(INFRA-GAPS-DEDUP): resolve 7 duplicate gap IDs + add dedup guard to pre-commit (#176)
cf36d58 feat(INFRA-PUSH-LOCK): reject pushes to branches with auto-merge armed (#179)
f3df6a9 chore(INFRA-CHUMP-API-RETRY): mark gap done — shipped in PR #164 (#177)
b9b7dbc fix(COG-027): bump dispatched-agent max-iter via CHUMP_AGENT_MAX_ITER env (#178)
7bfe555 docs(RESEARCH-002): align research docs with accurate tier-dependent injection thesis (#175)
b3dacad feat(INFRA-AGENT-RULES-INJECT): inject CHUMP_DISPATCH_RULES.md into all autonomous agent prompts (#174)
```

---

## Ambient stream events

(no ALERT events in window)

---

## Gap registry snapshot

- Open gaps: **26**
- Done gaps: **181**

To see open gaps: `grep -A5 'status: open' docs/gaps.yaml | head -80`

---

## Next steps for a human or agent reading this

1. Review any ALERT events above — they indicate coordination issues requiring action.
2. Check the closed gaps for follow-up work (new gaps filed? acceptance partially met?).
3. Read the merged PRs to identify any strategic doc updates needed (FACULTY_MAP, RESEARCH_PLAN, etc.).
4. If significant findings landed, consider writing a full session synthesis using `scripts/eval/generate-sprint-synthesis.sh`.

---

_Next scheduled run: approximately 2026-04-20T05:13:06Z + 6h via `launchd/com.chump.synthesis-pass.plist`_

