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
scripts/dev/chump-doctor.sh   # heals wedged binary; idempotent; safe
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

**Final report format** — reply with this structure under 250 words:
```
PR number: #NNNN  (or "BLOCKED" + one-line reason)
Files changed: <count>
Tests added: <count or "none">
CI state at hand-off: <green / pending / failed-with-fix-noted>
Open TBDs: <bullet list, or "none">
Notes: <2-3 sentences on tricky calls or recovery paths used>
```
