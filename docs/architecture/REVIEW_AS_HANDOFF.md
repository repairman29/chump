# Review-as-Handoff

> Multi-agent code review without an operator in the loop. Reviewer-agents
> diagnose CI failures and post structured fix-payload comments; the
> author-agent (or a free-tier worker) picks up the comment, applies the
> fix, and re-pushes. End-to-end self-heal.

## Provenance

This document captures the design that emerged organically when an
operator-agent review of PR #1349 (EVAL-026) succeeded by:

1. Observing that the PR's `cargo-test` job failed.
2. Reading the failed job log and identifying the root-cause test
   (`src/neuromodulation.rs:340` — a stale `assert!(neuromod_enabled())`
   that depended on a default the PR had flipped).
3. Posting a structured PR comment containing the **exact diff** and a
   one-line explanation.
4. The author-agent (`pensive-wu`, still alive in another worktree) read
   the comment, applied the fix, and committed within ~10 minutes —
   without operator intervention or a new gap.

The pattern is reproducible. This document codifies it as a Chump
primitive so it doesn't depend on a single operator-agent's discipline.

## Mission alignment

| Pillar | Why this is on-mission |
|---|---|
| **EFFECTIVE** | Reduces operator-interruption per CI failure; gives a measurable "% CI failures self-healed" metric that buyers care about. |
| **CREDIBLE** | Every handoff is fully auditable through `ambient.jsonl`. Replayable post-hoc. |
| **RESILIENT** | Dead author? Ambient resurrects a worker. Loop attempt? Cap kicks in. Bad reviewer? ACL filters. |
| **ZERO-WASTE** | Kills the "operator triages every CI failure" tax. |

## What "handoff" means precisely

A handoff is a **structured Markdown PR comment** carrying enough
information for an author-agent to apply a fix without re-deriving the
diagnosis. The contract is the comment template (§3) and the
`[handoff:apply]` annotation (§4).

A handoff is NOT:
- A general PR review comment ("looks good, ship it").
- A vague suggestion ("maybe check the tests in env_flags?").
- A request for changes that needs design judgment.

A handoff is:
- A complete diff or precise instructions for one to a few specific
  edits, accompanied by failure-surface evidence and the rationale.
- A signed assertion by the reviewer that the fix has been verified
  (compiles + tests pass) when applied to a clean checkout of the PR
  branch.

## Comment template

Every handoff comment SHALL contain these four sections, in order:

