# Claude Code — session rules for this repo

## MANDATORY: run before anything else

Every Claude session, every time. Do not pick a gap, create a branch, or edit files until these pass.

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
grep -A3 "status: open" docs/gaps.yaml | head -40
scripts/gap-preflight.sh <GAP-ID>     # exits 1 if already done/live-claimed — stop if so
```

Then claim the gap before writing any code:
```bash
# Write gap claim to lease file — NO YAML EDIT, no git push needed:
scripts/gap-claim.sh <GAP-ID>
```

This writes `.chump-locks/<session>.json` with `gap_id` set. Other bots running
`gap-preflight.sh` will see the claim instantly (reads local files — no network).
Claims auto-expire with the session TTL — no stale locks possible.

## Ship pipeline (always use this, not manual git push + gh pr create)

```bash
scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge.
It also writes the gap claim at start and re-checks the gap after rebase.

**Only touch `docs/gaps.yaml` when a gap ships** (set `status: done` + `closed_date`).
Never add `in_progress`, `claimed_by`, or `claimed_at` to gaps.yaml — those fields
are gone. Claims live in lease files now.

## Hard rules

- **Never push directly to `main`.** Branch is `claude/<codename>`, worktree under `.claude/worktrees/<codename>/`.
- **Never start work on a gap without running `gap-preflight.sh` first.** It takes 3 seconds and prevents hours of wasted work.
- **Never leave a lease file behind.** Delete `.chump-locks/<session_id>.json` or call `chump --release` when done.
- **Commit often.** Uncommitted edits are at risk of being overwritten by `git pull`. Stage-commit every 30 minutes of work (`git commit -m "WIP(<GAP-ID>): ..."`).
- **If your branch is more than 15 commits behind main, rebase before continuing.**
- **`CHUMP_GAP_CHECK=0 git push`** — bypass the pre-push gap-preflight hook. Use when gap IDs in commit bodies cause false positives (e.g. a cleanup commit that mentions a gap ID it doesn't implement).

## Pre-commit guards (coordination audit, 2026-04-17)

After install (`./scripts/install-hooks.sh`), every `git commit` runs five checks. Most are silent no-ops; each one fails loud with a bypass hint.

| Check | What it blocks | Bypass env | Why |
|---|---|---|---|
| lease-collision | file claimed by a different live session | `CHUMP_LEASE_CHECK=0` | silent stomps |
| stomp-warning | staged file mtime > 10 min (non-blocking) | `CHUMP_STOMP_WARN=0` | cross-agent staging drift |
| gaps.yaml discipline | adds `status: in_progress` / `claimed_by:` / `claimed_at:` to the YAML | `CHUMP_GAPS_LOCK=0` | claim fields live in `.chump-locks/`, not the ledger |
| cargo-fmt auto-fix | unformatted `.rs` (auto-fixes + re-stages) | — | CI `cargo fmt --check` thrash |
| cargo-check build guard | staged `.rs` fails `cargo check --bin chump --tests` | `CHUMP_CHECK_BUILD=0` | broken-compile commits triggering `fix(ci):` follow-ups |

`git commit --no-verify` bypasses ALL five. Use very sparingly — `--no-verify` is the reason task #58 (Metal crash) and half the duplicate-work incidents shipped.

## Coordination docs

- `docs/gaps.yaml` — master gap registry (claims NOT stored here — only open/done status)
- `docs/AGENT_COORDINATION.md` — full coordination system (leases, branches, failure modes, five-job pre-commit spec)
- `scripts/gap-preflight.sh` — gap availability check (reads lease files + checks done on main)
- `scripts/gap-claim.sh` — write a gap claim to your session's lease file
- `scripts/bot-merge.sh` — ship pipeline (calls gap-claim.sh automatically)
- `scripts/stale-pr-reaper.sh` — runs hourly, auto-closes PRs whose gaps landed on main
- `scripts/git-hooks/pre-commit` — five-job coordination hook (see table above)
- `scripts/git-hooks/pre-push` — gap-preflight gate (blocks pushes with `done`/stolen-claim gap IDs)
