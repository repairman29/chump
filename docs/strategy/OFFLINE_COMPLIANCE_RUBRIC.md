---
doc_tag: strategy-rubric
last_audited: 2026-05-16
audience: gap filers (operator + fleet workers), Mission Driver, INFRA-1418 linter
purpose: Define what "offline-compliant" means in Chump. Used by `chump gap reserve --offline-check` (INFRA-1418) to catch anti-offline framing at file-time. Companion to docs/design/OFFLINE_FIRST.md (architecture) and docs/design/GITHUB_LIAISON.md (connected-mode efficiency).
status: v1 — Chief of Product canon, 2026-05-16
---

# Offline-Compliance Rubric

> **Mission anchor:** Chump enables offline solo devs on local LLMs. The bespoke coordination layer (NATS, state.db, ambient.jsonl, file leases) is **load-bearing strategy, not tech debt**. The Pi mesh (4 Pis, no internet, Llama on each) is the target deployment. The airplane-with-MacBook is the minimum viable test. — `project_offline_local_llm_mission.md`

Every gap filed against Chump must answer one question: **does this work when the laptop is on an airplane?**

This rubric defines the answer in three classes, lists the forbidden-without-fallback patterns that flag a gap as anti-offline, and gives the operator playbook for the rare cases where breaking offline is genuinely the right call.

## §1 — The three offline_class values

Every gap carries one of:

### `required` (default)

The gap delivers a capability that **must work in `CHUMP_GITHUB_MODE=offline`**. Implementation may use GitHub when connected for efficiency, but the offline path is a first-class deliverable in the AC.

Examples:
- "chump gap ship" — the registry must update offline (proof-of-merge from local main, INFRA-1392)
- "chump fleet status" — must read from local state.db, not poll GitHub
- "merge a feature branch" — local-merge-queue.sh must work without `gh pr merge` (INFRA-1323)

### `optional`

The gap delivers an **online-only optimization** that does not block the offline path. When GitHub is unreachable, the feature gracefully degrades to a clearly-flagged degraded mode (e.g. cache stale, polling fallback) and the fleet keeps running.

Examples:
- GitHub Liaison Phase 2 (INFRA-1318) — webhook-first cache; offline path serves last-known-good with `cached_at` flag
- GitHub Merge Queue (INFRA-1377) — saves CI minutes when connected; offline path uses local-merge-queue
- Webhook-driven auto-rebase (INFRA-1405) — webhook OR local post-receive hook; daemon works in either mode

### `breaks_offline` (requires sign-off)

The gap **regresses Pi-mesh capability** by introducing a hard dependency on GitHub or another network service in a path that previously worked offline. Filing requires `--force-anti-offline` + a written `Anti-Offline-Bypass:` trailer in the commit (audit trail).

Use only when:
- The feature genuinely cannot have an offline equivalent (e.g. "publish to GitHub Discussions"), AND
- The path is opt-in (operator has to explicitly enable it), AND
- An ambient event clearly marks when the path is exercised so offline operators see it in their stream

Today's catalog of `breaks_offline` gaps: **none merged**. INFRA-1377 (Merge Queue) is the closest call but is `optional` because it doesn't remove the offline path, only optimizes the online one.

## §2 — Forbidden-without-fallback patterns

The INFRA-1418 linter scans gap titles + descriptions + AC for these patterns and blocks the reserve unless `--force-anti-offline` is set. Each entry shows the regex (case-insensitive), the typical fix, and the doc reference.

| Pattern | Why it's anti-offline | Suggested rewrite | Doc |
|---|---|---|---|
| `gh pr (merge\|create\|view) ... ONLY` | hard-pins the path to GitHub even when local-merge-queue exists | "gh pr X (online) OR local-merge-queue.sh (offline)" | OFFLINE_FIRST.md §2 |
| `webhook ... ONLY\|webhook-only\|only.*webhook` | local equivalents (post-receive hook, NATS subject) exist for almost every webhook event | "webhook OR local-equivalent (post-receive hook / NATS subject `chump.<topic>`)" | OFFLINE_FIRST.md §3 |
| `GitHub Actions (must\|required\|is the gate)` | conflates the executor with the definition of correctness; tests are the CI | "GitHub Actions in connected mode, scripts/ci/run-local-ci.sh in offline mode" | OFFLINE_FIRST.md §1 |
| `gh api .* (blocking\|required\|gates)` | every fleet read should be cache-first per CLAUDE.md | "cache-first read via cache_lookup_*; gh api fallback only on miss" | CLAUDE.md §Cache-first reads |
| `--auto-merge` (literal flag, no fallback mention) | bot-merge.sh path doesn't work offline | pair with "or local-merge-queue.sh when CHUMP_GITHUB_MODE=offline" | OFFLINE_FIRST.md §2 |
| `pull_request\.\w+ event` (without local trigger) | GitHub-delivered event with no local-emit equivalent | "pull_request.X webhook OR ambient kind=<local-equivalent> emitted by post-receive hook" | INFRA-1405 (case study) |
| `state\.db .* flips on .* webhook\|webhook .* writes state\.db` | couples local ground truth to network delivery | "proof-of-merge: PROOF_LOCAL_MERGE OR PROOF_WEBHOOK; state.db remains canonical" | INFRA-1392 (case study) |

Each match in the gap text emits:

```
OFFLINE_CHECK FAIL: <line>
  pattern: <regex name>
  why: <one-line>
  suggested rewrite: <text>
  see: docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2
```

The reserve aborts unless `--force-anti-offline` is passed.

## §3 — Decision tree: is my new gap offline-compliant?

Walk this top-to-bottom **before** running `chump gap reserve`. Five yes/no questions; first "no" tells you the class.

