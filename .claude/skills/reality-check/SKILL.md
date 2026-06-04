---
name: reality-check
description: >-
  Reality-check gate before acting on any ALARM-CLASS belief — "X is down / dead
  / blocked / broken / halted / starved". A detector firing is a SIGNAL, not an
  OUTCOME; this gate forces you to verify the outcome the belief would CAUSE
  against ground truth (is the fleet actually still shipping? is trunk green?)
  and to check whether the signal is a known false-positive, BEFORE you broadcast
  or act. Thin wrapper over scripts/dev/reality-check.sh (CREDIBLE-090). Use when
  you're about to declare/broadcast an outage, stop a loop, page the operator, or
  otherwise act on "the fleet/auth/CI/queue is broken" — ESPECIALLY before any
  halt-class action. Born from the 2026-06-04 auth-dead misdiagnosis (acted on
  AUTH_DEAD false-positives for hours while the fleet shipped 99 PRs).
---

# reality-check

**A SIGNAL is not an OUTCOME.** Before you act on "X is down/dead/blocked/broken",
run the gate:

```bash
scripts/dev/reality-check.sh "<belief>" [--detector <kind>] [--halt-class]
```

What it does (the 5-step gate):
1. Names the belief + the signal that triggered it.
2. States the outcome the belief *predicts* (fleet stops shipping / trunk red).
3. Checks **ground truth** — recent merges (is the fleet actually shipping?) + trunk status.
4. Checks **signal reliability** — is there an OPEN gap marking this detector a false-positive?
5. **Verdict** — exit `1` REFUTED (stand down), `0` CONFIRMED (proceed), `2` UNVERIFIED.

Rules:
- **Never broadcast or act on an alarm-class belief until reality-check returns CONFIRMED.**
- A `--halt-class` belief (declare outage / stop the fleet / page the operator) additionally
  requires a **fresh-eyes (or peer) confirm** — a single session may not act on it alone.
- If the detector has an open false-positive gap, **fix the detector, don't act on its output.**

Full procedure + case study: `docs/process/REALITY_CHECK.md`.

Examples that should trigger this skill: "is the fleet really down?", "before I declare CI broken",
"reality-check the auth-dead alert", "should I stop the loop / page the operator", "verify this outage
is real".
