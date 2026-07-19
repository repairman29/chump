# Chump — Codebase Reality Map

> **Purpose.** A reading guide for any agent (Claude Code, opencode, codex, human)
> trying to understand *what this repo actually is* without re-scanning 255K LOC of
> Rust + 1,900 shell scripts. It is the honest, cross-cutting counterpart to the
> auto-generated inventories:
> - `docs/HIDDEN_GEMS.md` — evangelist feature showcase (the "sum of parts").
> - `docs/CAPABILITIES_REGISTRY.json` — machine CLI dump.
> - `docs/architecture/ARCHITECTURE.md` — the component architecture.
>
> This doc is the **"more than the sum of the parts"** view plus the **credibility
> discipline** needed to read the codebase without being fooled by it.
>
> Produced 2026-07-05 via 8 parallel capability scans + a negative-space sweep.
> Refresh with the same method (see *Provenance*) when the shape changes materially.

---

## 0. Read this first: the credibility discipline

**Chump systematically describes itself as more finished than it is.** Nearly every
module carries an `INFRA-NNNN`/`CREDIBLE-NNNN` comment and a `scripts/ci/test-*.sh`
sibling, which makes automated scans (and reviewers) grade it "REAL & load-bearing."
But the code's *self-description overstates its verified behavior.* Documented, in this repo's own history:

- Fleet metrics have lied by large factors (a lease/worker counter reported ~189 vs
  ~1 real; a ship-count reported ~78 vs ~2 real merges). See `CREDIBLE-146`/`149`.
- The fleet has gone **silently dark for days** while every dashboard read "healthy"
  (stale-cache auth false-negative; see `docs/process/REALITY_CHECK.md`).
- The flagship external-repo loop has **not met its own exit bar** (≥3 merged PRs in
  one overnight `chump improve` run) despite the code being "shipped."

**Rule for future agents:** treat "the code exists + has a gap ID" as *evidence of
intent*, not *evidence of working value*. Before you rely on any capability, verify
the **outcome** it should produce against ground truth — this is the `signal ≠ outcome`
doctrine (`CREDIBLE-090`, `scripts/dev/reality-check.sh`). Discount maturity claims,
including the "maturity" columns below, accordingly.

---

## 1. What Chump is (the one-line thesis)

Under the devtool surface, Chump is **one opinionated stack: a sovereign,
offline-first, self-hosted fleet of autonomous coding agents that build and maintain
software with no human in the loop.** Every layer independently chose the same DNA —
files as the authority (not the cloud), a local-LLM cascade (not API-only), SQLite
everywhere, YAML-primary registries (no vendor lock-in), and graceful degradation at
every boundary. That coherence is the product worth more than the sum: it serves the
market cloud agent-SaaS *cannot* (air-gapped, regulated, cost-constrained, sovereignty-
constrained). Aligns with `docs/MISSION.md` and `docs/OFFLINE_FIRST_WORKFLOW.md`.

---

## 2. The capability map (where the value lives)

Eight capability areas, each a plausible standalone product. **Maturity is the code's
own claim — apply §0.** "Extractable" = how cleanly it could leave the monolith today.

