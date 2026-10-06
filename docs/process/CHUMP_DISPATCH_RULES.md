---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump dispatch rules — injected into every autonomous agent prompt

> This file is read programmatically by `dispatch.rs` and `execute_gap.rs` and
> injected verbatim into the system prompt for every Chump-dispatched agent
> (both `claude` and `chump-local` backends). Keep it under 60 lines.
> Full rules in CLAUDE.md; AGENTS.md is the cross-tool canonical entry point.

## SCOPE INVARIANTS (defense-in-depth)

- **Refuse SWARM-, PRIVATE-, INTERNAL- prefixed gaps.** If the gap ID starts with `SWARM-`, `PRIVATE-`, or `INTERNAL-`, immediately reply `SCOPE-REFUSE: this gap domain is out of scope` and exit. These are proprietary/internal domains.
- **Refuse files outside gap.paths.** If the gap YAML specifies a `paths:` list, only edit files within those paths. Refuse edits outside with `SCOPE-REFUSE: edit target outside gap.paths`.
- **Refuse Cargo.toml dependency additions without explicit operator approval.** Adding new deps to Cargo.toml requires the gap acceptance criteria to explicitly list the dep. Refuse with `SCOPE-REFUSE: new Cargo dep requires gap AC approval`.

## Hard rules (no exceptions)

- **Never push to `main`.** Branch is `claude/<codename>`, worktree under `.claude/worktrees/<codename>/`.
- **Commit with `scripts/coord/chump-commit.sh <file1> [file2] -m "msg"`**, not bare `git add && git commit`. The wrapper prevents cross-agent staging drift.
- **Run `cargo fmt --all` before committing any `.rs` file.** The pre-commit hook does it, but if you bypass with `--no-verify` you must run it manually. CI fails on unformatted code.
- **Atomic PR discipline.** Once `bot-merge.sh` runs, do NOT push more commits to that branch. Open a new worktree for follow-on work.
- **Never leave a lease file behind.** `bot-merge.sh` handles cleanup. If you abort early, run `chump --release`.

## Ship pipeline

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge. Do not run `git push` or `gh pr create` manually.

## Research integrity

Before touching any eval fixture, cognitive-architecture code, or research claim:

- Read `docs/process/RESEARCH_INTEGRITY.md`. The accurate thesis is narrower than what CHUMP_PROJECT_BRIEF.md and CHUMP_RESEARCH_BRIEF.md say.
- Do not write "cognitive architecture is validated" — individual modules (surprisal, belief state, neuromod) are unablated.
- Do not write "Surprisal EMA: Confirmed" — that claim is unsupported pending EVAL-043.
- Any eval delta from n<100 or Anthropic-only judges must be described as "preliminary".

## Coordination

- The gap is already claimed in this worktree when this prompt is injected.
- Read `docs/gaps.yaml` for the gap's acceptance criteria.
- Check `.chump-locks/ambient.jsonl` for recent activity from sibling sessions.
- Use `CHUMP_GAP_CHECK=0 git push` only when gap IDs in commit bodies cause false positives on the pre-push hook.

## Picker policy: single source (INFRA-8060)

Picker-side policy that also belongs on the Rust `GapBriefing` lives in
`scripts/dispatch/picker-policy.json`, read by both `src/briefing.rs`
(`load_sync_overhead_ceiling`) and `scripts/dispatch/_pick_gap.py`
(`_picker_policy`). An upper-case env var of the same name overrides the file
for one run (e.g. `SYNC_OVERHEAD_CEILING`). Add new briefing-driven policy to
that file instead of a new env var plus a mirror field.

Audit of the other env-var policies read by `_pick_gap.py` (no Rust mirror
field exists for any of them, so there is no drift today; nothing moved):

| Env var | Kind | Verdict |
|---|---|---|
| `FLEET_COOLDOWN_THRESHOLD` | numeric policy (default 3) | candidate for `picker-policy.json` if the briefing ever needs it |
| `CHUMP_MIXED_FLEET_XS_GATE` | feature flag | stays an env flag |
| `CHUMP_ACTIVE_MISSION` | per-run mission selector | stays an env var (runtime input) |
| `FLEET_MODEL`, `EXCLUDE_RE`, `ACTIVE_GAPS`, `COOLDOWN_DIR`, `WORKER_*` | per-worker runtime inputs | stay env vars |
