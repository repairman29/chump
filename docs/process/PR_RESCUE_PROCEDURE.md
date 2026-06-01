---
doc_tag: canonical
owner_gap: META-246
last_audited: 2026-05-31
authority: operator-decision-of-record 2026-05-31T15:55Z
---

# PR Rescue Procedure (canonical doctrine)

> **Audience:** PR-shepherd daemon, dispatched Sonnet sub-agents, Opus orchestrators, curators on rescue duty.
>
> **When to use:** queue depth > 20 stuck PRs OR operator paged "queue is stuck" OR 4+ hour stall.

Codifies the **triage → fix-at-source → propagate → cascade** sequence we've executed 5+ times this session. Same pattern each time. This doc means we stop reinventing.

---

## TL;DR (daemon brief-injection, ~30 lines)

```
WHEN OPERATOR PAGES "QUEUE IS STUCK":

1. DIAGNOSE before acting. Run:
     gh pr list --state open --limit 200 --json mergeStateStatus | jq 'group_by(.mergeStateStatus) | map({s:.[0].mergeStateStatus, n:length})'
     gh pr list --state open --limit 200 --json mergeStateStatus,statusCheckRollup | jq '.[] | select(.mergeStateStatus=="BLOCKED") | .statusCheckRollup[] | select(.conclusion=="FAILURE") | .name' | sort | uniq -c | sort -rn | head -10

2. CLASSIFY by dominant surface. If >70% of BLOCKED PRs fail on SAME check name:
     → Systemic rot. Fix AT SOURCE. (Section 5 patterns)
   Else:
     → Per-PR triage. (Section 4 per-state actions)

3. FIX SUBSTRATE FIRST. Land the surface fix (1 PR, admin-merge if no real-content failure).

4. PROPAGATE. Trigger rebase wave OR rerun wave on dependent PRs. (Section 6 cascade tables)

5. WAIT for cascade (5-15 min per PR; 4 self-hosted Macs + GitHub-hosted ubuntu-arm).

6. AUTONOMOUS DAEMONS take it from here. Verify pr-shepherd is ticking; verify auto-merge-rearm armed CLEAN PRs.

DO NOT:
- Mass admin-merge feat-class PRs without verifying cargo-test passes
- File 26 individual gaps for the same fingerprint (META-186 fingerprint dedup is canonical)
- Rebase one PR at a time (do the whole wave; share runner cost)
- Trigger 28 reruns without throttling (queue saturates self-hosted Mac runners)
```

---

## 1. When to use this

| Trigger | Action |
|---|---|
| `chump pr-shepherd-status` reports queue > 20 BLOCKED | Run §2 triage |
| Operator pages "queue stuck" / "rescue the PR queue" | Run §2 triage |
| Last main ship > 4 hours ago AND open PRs > 10 | Run §2 triage |
| 5+ PRs file follow-up gaps with same fingerprint within 1h (META-186 dedup signal) | Run §2 triage; assume systemic rot |
| Single PR stuck > 24h | Use `shepherd` curator, NOT this doc |

---

## 2. Triage protocol (the 4-step diagnose)

```bash
# Step 1: queue shape
gh pr list --state open --limit 200 --json mergeStateStatus | \
  jq 'group_by(.mergeStateStatus) | map({s:.[0].mergeStateStatus, n:length})'

# Step 2: dominant failure surface
gh pr list --state open --limit 200 --json mergeStateStatus,statusCheckRollup | \
  jq '.[] | select(.mergeStateStatus=="BLOCKED") | .statusCheckRollup[] |
      select(.conclusion=="FAILURE") | .name' | \
  sort | uniq -c | sort -rn | head -8

# Step 3: dominant STEP (within the failing check)
SAMPLE=$(gh pr list --state open --limit 200 --json number,mergeStateStatus --jq '.[] | select(.mergeStateStatus=="BLOCKED") | .number' | head -1)
gh pr view $SAMPLE --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | .detailsUrl' | \
  head -3

# Step 4: classify the surface (§5 patterns)
```

**Decision rule:** if step 2's top failure count ≥ 70% of BLOCKED count → **systemic rot, fix at source** (§3). Else → **per-PR triage** (§4).

---

## 3. Systemic rot — fix at source