| Layer | Lives in | Standalone thesis / closest analog | Extractable |
|---|---|---|---|
| **Multi-agent coordination** | `crates/chump-coord`, `chump-agent-lease` (published), `chump-orchestrator`, `atomic_claim.rs` | Distributed agent-fleet substrate (atomic claims, event bus, work queue, consensus vote) — *Step Functions+SQS+EventBridge / Consul, for agents*. Novel **dual-authority** design (files authoritative, NATS optional). | `chump-agent-lease` ✅ clean; `chump-coord` ✅ (opt NATS); orchestrator ⚠️ |
| **LLM infrastructure** | `provider_cascade.rs`, `local_openai.rs`, `provider_bandit.rs`, `crates/chump-cost-tracker`, `chump-mcp-lifecycle`, `mcp-servers/*`, `tool_normalize.rs` | Free-tier-maximizing **LLM gateway + cost governor** (9-provider cascade, bandit routing, hard cost ceiling, weak-model JSON repair, local fallback) — *OpenRouter / LiteLLM / Helicone*. | `cost-tracker`, `bandit`, `tool_normalize`, `mcp-lifecycle` ✅ publishable |
| **AI-native work/planning** | `crates/chump-gap-store` (clean), `crates/chump-planner` (clean), `docs/gaps/*.yaml` (1,171), gap CLI in `main.rs` | **Agent-native issue tracker** — YAML-primary + SQLite shadow, LLM decomposition in-process, agent routing fields (`required_model`, `preferred_backend`, `skills_required`) — *Linear/Jira, but agent-native*. | store + planner ✅ clean; CLI ❌ welded into `main.rs` |
| **Autonomous CI / ship firewall** | `preflight.rs`, `crates/chump-ship`, `chump-git-hooks`, `scripts/coord/bot-merge.sh`, trunk-sentinel | **Autonomy-grade ship firewall** — local CI mirror (<60s), auto-merge, flake classifier, **red-trunk self-fixer** (no off-the-shelf analog), off-rails claim enforcement — *Trunk.io / Mergify / GH merge queue*. | `preflight`, `chump-ship`, `chump-git-hooks` ✅; bot-merge ⚠️ shell hub |
| **Agent memory & learning** | `memory_db.rs`, `reflection_db.rs`, `memory_graph.rs`, `durable_execution*.rs`, `crates/chump-perception` | **Agent memory + reflection + durable-execution** — GEPA typed reflection, HippoRAG-style graph recall, Temporal-lite crash-replay — *Mem0 / Letta / Temporal / LangGraph checkpointing*. | memory/reflection/durable ✅ clean; integration layer ⚠️ |
| **Observability / fleet telemetry** | `ambient.jsonl` + `EVENT_REGISTRY.yaml` (bidirectional CI-enforced), `waste_tally.rs`, `kpi_report.rs`, `fleet_health.rs`, `floor_temp.rs`, `crates/chump-github-cache` | Self-hosted **"Datadog for agent fleets"** with a rare **cost-governance + waste-taxonomy** angle — *Helicone / Langfuse / Datadog*. **But see §0 — several counters over-report.** | events/waste/cost ✅; detectors + health ⚠️ tangled |
| **Developer surfaces** | `acp_server.rs` (ACP, a *required* CI gate), `web_server.rs` (PWA, 10K-line god-file), `crates/chump-fleet-server`, `chump-mode`, `inspect_cmd.rs`, `slack.rs` | **ACP-native, self-hosted coding-agent backend** (plugs into Zed/JetBrains/VS Code) + operator cockpit — *Cursor / Copilot, but open + local + ACP-standard*. | `acp_server` ✅; `chump-fleet-server` ✅; `web_server` ❌ god-file |
| **External-repo automation** | `onboard.rs`, `improve.rs`, `external_verify_merge.rs`, `commands/bootstrap.rs`, `crates/chump-handoff`, `scripts/arsenal/` | **Autonomous OSS contributor** (onboard→improve→verify-merge with anti-cosmetic gates + self-merge) + 0→1 bootstrapper — *Devin / SWE-agent / Sweep / Dependabot*. **Least-proven externally (§0).** | schema/contract/verify-merge ~80%; improve/bootstrap ⚠️ |

---

## 3. The negative space (what tidy scans miss — and why)

A capability scan finds what it's told to look for. The buckets in §2 were *hypotheses*,
so they confirmed themselves and **missed whole categories.** These are real (LOC in
the source tree), and easy to overlook:

- **Cognitive architecture / "synthetic consciousness" (~7.9K LOC).** `phi_proxy.rs`
  (an Integrated-Information-Theory proxy measuring cross-module information flow),
  `neuromodulation.rs`, `blackboard.rs` (global workspace), `belief_state.rs`,
  `counterfactual.rs`, `ego_tool.rs`, `introspect_tool.rs`, `consciousness_*`,
  `reasoning_mode.rs`, `precision_controller.rs`, `activation.rs`. **This reframes the
  whole project:** it is as much a cognitive-architecture research bet as a devtool.
  Empirical status is deliberately *not* in this public repo — see
  `docs/architecture/CHUMP_FACULTY_MAP.md` (moved to `chump-proprietary`) and
  `docs/process/RESEARCH_INTEGRITY.md`.
- **Evaluation / research science (~4.6K Rust + ~41K script LOC).** `eval_harness.rs`,
  `adversary_llm.rs`, `battle_qa_tool.rs`, `vector6/7_verify.rs`, `trajectory_replay.rs`
  + `scripts/ab-harness`, `eval-human-label`, `eval-reflection-ab`, `qa`. A rigorous
  A/B + adversarial + human-labeling harness that has *honestly killed features*.
- **Tool-governance + WASM sandbox (~6K LOC).** `tool_policy/middleware/routing`,
  `context_firewall.rs`, `sandbox*.rs`, `wasm_runner.rs` — agent tool-use *safety*.