1. **Can a Pi 4 with no internet access execute the AC end-to-end?** If no → `optional` if there's graceful degradation, `breaks_offline` if not.
2. **Does any AC step say "wait for GitHub Actions" / "wait for webhook" / "poll gh api" with no local alternative?** If yes → `breaks_offline` unless rewritten with an OR-clause.
3. **Does the gap mutate `state.db`, `.chump-locks/`, or `ambient.jsonl` based on a GitHub-delivered signal?** If yes → it must accept the local-equivalent signal too. Otherwise `breaks_offline`.
4. **Does the gap add a new required CI check that lives only in `.github/workflows/`?** If yes → either also add to `scripts/ci/run-local-ci.sh` (then `required`) or accept `optional` and document the offline gap.
5. **Does the gap use `gh api` / `gh pr` in a hot loop without going through `cache_lookup_*` first?** If yes → `optional` at best; rewrite to cache-first per CLAUDE.md.

If you answered "yes" to all five, the gap is `required` (default). File it.

## §4 — The `--force-anti-offline` operator playbook

Reserved for cases where breaking offline is genuinely the right product call.

**When it's appropriate:**
- The feature is intrinsically network-dependent (e.g. "publish release notes to GitHub Discussions") — there is no offline equivalent that makes sense.
- The feature is opt-in, off by default, and a connected-mode operator explicitly chose it.
- The cost of a parallel offline implementation outweighs the benefit (rare; usually the offline path is a few extra lines, not a parallel system).

**Operator step:**

```bash
chump gap reserve --domain X --priority P1 --effort s \
    --title "..." \
    --force-anti-offline \
    --offline-bypass-reason "Genuinely network-dependent: publishes to GitHub Discussions, no local equivalent. Off by default; operator must set CHUMP_PUBLISH_DISCUSSIONS=1."
```

This writes an audit row to `gap_offline_bypass_audit` (gap_id, reason, operator, timestamp). The gap is tagged `offline_class: breaks_offline` automatically.

**Commit-time discipline:**

The implementing PR must include a trailer in the commit body:

```
Anti-Offline-Bypass: <one-sentence reason matching the gap's offline-bypass-reason>
```

The pre-commit gate (extension of `scripts/git-hooks/pre-commit-rust-first.sh` pattern) checks for this trailer when the touched gap has `offline_class: breaks_offline`. Bypass goes into the audit log.

**Reviewer mandate:**

Operator (Jeff) reviews every `breaks_offline` PR before merge. No fleet auto-approval. The audit row + commit trailer + operator review form the three-key gate.

## §5 — Case studies

These are real gaps that hit `OFFLINE_CHECK FAIL` during the 2026-05-16 audit pass and were rescoped:

### INFRA-1392 (state.db status flip)
**Original (anti-offline):** "state.db gap status flips ONLY on webhook pull_request.merged=true (not on chump claim)"

**Rescoped (`required`):** "state.db status only flips on PROOF-OF-MERGE (local main commit OR webhook merged=true)"

**Lesson:** The bug (status flips pre-merge on `chump claim`) is real. The proposed fix coupled the truth to a network-delivered event, which broke offline. Rewrite accepts proof from either local-main-commit OR webhook — symmetric across the two modes.

### INFRA-1405 (event-driven auto-rebase)
**Original (anti-offline):** "event-driven auto-rebase on pull_request.synchronize webhook — replaces pr-rescue.sh 2h cron"

**Rescoped (`required`):** "event-driven auto-rebase on local-push OR pull_request.synchronize webhook"

**Lesson:** Same anti-offline trap — the trigger was hard-coupled to GitHub. Local equivalent (post-receive hook on local main bare repo, or git config hook in single-machine case) emits the same `branch_rebase_needed` event. Daemon consumes the event regardless of source.

### INFRA-1318 (GitHub Liaison Phase 2)
**Original:** Vague AC (TODO placeholders); risk that "webhook-first cache" would be implemented as "webhook-only cache."

**Filled-in (`optional`):** Liaison reads still serve from cached value with `cached_at` stale-flag when GitHub is unreachable. Workflows that need fresh data exit with a "cache stale" message rather than retry-API-until-rate-limit-dies. Liaison is not started at all in `CHUMP_GITHUB_MODE=offline`.

**Lesson:** Connected-mode efficiency features are fine — they just need an explicit graceful-degradation contract in the AC.

## §6 — How to cite this rubric

The INFRA-1418 linter cites sections directly:

```
OFFLINE_CHECK FAIL: AC item 3 mentions "webhook ... ONLY"
  see: docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2 forbidden-patterns
  see also: case study INFRA-1392 in §5
  fix: rewrite as "PROOF_LOCAL_MERGE OR PROOF_WEBHOOK"
```

PR reviewers cite the rubric in review comments:

```
This adds a webhook-only path. Per OFFLINE_COMPLIANCE_RUBRIC.md §3 question 2, this needs a local-equivalent OR an `Anti-Offline-Bypass:` trailer.
```

Operator emergency overrides cite the rubric in the audit reason:

```
chump gap reserve ... --force-anti-offline \
  --offline-bypass-reason "RUBRIC §4 case 1 (intrinsically network-dependent); off by default."
```

## §7 — Maintenance

This rubric is canon. Updates require:

1. Filing a gap with title `MISSION: OFFLINE_COMPLIANCE_RUBRIC update — <change>`
2. Operator review (the rubric defines the bar; changing it changes what the bar means)
3. Re-running `chump gap audit --offline-class` after merge to surface any gaps that now reclassify

The forbidden-pattern catalog (§2) is the most-likely-to-evolve section. New patterns get added when a new anti-offline framing is observed in the wild — see the case studies in §5 for the pattern.