When ≥70% of BLOCKED PRs share a failure surface, ONE upstream PR unblocks them all. The 5 patterns we hit this session (all in §5):

| Surface | Source PR | Cascade after |
|---|---|---|
| `raw-gh lint gate` audit fail (allowlist drift) | INFRA-2314, INFRA-2315 (same pattern) | Rebase wave |
| `Install manifest gate` pr-hygiene fail | INFRA-2308 | Rebase wave |
| `EVENT_REGISTRY coverage` audit fail | RESILIENT-041 (sweep) | Rebase wave |
| `test-pre-push-test-gate` fast-checks fail | INFRA-2297 (test fixture bug) | Rerun wave |
| sccache cred / Rust toolchain | RESILIENT-041 / #2845 | Rerun wave |

**Execution sequence (rigid):**

```bash
# 3a. File P0 gap for the source fix:
chump gap reserve --domain INFRA --title "trunk-red rescue — <one-line surface>" \
                  --priority P0 --effort xs --force

# 3b. Claim + edit the canonical file:
chump claim <GAP-ID> --paths <canonical-file>

# 3c. Make the surgical edit (no scope expansion!)
#     Examples:
#     - Allowlist drift: append to scripts/ci/raw-gh-allowlist.txt
#     - Manifest gate: append to scripts/setup/optional-installers-allowlist.txt
#     - EMIT-NO-REG: append to scripts/ci/event-registry-reserved.txt
#     - Flaky test: append to docs/process/KNOWN_FLAKES.yaml (INFRA-764)

# 3d. Verify locally:
bash scripts/ci/test-<relevant>.sh 2>&1 | tail -5

# 3e. Push + admin-merge:
bash scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
# OR if bot-merge stalls (15 min budget):
CHUMP_OPERATOR_RECOVERY=1 git push -u origin <branch>
gh pr create --base main --title "fix(<GAP-ID>): <one-line>" --body "..."
gh pr merge <PR> --admin --squash --repo repairman29/chump

# 3f. Propagate per §6 cascade table.
```

---

## 4. Queue-state taxonomy

Each PR is in exactly one of 6 daemon-classification states (META-183 + META-185 framework). Action per state:

| State | What it means | Action |
|---|---|---|
| **MERGEABLE** | All required checks pass; auto-merge NOT armed | PR-shepherd daemon arms via `gh pr merge --auto --squash` (META-186) |
| **ARMED** | All required checks pass; auto-merge IS armed | No-op. Wait for merge. |
| **BEHIND** | Main moved; needs rebase | PR-shepherd daemon auto-rebases via `gh pr update-branch --rebase` (META-184) |
| **BLOCKED** | Required checks haven't completed; conclusion may still be running | Wait. CI saturation. |
| **BLOCKED_GREEN** | All checks done, none failed, but auto-merge not armed | PR-shepherd daemon arms (META-186) |
| **BLOCKED_REAL_FAIL** | At least one required check FAILED | PR-shepherd daemon files follow-up gap with sha256 fingerprint dedup (META-186) |
| **DIRTY** | Semantic merge conflict | Daemon does NOT touch. Operator-attention queue. |
| **UNKNOWN** | GitHub still computing | Wait. Resolves within 60 sec typically. |

---

## 5. Failure-surface taxonomy (12 patterns from this session)

For each pattern: **detect signal**, **upstream source**, **fix action**, **propagation**.

### 5.1 Allowlist drift — `raw-gh lint gate`
- **Detect**: `audit` job step *"raw-gh lint gate — no new direct gh calls in hot-path scripts outside lib/ (INFRA-1274)"* fails. Log line: `FAIL: N new raw-gh caller(s) found in hot paths`.
- **Source**: Recently-merged daemon or script added raw `gh` calls without updating allowlist.
- **Fix**: Append entry to `scripts/ci/raw-gh-allowlist.txt` with migration ref `# migration gap: INFRA-1249` (or specific gap).
- **Propagation**: Rebase wave on all PRs.

### 5.2 Install manifest gate — `pr-hygiene`
- **Detect**: `pr-hygiene` job step *"Install manifest gate"* fails. Log: `FAIL: N unmapped installer(s) — see remediation above`.
- **Source**: New `scripts/setup/install-*.sh` shipped without manifest update.
- **Fix**: Append entry to `scripts/setup/optional-installers-allowlist.txt` (alphabetical).
- **Propagation**: Rebase wave.

