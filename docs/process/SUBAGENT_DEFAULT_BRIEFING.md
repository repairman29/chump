# Subagent default briefing prefix (META-028)

This file is the standard prefix prepended to every `Agent`-tool prompt in Chump.
Load it via: `cat "$(scripts/lib/get-agent-briefing-prefix.sh)"` or override with
`CHUMP_AGENT_DEFAULT_PREFIX=<path>`.

---

## Execution contract (read before anything else)

- **No clarifying questions.** You have everything you need. If something is
  ambiguous, make the most reasonable call, note it in your final report, and
  keep moving. Do not stop to ask.
- **Auto-decide on ambiguous AC.** If an acceptance criterion is vague, apply
  the most conservative interpretation that still satisfies the letter of the
  criterion. Document your interpretation in one line; do not pause.
- **Scope is fixed.** Do not expand beyond the deliverables listed. Do not
  do adjacent cleanup, refactors, or "while I'm here" changes.
- **Ship or report BLOCKED.** Every session ends with either a PR number or
  a one-line BLOCKED reason. "I wasn't sure" is not a valid BLOCKED reason —
  make the call and ship.

## Agent vs SendMessage discipline

- **`Agent`** spawns a **new** subagent with no context from this conversation.
  Use it only for genuinely independent work.
- **`SendMessage`** resumes an **existing** subagent with full context.
  Always prefer `SendMessage` over spawning a second `Agent` for the same task.
  Spawning a second `Agent` for a running task wastes a slot and loses state.

## chump-doctor heal pattern

If `chump gap …` or `bot-merge.sh` hangs > 30s (no output, no progress):

```bash
scripts/dev/chump-binary-unwedge.sh   # heals wedged binary; idempotent; safe
```

## Falsifying-condition discipline

Before implementing any feature, state the falsifying condition — the observation
that would prove it wrong or unnecessary. If the condition is met, close as
"superseded" rather than implementing.

## Manual-recovery wall-clock budget: 10 minutes

If the canonical ship path (`bot-merge.sh --auto-merge`) is blocked for more than
10 minutes, switch to manual recovery immediately. Do not keep retrying the same
command. Recovery path:

```bash
# 1. Push branch
CHUMP_BYPASS_BOT_MERGE=1 git push -u origin <your-branch> --force-with-lease

# 2. Open PR
gh pr create --base main --title "<title>" --body "<body>"

# 3. Arm auto-merge
gh pr merge <PR-number> --auto --squash

# 4. Close gap (if stuck, skip — batcher will catch up)
chump gap ship <GAP-ID> --closed-pr <PR-number> --update-yaml
```

## Shipping (CRITICAL — read in full before ending)

```bash
# Canonical path:
scripts/coord/bot-merge.sh --gap <YOUR-GAP-ID> --auto-merge
```

## Fleet quality rules (opencode coaching set — 2026-05-13)

Ten rules distilled from the most common failure modes in the opencode-bigpickle harness:

1. **Title-vs-diff sanity check.** Read `git diff --stat origin/main..HEAD` before
   committing. The diff must implement what the title claims and nothing else.

2. **Run the gate locally before push.** `bash scripts/ci/<test-for-your-gap>.sh` must
   exit 0 on your machine before you touch `git push` or `bot-merge.sh`.

3. **No hardcoded wall-clock fixtures.** Tests must not contain literal future dates or
   sleep durations. Use `$NOW`, env vars, or relative offsets. Hardcoded dates cause
   CI flakes after they expire.

4. **GNU-first, then BSD fallback.** Scripts must work on Linux. Use
   `date -u +%Y-%m-%dT%H:%M:%SZ` (GNU). If macOS `date -r` is needed, guard it:
   `command -v gdate && gdate ... || date ...`.

5. **Bypass-with-why.** Every `CHUMP_*=0` or `--no-verify` bypass requires a trailer
   explaining why: `Event-Registry-Bypass: <reason>`, `Test-Gate-Bypass: <reason>`.
   No silent bypasses — they mask real failures.

6. **No ci.yml reorder.** Never reorder existing job steps in `.github/workflows/ci.yml`
   unless the gap explicitly targets CI structure. Step reordering invalidates the
   `cancel-in-progress` group semantics and breaks the green-main signal.

7. **Verify YAML mirror lands.** After `chump gap ship`, run `chump gap show <ID>` and
   confirm `closed_pr:` is set and `docs/gaps/<ID>.yaml` reflects `status: done`.

8. **Pillar prefix in title.** Every new gap title must start with `EFFECTIVE:`,
   `CREDIBLE:`, `RESILIENT:`, or `ZERO-WASTE:` so `chump mission-grade` can tally it.

9. **One-gap-one-PR.** One PR = one logical gap. Bundling multiple gaps into a PR
   confuses `chump gap ship` and triggers the INFRA-996 dup-PR guard. Exception:
   a parent gap whose AC explicitly decomposes child gaps.

10. **Ambient pre-pickup.** Before claiming any gap, glance at
    `tail -30 .chump-locks/ambient.jsonl` for `lease_overlap`, `pr_stuck`,
    `edit_burst`. If any signal is hot, address it before picking new work.

**Final report format** — reply with this structure under 250 words:
```
PR number: #NNNN  (or "BLOCKED" + one-line reason)
Files changed: <count>
Tests added: <count or "none">
CI state at hand-off: <green / pending / failed-with-fix-noted>
Open TBDs: <bullet list, or "none">
Notes: <2-3 sentences on tricky calls or recovery paths used>
```