```markdown
## Failure surface

[copy-paste of the failing test name, panic message, line ref, or
build error. Must be unambiguous about what CI saw.]

## Root cause

[1–3 sentences explaining why the failure occurred. References the
specific code location.]

## Apply this diff

```diff
[a unified diff or a precise edit instruction. If a unified diff,
must apply cleanly to the PR HEAD with `git apply`. If instructions,
must be specific enough that a coding agent can execute mechanically
("rename `foo_default_on` → `foo_default_off`, change line 344 to
`assert!(!neuromod_enabled())`, add `std::env::remove_var(...)`
before the assert").]
```

## Verification

[what the reviewer ran on a clean checkout to confirm the fix works.
Required when the reviewer claims pre-verified status.]

[handoff:apply by=<reviewer-id> verified=<true|false>]
```

The `[handoff:apply]` annotation on the last line is the load-bearing
machine-readable hook. Without it, the comment is advisory only.

## ACL on `[handoff:apply]`

Not every comment is a handoff. Anyone can author a PR comment, but
only **trusted reviewers** can issue `[handoff:apply]`:

- The operator (always trusted).
- An agent role with the `reviewer` capability flag set in its session
  metadata. This is granted at session-start by the operator or by
  `chump review --serve` (the reviewer-role daemon).
- An agent that authored the original PR (self-handoff, e.g. when an
  agent diagnoses its own CI failure mid-session).

A comment from an untrusted source carrying `[handoff:apply]` MUST be
ignored. The author-agent's listener (§5) verifies the source's
capability before acting.

## Author-agent re-engagement loop

When an author-agent finishes (or pauses) a session, before it
relinquishes its lease it SHALL:

1. Run `gh pr list --author @me --state open --json number` to find
   PRs it owns.
2. For each, run `gh pr view --json comments` and scan for handoff
   comments authored after the last commit on the PR HEAD.
3. If a trusted handoff comment exists:
   - Re-claim a worktree on the PR branch (or resurrect via the lease
     coordinator if the original is gone).
   - Apply the diff or follow the instructions.
   - Run the verification command from the comment, plus
     `cargo test --bin chump --tests` (full suite, per INFRA-761).
   - Push if green; emit `kind=review_handoff_applied`.
   - If the verification fails, do NOT loop: emit
     `kind=review_handoff_failed` with the failure details and exit.
     Operator escalates.
4. Cap re-engagements at **1 per PR per worker session**. Subsequent
   handoff comments wait for a new worker.

The session lease MUST remain live through this re-engagement. If the
session has already ended, an ambient watcher (`chump review --resume`)
spawns a fresh worker on the branch.

## Reviewer-role agent

A new run mode: `chump review --serve` — long-running daemon that:

1. Subscribes to `ambient.jsonl` for `kind=pr_check_fail` events.
2. For each, pulls the PR, the failing job logs (via `gh run view
   --log-failed`), and the diff against the PR base.
3. Calls a model (default: configured operator-class — currently Sonnet,
   could route to a free-tier provider via INFRA-733 cascade for cost
   control) with a prompt template anchored on the comment template
   above. The prompt enforces the four-section structure and rejects
   responses that don't conform.
4. If the model produces a viable diff, optionally validates it on a
   throwaway worktree (`git apply --check` + `cargo check`). The
   `verified=` flag in the annotation reflects this validation.
5. Posts the comment via `gh pr comment`. Emits
   `kind=review_handoff_initiated`.
6. Watches for the next push on the branch (15-minute timeout). If
   green, emits `kind=review_handoff_applied`. If still red, emits
   `kind=review_handoff_failed`. If no push, emits
   `kind=review_handoff_timeout`.

Reviewer agents do NOT claim gaps. They are pure feedback agents.

## Telemetry

Five new ambient events. All registered per INFRA-754:

| Kind | Trigger |
|---|---|
| `review_handoff_initiated` | Reviewer posts a `[handoff:apply]` comment |
| `review_handoff_applied` | Author push lands and CI flips green |
| `review_handoff_failed` | Author push lands but CI still red |
| `review_handoff_timeout` | No author push within 15 min of comment |
| `review_handoff_escalated` | Failure or timeout triggers operator notification |

Consumers:

- `fleet-brief` — surface "N PRs self-healed via handoff today" in the
  daily digest.
- `kpi-report` — long-running ratio: `(applied) / (initiated)` is the
  self-heal rate. Target is north of 70%.
- `waste-tally` — `(failed + timeout) / (initiated)` is the
  reviewer-error rate. Target south of 15%.

## Failure modes and mitigations

| Mode | Mitigation |
|---|---|
| Reviewer posts a comment with a wrong fix | The author-agent runs full-suite tests post-apply (INFRA-761 gate). If red, no push, emit `failed`, escalate. The reviewer-error rate above provides the long-running quality signal. |
| Two reviewers post conflicting comments | First trusted comment wins. Author processes only the **earliest** handoff after the last HEAD commit. Later comments are picked up only after the next CI cycle. |
| Author-agent loops on bad fix | Hard cap of 1 re-engagement per PR per worker session. After that, new worker required (and operator gets a `review_handoff_escalated` ping). |
| Reviewer ACL spoofed | Trust check verifies the comment author's GitHub username against the session-metadata reviewer capability — not just the comment annotation. |
| Author session dies before reading comment | `chump review --resume` daemon polls open PRs every 5 min; if a handoff comment is unread for >30 min, it spawns a fresh worker on the branch. |
| Free-tier reviewer model produces malformed comment | Comment template lint (CI-side) rejects comments missing required sections before they post. |

## Build sequencing

This document is the spec for an EFFECTIVE-XXX parent gap that decomposes into:

1. Comment template + Markdown lint (s) — §3.
2. ACL on `[handoff:apply]` annotation (s) — §4.
3. Author-agent re-engagement loop in `worker.sh` (m) — §5.
4. Reviewer-role binary mode `chump review --serve` (m) — §6.
5. Ambient telemetry + fleet-brief integration (xs) — §7.
6. End-to-end smoke test: synthesize a CI failure, verify self-heal
   completes within 15 min (s) — covers §3-§7 integration.

The parent gap should be filed as `EFFECTIVE-XXX` and decomposed via
`chump gap decompose` (the just-shipped PRODUCT-063 feature, dogfooded).

## Open questions

- **Cost.** Reviewer-role calls cost tokens per CI failure. With the
  cascade, route reviewer calls preferentially to free-tier providers
  (Groq Llama 3.3 70B has been adequate for diff-quality work in our
  cascade pilots). This makes the reviewer essentially free at scale.
- **Privacy.** Handoff comments contain code snippets. The cascade
  privacy budget (`CHUMP_ROUND_PRIVACY=safe-only`) governs whether
  trains-tier providers can see them. Default to `safe-only` for
  reviewer calls.
- **Multi-language.** The current diff template assumes Rust. The
  template is language-agnostic; the failure-surface parser may need
  extension for non-cargo CI (Node, Python). Defer until we have a
  non-Rust workload.