### 5.3 EMIT-NO-REG sweep — event-registry-coverage
- **Detect**: `audit` job step *"EVENT_REGISTRY coverage"* fails. Log: `EMIT-NO-REG: <kind>` repeated N times.
- **Source**: New `kind=foo` emit shipped without registering in `EVENT_REGISTRY.yaml` OR `event-registry-reserved.txt`.
- **Fix**: Append entries to `scripts/ci/event-registry-reserved.txt` with `# reason: <gap> emitted by <path>:<line>`.
- **Propagation**: Rebase wave.

### 5.4 Register-without-emit orphans — strict-mode audit
- **Detect**: `audit` step with `CHUMP_REGISTRY_GATE_MODE=strict` fails on `register-without-emit (orphans): N`.
- **Source**: New entries to `EVENT_REGISTRY.yaml` whose emitters never landed.
- **Fix**: Either ship the emitter OR mark in `event-registry-reserved.txt` with "deferred to per-feature gap" rationale.
- **Propagation**: Rebase wave.

### 5.5 Test-pre-push-test-gate fixture bug — `fast-checks`
- **Detect**: `fast-checks` step *"pre-push cargo-test full-suite gate (INFRA-761)"* fails with `rs-change-passing should pass (rc=2)`.
- **Source**: `scripts/ci/test-pre-push-test-gate.sh` test fixture injects synthetic code into a file that doesn't exist (e.g. `src/lib.rs` for the chump crate). This was fixed by INFRA-2297 but watch for similar fixture drift.
- **Fix**: Adjust test fixture in `scripts/ci/test-pre-push-test-gate.sh`.
- **Propagation**: Rerun wave (not rebase — content already up-to-date).

### 5.6 sccache R2 cred broken — `cargo-test` exit 102
- **Detect**: `cargo-test` step fails with `sccache: error: Server startup failed: cache storage failed to read: Credential access key has length 1, should be 32`.
- **Source**: `R2_ACCESS_KEY_ID` GitHub secret is misconfigured (placeholder, garbage, or expired).
- **Fix**: T2 operator escalation per META-207. Operator runs `~/.chump/r2-rotation.env` rotation script.
- **Mitigation if operator unavailable**: Defense-in-depth length check in `.github/workflows/ci.yml`'s `r2detect` step routes garbage creds through no-cache fallback (RESILIENT-041 pattern).
- **Propagation**: Rerun wave.

