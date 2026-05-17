---
name: pre-ship-ci-prediction
description: Predict CI verdict (green/yellow/red) before arming bot-merge, based on local checks + queue-jam state + recent failure history
version: 1
platforms: []
metadata: {}
---

# pre-ship-ci-prediction

## User story

**As a Shipper agent**, when I am about to push commits and arm `bot-merge --auto-merge`,
**I want to predict the CI verdict using local checks + current queue-jam state + recent required-check failure history**,
**so that I don't add my PR to an already-jammed queue and trigger an hour of operator firefighting that 7 sibling workers ALREADY caused** (precedent: 2026-05-17 03:00 UTC — 10/10 open PRs BLOCKED, fleet-paused doctrine ignored).

## When this skill applies

Trigger this skill whenever you are about to:
- Run `scripts/coord/bot-merge.sh --gap <ID> --auto-merge`
- Push to a feature branch with intent to PR
- Open a PR via `gh pr create`
- Arm auto-merge on an existing PR via `gh pr merge --auto`

## Procedure

1. **Pipeline-jam check** (don't push into a jammed queue):
   ```bash
   gh pr list --state open --limit 20 --json mergeStateStatus 2>/dev/null \
     | jq -r '.[].mergeStateStatus' | sort | uniq -c
   ```
   Compute `% BLOCKED`. If ≥50% over the open queue → **STOP** and surface to operator. Your PR will just stack.

   Once [INFRA-1607](docs/gaps/INFRA-1607.yaml) lands, this becomes:
   ```bash
   test -f .chump/fleet-paused && { cat .chump/fleet-paused; exit 1; }
   ```

2. **Local pre-commit gates** (catch what CI will catch, cheaper):
   ```bash
   cargo fmt --all -- --check
   cargo clippy --all-targets --all-features -- -D warnings
   cargo check --bin chump --tests
   ```
   Failures here = CI will fail. Fix locally before push.

3. **Required-check flake-rate check**:
   ```bash
   # Required checks per repo ruleset
   REQ_CHECKS=$(gh api repos/{owner}/{repo}/rules/branches/main 2>/dev/null | jq -r '.[] | .name')
   # Last 20 runs per check, fail rate
   for check in $REQ_CHECKS; do
     gh run list --workflow="$check" --limit 20 --json conclusion \
       | jq -r '[.[].conclusion] | (group_by(.) | map({(.[0]): length}) | add)' 
   done
   ```
   Any required check with >20% failure rate → expect a flake. Either retry-tolerant or rebase first.

4. **ACP smoke specifically** (today's biggest jam source):
   ```bash
   # Is your branch likely to hit the broken ACP lane? (per INFRA-1561 Wave 1)
   gh pr diff <PR_NUMBER> --name-only 2>/dev/null | grep -E '^src/.*acp|src/main\.rs$|crates/.*Cargo.toml'
   ```
   If any match AND `CHUMP_SELF_HOSTED_ENABLED=true` → ACP smoke is on the broken-lane path → expect failure until INFRA-1561 ships.

5. **tauri-cowork-e2e specifically** (chronic flake):
   ```bash
   gh pr diff <PR_NUMBER> --name-only 2>/dev/null | grep -E '^desktop/src-tauri|^web/v2'
   ```
   If empty AND tauri-cowork-e2e is a required check → expect SKIPPED → expect BLOCKED. See INFRA-1432/1433/1529/1425/1385 for the family of gaps tracking this.

6. **Verdict**:
   - **GREEN** (all checks pass, jam <30%, no flake-path hit) → `bot-merge --auto-merge`
   - **YELLOW** (one signal soft-bad: jam 30-50%, or 1 flake-path hit, or 1 local lint warning) → push, watch closely, manual retrigger ready
   - **RED** (jam ≥50%, multiple flake paths, or local checks fail) → do NOT push. Either rebase first OR escalate to operator OR wait for queue to drain

## Pitfalls

### Pitfall 1: "Local cargo test passes" ≠ "CI test will pass"
Different runner OS, different env vars, different cache state, different network. **Required checks run on self-hosted runners with platform-specific guards (INFRA-1539 sweep).** Local-pass is necessary but not sufficient.

### Pitfall 2: Trusting tauri-cowork-e2e to "just pass eventually"
This check has been failing or SKIPPED-on-non-tauri-paths for weeks. INFRA-1425/1432/1433/1529 are all open gaps. Treat any required-check-with-SKIPPED-result as **failure**, not "passed via skip" — required checks that skip BLOCK the PR per the ruleset.

### Pitfall 3: Ignoring the ambient `gh_self_throttled` signal
44K self-throttle events in 23h on 2026-05-15. If `tail -200 .chump-locks/ambient.jsonl | grep gh_self_throttled | wc -l` returns >10 in the last hour, GitHub API is rate-limited; auto-merge will probably time out waiting on REST. **Wait for the spike to clear before arming.**

### Pitfall 4: Pushing into the queue when paramedic is broken
[INFRA-1597](docs/gaps/INFRA-1597.yaml) tracks "paramedic daemon broken (LLM-mode + r2d2)". If paramedic isn't running, BLOCKED PRs don't get auto-rescued — they sit. Verify: `launchctl list | grep com.chump.paramedic` should return a running entry. If empty, manual rescue only.

## Verification (how to know this skill worked)

- Your PR ships within 30 minutes of `--auto-merge` arming under normal queue conditions
- Your PR does NOT enter the BLOCKED state for >10 minutes
- Required checks pass on first run (no manual retrigger needed)
- You did NOT add to a jam (the queue's `% BLOCKED` did not increase post-push)

## Outcome recording

```
skill_manage(action=record_outcome, name=pre-ship-ci-prediction, success=true)
```

Call `success=true` when:
- Your PR shipped clean as predicted (GREEN)
- You correctly identified a YELLOW and shipped with one retrigger
- You correctly identified a RED and **didn't push** (the highest-value case — you saved a wasted CI cycle)

Call `success=false` when:
- You predicted GREEN and CI failed
- You predicted RED and didn't push, but the queue cleared and you could have shipped fine (over-cautious)
- Your push BLOCKED for >30min on a check the procedure should have flagged

## Cross-references

- **The lid** (auto-pause on jam): [INFRA-1607](docs/gaps/INFRA-1607.yaml)
- **Specific known flakes**: [INFRA-1561](docs/gaps/INFRA-1561.yaml) (ACP lane), INFRA-1432/1433/1529 (tauri-cowork)
- **Paramedic health**: [INFRA-1597](docs/gaps/INFRA-1597.yaml)
- **GitHub rate-limit context**: AGENTS.md "GraphQL exhaustion handling"
- **Required-check ruleset gate**: [INFRA-1522](docs/gaps/INFRA-1522.yaml) (sibling — gates `chump fleet up`)