- **PR-review intelligence (~5K LOC).** `pr_triage/explain/fix_clippy/ac_coverage/
  coupling`, `diff_review_tool.rs` — review automation distinct from the ship pipeline.
- **Omni-channel messaging (~4.8K LOC).** Discord / Telegram / Slack / `platform_router`.
- **Skills registry (~2.6K LOC).** `skill_db/hub/metrics/tool` — a capability marketplace.
- **HITL + operator-modeling (~1.7K LOC).** `hitl_escalation.rs`, `approval_resolver.rs`,
  and `ask_jeff_db.rs`/`user_profile.rs` — *the system models its own operator.*
- **Device/computer control (~1.4K LOC).** `browser*.rs`, `screen_vision_tool.rs`,
  `mcp-servers/chump-mcp-adb` (Android).
- **Also uncovered:** `chump-gh-app` (a real GitHub App), `chump-integrator`,
  `chump-policy`, `chump-reviewer-routing`, `chump-cancel-registry`, `ast-crawler`.

**The deepest asset isn't code at all:** the **doctrine + decision-log corpus**
(`docs/` ≈ 78K lines across 527 files + 1,171 gap YAMLs). That is a uniquely detailed
record of *how to run autonomous coding-agent fleets, what breaks, and how it was fixed* —
harder to replicate than any single module, and the connective tissue for everything else.

---

## 4. Five cross-cutting truths

1. **Claimed capability ≫ verified capability.** The instruments overstate reality
   (§0). The honest maturity of §2 is materially lower than the code says.
2. **It's a cognitive-architecture bet in a devtool costume.** The consciousness/
   neuromodulation/φ/counterfactual layer is the actual ambition; the CI-bot framing
   hides it. Different thesis, different risk profile.
3. **The doctrine corpus is the least-replicable asset** — worth more than any one
   product because it's the accumulated operating methodology (§3).
4. **The eval rigor is the antidote to §0 — but pointed the wrong way.** A serious A/B/
   adversarial harness exists and is intellectually honest, yet it's aimed at cognitive
   experiments, **not** at the operational metrics that lie. *Turning it onto the
   fleet's own self-reports is the single highest-impact move in the repo.*
5. **Extractability is the binding constraint, and it's currently blocked.** 34 clean
   crates *imply* modularity, but ~188K LOC sit in the root `chump` binary behind
   god-files (`main.rs` ~18K, `web_server.rs` ~10K), and ~89 `scripts/ci` tests
   hard-code `src/main.rs`. Attempting to extract the gap arm (`INFRA-3302`, 2026-07-05)
   **failed** on exactly this coupling. The "many products" are, today, welded together.

---

## 5. The keystone (what unlocks all of it)

Two unglamorous moves gate almost everything above:

1. **Decompose the monolith (`INFRA-3287`).** Until `main.rs`/`web_server.rs` and the
   root crate are broken into the workspace crates that already exist, *no* capability
   in §2 can become a standalone product, and every change pays the recompile + test-
   coupling tax. **Do it in tiny per-command sub-slices** — big-arm moves shatter the
   ~89 `main.rs`-grepping tests at once (that's how `INFRA-3302` failed). See
   `docs/gaps/INFRA-3287.yaml`.
2. **Point the eval harness at the fleet's own metrics.** Apply the same A/B + ground-
   truth rigor used on cognitive experiments to `fleet_status` / `fleet_health` /
   ship-count / auth-status. That converts §0 from a recurring liability into a
   differentiator: a *self-verifying* agent fleet.

Everything else is a prioritization question on top of these two.

---

## 6. Provenance & refresh

- **Method:** 8 parallel read-only capability scans (coordination, LLM infra, CI/ship,
  memory, dev surfaces, work/planning, observability, external-repo) + a negative-space
  sweep over `crates/`, `src/`, `scripts/`, and `docs/`. LOC figures are `wc -l` over
  `git ls-files` at the time of writing.
- **Bias to correct on refresh:** bucketed scans confirm their own hypotheses and
  inherit the code's optimism (§0). When refreshing, *start* from the negative space and
  from outcome-verification, not from the feature list.
- **Privacy:** empirical eval results (deltas, n-values, model-tier outcomes) and
  faculty-status tables are intentionally excluded here and tracked in `chump-proprietary`
  per the 2026-05-05 IP sweep. Methodology remains public in
  `docs/process/RESEARCH_INTEGRITY.md`.

_Last mapped: 2026-07-05._