### 5.7 Cranelift component unavailable — `Install Rust toolchain`
- **Detect**: `Install Rust toolchain` step fails with `error: component 'rustc-codegen-cranelift' for target 'x86_64-unknown-linux-gnu' is unavailable for download for channel 'stable'`.
- **Source**: Upstream Rust release dropped the cranelift component manifest entry.
- **Fix**: Drop the `--component rustc-codegen-cranelift` flag from the `actions/rust-toolchain` step in `.github/workflows/ci.yml` (#2845 pattern).
- **Propagation**: Rebase wave.

### 5.8 chump-integrator merge_branch test panic — `cargo-test`
- **Detect**: cargo-test fails with `cycle::merge_branch::tests::test_conflict_aborts_with_structured_error ... FAILED` and panic *"first merge should have succeeded"*.
- **Source**: A merge that landed broken integration logic in `crates/chump-integrator/src/cycle/merge_branch.rs`.
- **Fix**: Active sub-agents on chump-integrator worktree own this; ci-audit curator dispatches.
- **Propagation**: Rerun wave after fix lands.

### 5.9 Pr-shepherd-daemon self-allowlist gap
- **Detect**: Same as §5.1 but with file `scripts/coord/pr-shepherd-daemon.sh` flagged.
- **Source**: META-186 added `gh pr merge` and `gh pr update-branch` to the daemon WITHOUT updating allowlist. Self-referential blocker.
- **Fix**: INFRA-2315 pattern — append `scripts/coord/pr-shepherd-daemon.sh` to allowlist.
- **Propagation**: Rebase wave.

### 5.10 Auto-merge-rearm daemon allowlist gap
- **Detect**: Same as §5.1 but with `scripts/coord/auto-merge-rearm-daemon.sh` flagged.
- **Source**: INFRA-2309 shipped the rearm daemon; its `gh pr list --json mergeStateStatus,autoMergeRequest` is raw gh because cache wrapper doesn't expose those fields.
- **Fix**: INFRA-2314 pattern — append both `scripts/coord/auto-merge-rearm-daemon.sh` and `scripts/coord/chump-pr-ready-to-ship.sh`.
- **Propagation**: Rebase wave.

### 5.11 Flaky test — `gap-reserve concurrency (INFRA-021)`
- **Detect**: `fast-checks` step *"gap-reserve concurrency (INFRA-021)"* fails intermittently across many PRs.
- **Source**: `scripts/ci/test-gap-reserve-concurrency.sh` has race-condition flakiness.
- **Fix**: Add to `docs/process/KNOWN_FLAKES.yaml` (INFRA-764 framework). Cargo-test wrapper auto-retries on known-flake matches.
- **Propagation**: Rerun wave after KNOWN_FLAKES update propagates.

### 5.12 Ghost PRs — gap status=done but PR still open
- **Detect**: PR title regex extracts gap-id `<DOMAIN>-NNN`; `chump gap show <ID>` returns `status: done`.
- **Source**: PR was force-closed-without-merge OR gap was bulk-flipped via override; PR became orphan.
- **Fix**: `gh pr close <N> --comment "Ghost — gap already status=done; closing per META-225 auto-fixer"`.
- **Propagation**: None (closes 1 PR, no cascade).

---

## 6. Cascade impact tables (fix X → expect Y)

### 6.1 Allowlist-class fixes
| You fix | All open PRs are now... | Next action |
|---|---|---|
| `scripts/ci/raw-gh-allowlist.txt` | BEHIND (need new base) | Rebase wave on all BLOCKED PRs |
| `scripts/setup/optional-installers-allowlist.txt` | BEHIND | Rebase wave |
| `scripts/ci/event-registry-reserved.txt` | BEHIND | Rebase wave |

### 6.2 Test-fixture / flake fixes
| You fix | All open PRs are... | Next action |
|---|---|---|
| `scripts/ci/test-pre-push-test-gate.sh` | Still on same base; just need fresh CI | Rerun wave: `gh run rerun <RUN> --failed` |
| `docs/process/KNOWN_FLAKES.yaml` | Same; flake autoretry honored on next run | Rerun wave |

### 6.3 Workflow-class fixes
| You fix | Side effects to expect |
|---|---|
| `.github/workflows/ci.yml` (any change) | preflight-vs-CI parity gate may fire; add to `scripts/ci/preflight-ci-parity-exceptions.txt` if new step can't mirror |
| Required-check change in branch-protection ruleset | Active PRs may stay BLOCKED until ruleset propagates (~30 sec); existing armed-auto-merge may disarm |
| `cargo-test` / `e2e-pwa` `runs-on:` change | Next run routes to new runner; existing in-progress jobs complete on old |

### 6.4 Code-class fixes (rare; per-PR triage instead)
| You fix | Cascade |
|---|---|
| `Cargo.lock` | All Rust PRs need rebase + recompile (~15 min sccache-warm, 30 min cold) |
| `crates/X/src/lib.rs` | Only PRs touching that crate affected; per-PR rebase |
| `.cargo/config.toml` | All Rust PRs need rerun (not rebase) |

### 6.5 Substrate-class fixes (operator-action)
| You can't fix (operator T2) | Workaround |
|---|---|
| R2 cred rotation | Defense-in-depth length-check in r2detect step |
| chump-fleet-bot identity | Use operator's gh CLI temporarily (per-session, not durable) |
| GitHub merge queue activation | API gated for personal repos; use chump-integrator batching instead |

---

## 7. Merge-order pyramid

When multiple PRs need to land, this is the order (top first):

```
                    ┌──────────────────────────┐
                    │  1. SUBSTRATE FIXES      │  allowlists, gates, infra
                    │  (admin-merge OK)        │  bypasses self-blocking
                    └──────────────────────────┘
                  ┌────────────────────────────┐
                  │  2. PROPAGATION TRIGGERS    │  rebase wave OR rerun wave
                  │  (mechanical, no review)    │  fan out the substrate fix
                  └────────────────────────────┘
              ┌────────────────────────────────┐
              │  3. KEYSTONE PRs                │  the operator-prioritized
              │  (admin-merge case-by-case)     │  unblockers of many others
              └────────────────────────────────┘
        ┌────────────────────────────────────────┐
        │  4. FEAT/CONTENT PRs                    │  normal auto-merge path
        │  (CI must pass; daemon arms)            │  no admin-merge
        └────────────────────────────────────────┘
  ┌──────────────────────────────────────────────────┐
  │  5. DIRTY (semantic conflicts)                    │  human resolution
  │  (operator-attention queue)                       │  or close-as-stale
  └──────────────────────────────────────────────────┘
```

**Rule:** never land 3 or 4 while substrate (1) is broken — the PRs will queue up needing rebase.

---

## 8. Admin-merge safety gates (when YES, when NO)

`gh pr merge <N> --admin --squash` is the trunk-red rescue hammer. It bypasses required-status-checks. Use rules:

### ✅ Admin-merge OK when ALL hold:
- Failure is **infrastructure-class** (allowlist drift, install-manifest, EMIT-NO-REG, flaky test)
- `cargo-test`, `clippy`, `e2e-pwa` are NOT failing (or are SKIPPED for valid reason like docs-only)
- No operator HOLD label on the PR
- T1-T4 escalation triggers NOT active (per META-207)
- Title prefix matches fix-class allowlist (`fix(/docs(/chore(/hotfix(/ci(/test(/revert(/build(/style(/refactor(/perf(`)
- 0 active leases on PR's claimed paths (don't collide with sibling sub-agents)

