---
doc_tag: contract
owner_gap: INFRA-1044
last_audited: 2026-05-13
companion_docs:
  - docs/process/CHUMP_FIRST_DOCTRINE.md
  - docs/process/AGENTS.md
---

# Agent-Harness Contract

The concrete technical surface any agent harness must implement to ship gaps through Chump's fleet. The *why* lives in [`CHUMP_FIRST_DOCTRINE.md`](CHUMP_FIRST_DOCTRINE.md); this doc is the *what*.

If your harness — Claude Code, opencode-bigpickle, codex, a hand-typed manual loop, or something new — satisfies all five surfaces below, Chump's gap registry + bot-merge + fleet coordination will work for you.

## The 5 contract surfaces

### 1. Prompt I/O

The agent reads its assignment from one of:

- **stdin** — Chump pipes a briefing into the agent process
- **`chump --briefing <GAP-ID>` stdout** — the agent shells out and parses

…and writes intent to **stdout** as it works. No specific framing required, but the agent must respect:

- `CHUMP_BRIEFING_MAX_BYTES` (default 32_768) — truncate input if larger
- One claim = one gap; don't fork mid-session to a different gap

### 2. File mutation tools

The agent must be able to do, scoped to the current worktree:

| Operation | Constraint |
|---|---|
| read file | repo-relative path; reject `..` escape |
| write file | atomic (write to tmp + rename); preserves +x bit |
| edit / patch | apply unified diff or string-replacement |
| glob / list | bounded by `repo_root` |

Implementation is the harness's problem. Claude Code provides `Read`/`Edit`/`Write` tools; opencode-bigpickle uses its own. Manual mode uses the human + editor.

What Chump enforces: the post-commit hook + pre-push gates inspect the **resulting filesystem state**, not how the agent got there.

### 3. Shell execution

Bounded subprocess invocation with `cwd = <worktree>`:

- Timeout supplied by the agent (Chump doesn't dictate)
- Output capture (stdout + stderr) for diagnostic and ambient-stream emission
- Honor `CHUMP_*` env vars the parent process exported (lease, session, gap context)

Why: most coord scripts assume the agent ran from the linked worktree, not the main checkout (INFRA-109, INFRA-779 lessons).

### 4. Git operations

The agent must perform, in the worktree:

- `git add` / `git commit` with an identity the harness owns (CREDIBLE-040 — opencode-bigpickle uses `bigpickle@chump.bot`, Claude Code uses Jeff's identity, manual uses operator's identity)
- `git push origin <branch> --force-with-lease`

**Lease awareness:** before pushing, the agent (or a wrapper) honors the lease state — don't push if `.chump-locks/<session>.json` shows another holder. Use `chump --release` to surrender voluntarily.

**Branch convention:** `chump/<gap-id-lower>-claim` (atomic_claim creates these; harness inherits).

### 5. GitHub (`gh`) operations

- `gh pr create --base main` after the first push
- `gh pr view` to read status
- `gh pr merge --auto --squash` to arm auto-merge after CI passes

The fleet's `bot-merge.sh` handles the auto-merge arming for fleet PRs; manual sessions arm directly. Both are valid.

## Out of scope — Claude-Code-specific dev plumbing

These exist in the repo today but are **not** part of the harness contract. A non-Claude harness ignores them:

| Surface | Why it's Claude-only |
|---|---|
| `PreToolUse` / `PostToolUse` / `SessionStart` hooks | Claude Code event system. Non-Claude harnesses use `chump ambient emit` (INFRA-1048) directly. |
| Slash commands (`/loop`, `/schedule`, `/ultrareview`) | Claude Code operator UX. Other harnesses have their own command surfaces. |
| Sub-agent dispatch (the `Agent` tool) | Claude Code feature. Non-Claude harnesses parallelize via the fleet (multiple workers). |
| Model-router (`claude-opus`, `claude-sonnet`) | Anthropic model identifiers. Other harnesses pick models their own way. |
| `.claude/` directory layout | Claude Code convention. Other harnesses use their own. (See INFRA-1053 — Chump product code should not hardcode this path.) |

## Chump-provided entry points

Every harness uses these — they're the agent-facing API (INFRA-1050 formalizes the spec):

| CLI | Purpose |
|---|---|
| `chump --briefing <GAP-ID>` | One-shot gap context: title, AC, recent ambient events for the gap, sibling PRs |
| `chump --execute-gap <GAP-ID>` | Orchestrated wrapper for hands-off agents — claim, brief, return |
| `chump ambient emit <kind> [...]` | Write to `.chump-locks/ambient.jsonl` (INFRA-1048) |
| `chump gap show <GAP-ID> [--json]` | Registry read |
| `chump gap ship <GAP-ID> [--update-yaml]` | Mark done after merge |
| `chump health --json` | Capability probe — what's wired, what's broken |

## Known harnesses

| Harness | Status | Identity | Notes |
|---|---|---|---|
| **Claude Code** | reference, in fleet | operator's git identity | Default. SDK provides Read/Edit/Bash tools; hooks fire ambient events automatically. |
| **opencode-bigpickle** | exists, ships PRs | `bigpickle@chump.bot` | Jeff's opencode variant. Mixed quality (private operator notes). |
| **manual** | minimum-viable | operator's git identity | `CHUMP_AGENT_HARNESS=manual` (INFRA-956). Operator reads briefing, edits by hand, commits manually. Tests the contract bottom-up. |
| **codex** | planned (INFRA-1054) | TBD | Second canonical non-Anthropic harness; empirical proof of independence. |

## Compliance checklist

Before declaring a harness "Chump-compatible", verify:

- [ ] Reads briefing via stdin OR `chump --briefing` parse
- [ ] Writes commits with a stable, harness-attributed git identity
- [ ] Honors lease state (writes `.chump-locks/<session>.json` or skips push when foreign lease present)
- [ ] Emits to ambient stream — either via `chump ambient emit` (universal) or harness-native hooks
- [ ] Branch follows `chump/<gap-id-lower>-claim` convention
- [ ] At least one end-to-end gap shipped via this harness (claimed → edited → pushed → merged → `chump gap ship` recorded)

Once a harness has ≥10 PRs through it, file a synthesis doc comparing ship-rate, waste-rate, and gap-class coverage against Claude Code (per INFRA-1049 per-harness metrics).
