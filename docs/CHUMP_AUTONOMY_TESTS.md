# Chump Autonomy Tests

Test suite and acceptance criteria for autonomous operation. Complements [BATTLE_QA.md](BATTLE_QA.md) (which tests single-session correctness) with multi-session and end-to-end autonomy scenarios.

## Test categories

### T1 — Single-session task completion

Verify Chump can complete a task without human intervention from task submit to PR merged.

```bash
# Run T1 smoke suite (5 tasks, cloud model)
scripts/battle-qa.sh --max 5 --autonomy-mode

# Acceptance: ≥ 4/5 pass (80%)
```

Tasks in suite:
- T1-1: List open gaps → pick a docs gap → open PR (no code change)
- T1-2: Run `cargo test` → summarize failures in a comment
- T1-3: Answer a factual question about the codebase
- T1-4: Create a new note in `brain/notes/` and commit
- T1-5: Run `battle-qa.sh --max 3` and report results to Discord

### T2 — Gap lifecycle

Full gap lifecycle: claim → implement → PR → CI → merge → release lease.

```bash
# Claim a known-safe test gap
scripts/gap-claim.sh TEST-001

# Implement a trivial change
echo "# test $(date)" >> docs/SCRATCH.md
scripts/chump-commit.sh docs/SCRATCH.md -m "test(autonomy): T2 gap lifecycle test"

# Ship
scripts/bot-merge.sh --gap TEST-001 --auto-merge
```

**Acceptance:** PR opened, CI green, auto-merge armed, lease released within 10 minutes.

### T3 — Mabel peer approval

Test the full peer-approval path (Mac → Mabel → approve → proceed).

Prerequisites: Mabel online, `CHUMP_PEER_APPROVE_TOOLS=merge_pr` set.

1. Trigger a `merge_pr` tool call from Mac
2. Mabel's Verify round picks up `brain/a2a/pending_approval.json`
3. Mabel SSHs to Mac, runs `cargo test`
4. Mabel calls `POST /api/approve`
5. Chump logs "peer approved" and proceeds

**Acceptance:** PR merged within 15 minutes without human interaction.

### T4 — Multi-session coordination

Two concurrent agent sessions must not claim the same gap or stomp each other's files.

```bash
# Session A (in worktree-A)
CHUMP_SESSION_ID=session-A scripts/gap-claim.sh EVAL-035

# Session B (in worktree-B) — should be rejected
CHUMP_SESSION_ID=session-B scripts/gap-preflight.sh EVAL-035
# Expected: exits 1 with "gap claimed by session-A"
```

**Acceptance:** Session B blocked; ambient.jsonl shows `lease_overlap` ALERT.

## CI integration

The T1 smoke suite runs in CI on PRs that touch `src/` (not docs-only):

```yaml
# .github/workflows/autonomy-smoke.yml
- run: scripts/battle-qa.sh --max 3 --timeout 300
```

## See Also

- [BATTLE_QA.md](BATTLE_QA.md) — battle-qa.sh reference
- [AGENT_COORDINATION.md](AGENT_COORDINATION.md) — lease system
- [SOAK_72H_LOG.md](SOAK_72H_LOG.md) — extended stability runs
- [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) — PR workflow