### ❌ Admin-merge NOT OK when ANY hold:
- `feat(` class PR with `cargo-test` actually failing
- `mergeStateStatus = DIRTY` (would force over real conflicts)
- Operator HOLD label present
- Single-PR failure (not queue-wide) — that's per-PR triage, not rescue
- Trunk is red on a content-class cause (not infra)

### Special case: META-180 PR-shepherd daemon is allowed to admin-merge
When `pr-shepherd-daemon` classifies a PR as `BLOCKED_GREEN` AND fix-class allowlist matches → it MAY call `gh pr merge --auto --squash` (not --admin). The `--auto` flag waits for required-checks to pass, which is the safety boundary. **The daemon NEVER uses --admin.** Only orchestrators with operator-session auth use --admin.

---

## 9. Daemon coordination matrix (who handles what)

| Daemon | Owns | Hands off to |
|---|---|---|
| `pr-shepherd-daemon` (META-180/181/182/183/184/185/186) | Classify, rebase BEHIND, arm BLOCKED_GREEN, file gaps on BLOCKED_REAL_FAIL | DIRTY → operator-attention queue; trunk-red → safe-mode |
| `auto-merge-rearm-daemon` (INFRA-2309) | Arm `gh pr merge --auto --squash` on CLEAN PRs matching fix-class allowlist | Throws to PR-shepherd if PR is BEHIND not CLEAN |
| `trunk-sentinel-daemon` (INFRA-2324) | Watches main ci.yml; emits trunk_red/trunk_red_persistent on RED past 5min; files a P0 fix-trunk gap; calls operator-recall on RED >60min | fix-trunk-dispatcher (claim path) |
| `fix-trunk-dispatcher` (INFRA-2324 / INFRA-2341) | Pre-empts picker when trunk RED. Claims highest-priority fix_trunk gap, then **(default mode=signal)** emits `fix_trunk_priority_signal` + writes URGENT-INBOX entry so the operator's running IDE picks up the work (respects Max subscription billing). **(opt-in mode=subprocess)** spawns headless `claude -p` — for ANTHROPIC_API_KEY billing without an interactive IDE | inbox-check-urgent (signal mode) / claude -p subshell (subprocess mode) |
| `inbox-check-urgent.sh` (INFRA-2016 / INFRA-2341) | PostToolUse + SessionStart helper: reads `.chump-locks/URGENT-INBOX.jsonl`, surfaces CRIT entries as `<system-reminder>` to the IDE; elevates `kind=fix_trunk_priority_signal` with a banner; emits `fix_trunk_session_acknowledged` on cursor advance | Running IDE session (the operator) |
| `daemon-activator` (META-225) | Auto-install new `install-*.sh` scripts after they merge to main | Nothing — terminal |
| `ghost-pr-closer` (META-225) | Close stale PRs where `gap.status=done AND mergeStateStatus IN (DIRTY,CONFLICTING)` | Nothing |
| `main-worktree-drift-detector` (META-225) | Alert on accumulated drift; file cleanup gap when threshold breached | File gap, no action |
| `chump-integrator` (INFRA-2130) | Batch N `ready_to_ship` gaps into one integration PR | bot-merge for the integration PR |

**Coordination invariants:**
- PR-shepherd does NOT also rearm what auto-merge-rearm handles (double-duty); their fix-class allowlists agree
- Trunk-red guard in PR-shepherd halts ALL action paths simultaneously
- All daemons emit ambient events; observability roll-up at `chump observability tick`

**Trunk-loop dispatch mode trade-off (INFRA-2341):**

The fix-trunk-dispatcher defaults to **signal** mode — it claims the fix-trunk
gap atomically (reserving the worktree), then signals the operator's running
Claude Code IDE via `.chump-locks/URGENT-INBOX.jsonl` instead of spawning a
headless `claude -p`. This respects the operator's Max subscription billing
(no separate console.anthropic.com balance burn). **Caveat:** if NO Claude
Code IDE session is open when the signal lands, the URGENT-INBOX entry sits
waiting until the next session opens. The trunk-sentinel-daemon's 60-min
operator-recall path is the fallback — when no `fix_trunk_session_acknowledged`
event arrives within 60 min of `trunk_red_persistent`, the sentinel calls
`scripts/dispatch/operator-recall.sh` with condition CI_BROKEN so a human
gets paged.

For users who want headless billing (CI fleets, after-hours autonomous
operation), set `CHUMP_FIX_TRUNK_DISPATCH_MODE=subprocess` in the dispatcher's
launchd plist environment — the legacy `claude -p` path is preserved and
emits the existing `fix_trunk_dispatched` event for downstream consumers.

---

## 10. Collision-prone file watch list (the hot-collision files)

Files that get touched by multiple PRs simultaneously. **Use append-only discipline** + Off-Rails-Bypass if you touch from outside claim paths.

| File | Why collisions | Append discipline |
|---|---|---|
| `scripts/ci/raw-gh-allowlist.txt` | Every new daemon adding `gh` needs entry | Append alphabetically; one line per script; comment cites migration gap |
| `scripts/ci/event-registry-reserved.txt` | Every new ambient kind needs entry | Append at bottom under gap-anchored section header |
| `scripts/setup/optional-installers-allowlist.txt` | Every new `install-*.sh` needs entry | Append alphabetically |
| `scripts/setup/bootstrap-manifest.yaml` | Every new daemon needs verify entry | Append as new YAML entry; preserve nesting |
| `docs/observability/EVENT_REGISTRY.yaml` | Every new ambient kind needs entry | Append YAML entry; group by category |
| `.github/workflows/ci.yml` | Many fixes touch CI gates | Edit surgically; run preflight-vs-CI parity check |
| `scripts/ci/preflight-ci-parity-exceptions.txt` | Sister file for ci.yml | Append entry citing the new CI step |
| `.claude/agents/*.md` | Curator role doc updates | Edit sectionally; preserve other curators' role docs |

**Off-Rails-Bypass discipline:** when editing a hot-collision file outside the claim's paths, add commit trailer:
```
Off-Rails-Bypass: <gap-id> needs <file-name>; <reason>
```

---

## 11. Decision flowchart (one-page visual)

```
                    ┌─────────────────────────┐
                    │ QUEUE STUCK PAGED        │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │ §2 TRIAGE: queue shape    │
                    │ + dominant failure surface │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │ ≥70% share same surface?  │
                    └─────────┬──────┬────────┘
                              │YES   │NO
                  ┌───────────┘      └────────────┐
                  ▼                                ▼
       ┌──────────────────────┐    ┌──────────────────────┐
       │ §3 SYSTEMIC ROT      │    │ §4 PER-PR TRIAGE     │
       │ Fix at SOURCE         │    │ Classify each by    │
       │                       │    │ state, daemon       │
       │ Match §5 pattern     │    │ handles MERGEABLE/  │
       │ ↓                     │    │ BEHIND/BLOCKED_*    │
       │ File P0/xs gap       │    │ DIRTY → operator    │
       │ ↓                     │    │ attention queue     │
       │ Surgical edit        │    └──────────────────────┘
       │ canonical file       │
       │ ↓                     │
       │ Admin-merge per §8   │
       │ ↓                     │
       │ §6 Cascade impact:    │
       │  - Allowlist→rebase  │
       │  - Test→rerun         │
       │ ↓                     │
       │ §7 Merge-order pyramid│
       └─────────┬─────────────┘
                 │
                 ▼
        ┌──────────────────────────┐
        │ WAIT for daemon cascade   │
        │ pr-shepherd tick = 60s   │
        │ auto-merge-rearm = 60s   │
        │ CI = 5-15 min/PR         │
        └─────────┬─────────────────┘
                  │
                  ▼
        ┌──────────────────────────┐
        │ Re-run §2 triage.        │
        │ Repeat if dominant surface│
        │ has CHANGED to new pattern│
        └──────────────────────────┘
```

---

## 12. Anti-patterns (don't repeat these)

This session burned operator attention on these. Don't re-burn:

| Anti-pattern | What we should do instead |
|---|---|
| File 26 individual gaps for same fingerprint | META-186 fingerprint dedup handles it; one gap, one fix |
| Rebase 1 PR at a time | Do whole wave: `gh pr list --state open ... | while read n; do gh pr update-branch $n --rebase; done` |
| Trigger 28 reruns without throttling | Mac runners saturate; throttle to ~10 at a time, sleep 30s between batches |
| Mass admin-merge all 28 BLOCKED feat-class | Real cargo-test failures would land. Use §8 gate, only fix-class. |
| Ship a new daemon that uses `gh` without updating allowlist | Every new daemon → allowlist update in the SAME PR |
| Ship a new `install-*.sh` without manifest update | Same → optional-installers-allowlist.txt in the SAME PR |
| Ask the operator "should I admin-merge X?" | T1-T4 (META-207) checks; if none match, broadcast `FEEDBACK kind=proposal` to team |
| File a 27-AC gap then never decompose | Use `chump gap decompose` at claim time per CLAUDE.md two-phase rule |
| Stop the cron / autonomous loop because "nothing to do" | CLAUDE.md Pattern 15: every cycle must ship something. Scan deeper. |

---

## 13. Related docs

- [`CLAUDE.md` → Local CI discipline](../CLAUDE.md#local-ci-discipline-mandatory-infra-1673) — preflight discipline that prevents many of these classes
- [`CLAUDE.md` → Cache-first reads](../CLAUDE.md#cache-first-reads-infra-1081-2026-05-14) — when you need PR data
- [`AGENTS.md` → No-operator-escalation discipline](../../AGENTS.md#no-operator-escalation-discipline-operator-decision-of-record-2026-05-30) — when to ask vs broadcast FEEDBACK
- [`docs/process/SUBAGENT_DISPATCH.md`](./SUBAGENT_DISPATCH.md) — Sonnet dispatch contract; epilogue + checklist
- [`docs/process/SHEPHERD_AUTONOMY_LADDER.md`](./SHEPHERD_AUTONOMY_LADDER.md) — when an unwedging move is safe-without-asking
- [`docs/process/KNOWN_FLAKES.yaml`](./KNOWN_FLAKES.yaml) — auto-retry catalog (INFRA-764)
- [`docs/process/SHIP_ASSIST_PLAYBOOK.md`](./SHIP_ASSIST_PLAYBOOK.md) — wedge taxonomy and tooling inventory
- META-180 PR-shepherd daemon family (sub-slices 181..201)
- META-225 Quartermaster auto-fixers (daemon-activator, ghost-pr-closer, main-worktree-drift-detector)

---

**Doctrine lineage:** Synthesized from 24h of lived-through rescue cycles on 2026-05-30/31. Operator directive verbatim: *"develop a tight procedure document for the agents. they need to know what to fix in what order based on the situation. sequencing PR rescue work and understanding the cascading impacts, file edits, merges, etc. all need to be there..."*
