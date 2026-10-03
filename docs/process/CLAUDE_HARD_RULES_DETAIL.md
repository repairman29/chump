# CLAUDE.md hard-rule detail (ZERO-WASTE-125 archive/expansion)

Moved out of `CLAUDE.md` by ZERO-WASTE-125 (rulebook line-budget cut).
Covers the Claude-Code-specific hard-rule detail that didn't already have
a dedicated doc.

## Two-phase decomposition (don't pre-slice into sub-gaps)

At filing time, write the rough decomposition intent into the gap
*description*, not as filed sub-gaps — sub-gaps filed in advance age badly
as the codebase shifts. At claim time, run `chump gap decompose <ID>` — it
reads the description as LLM context and generates sub-gaps against the
*current* codebase. `--dry-run` inspects the prompt first; `--no-description`
if the description is stale. Never file sub-gaps manually in advance.

## Bootstrap a new product (INFRA-2265, META-067 outcome 3)

```bash
mkdir /tmp/myproject
chump bootstrap "A CLI tool that syncs files across machines" \
  --dir /tmp/myproject --skip-arch-decision
```

## Linked worktree git path confusion (INFRA-779)

On macOS, `/tmp` → `/private/tmp` symlink plus concurrent sibling claims
can corrupt a worktree's gitdir back-reference. Recovery:
`GIT_DIR=<repo>/.git/worktrees/<wt-name> GIT_WORK_TREE=/private/tmp/<wt-name> git <cmd>`.
`chump claim` auto-repairs the gitdir after `git worktree add`.

## `chump gap reserve` title similarity check (INFRA-1149)

Jaccard similarity >= `CHUMP_GAP_RESERVE_SIMILARITY_WARN` (default 0.65)
prompts y/N; >= `CHUMP_GAP_RESERVE_SIMILARITY_BLOCK` (default 0.85) blocks.
Bypass: `--force-duplicate` or `CHUMP_GAP_RESERVE_NO_SIMILARITY=1`.

## Off-rails guard (RESILIENT-025/026)

When a `.chump-locks/claim-*.json` exists, the pre-commit hook blocks any
commit whose subject doesn't contain the claimed gap ID (always on), and
the pre-push hook blocks pushes from the wrong branch. Path-scope
enforcement (RESILIENT-026) only fires when the claim declared paths via
`chump claim --paths CSV`. Disable (rare): `CHUMP_OFF_RAILS_CHECK=0`.

## Fleet scaling gate (INFRA-518)

Scale-up requires: waste rate < 15-20% (`chump waste-tally --window 2h`),
ship rate ≥ 70-80%, zero `fleet_wedge`/`pr_stuck` events in the last 2h.
Back off immediately (no debate) on: a `fleet_wedge` event, `silent_agent`
count > 1/h, `pr_stuck` cluster ≥3/2h, waste rate > 30%, CI failure rate >
25% (last 8 PRs). Every scale change logs to `ambient.jsonl`:

```bash
printf '{"ts":"%s","kind":"fleet_scale_change","from":%d,"to":%d,"rationale":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <old_size> <new_size> "<reason>" \
  >> .chump-locks/ambient.jsonl
```

Rollback: kill excess tmux panes, release orphaned leases, log the
scale-down. Full retrospective:
[`docs/syntheses/fleet-scaling-2026-05-06.md`](../syntheses/fleet-scaling-2026-05-06.md).

## MISSION-PM: gap registry health (META-046)

`chump gap audit-priorities [--json]` — exits non-zero if P0 count > 5, any
open P0 stuck > 7 days, or any vague (no AC) pickable gap exists. Also
reports double-encoded `depends_on`, missing-dep refs, open-with-closed_pr,
and `race-*` test pollution. Run before any PR touching the registry or
picker logic.

## Auth modes (INFRA-622)

| Mode | Env | Notes |
|---|---|---|
| `auto` (default) | — | Prefer `ANTHROPIC_API_KEY`; else OAUTH |
| `api-key` | `CHUMP_AUTH_MODE=api-key` | Force API key; error if absent |
| `oauth` | `CHUMP_AUTH_MODE=oauth` | Force subscription token; error if absent |

Workers re-evaluate credentials before each `claude -p` spawn. The OAUTH
refresher daemon (`scripts/coord/oauth-token-refresh.sh`, launchd
`com.chump.oauth-refresh.plist`, 5-min cadence) must be *loaded*, not just
installed — verify with `launchctl list | grep com.chump.oauth-refresh`.
macOS-only (Keychain-backed); Linux gets a loud
`kind=oauth_refresh_unsupported_platform` error. Validate overall:
`chump fleet doctor`.

## GitHub credentials for agents (INFRA-AGENT-CREDS)

Implicit (local dev): agent inherits `gh` keyring + SSH keys — breaks in
Docker/sandboxed workers. Explicit (production):

```bash
export GH_TOKEN="ghp_..."
export SSH_KEY_PATH="~/.ssh/id_ed25519"
GH_TOKEN="..." chump --execute-gap <ID>
```

Credential values never appear in logs; falls back to keyring if unset.

## Local CI discipline — manual steps until `chump preflight` covers everything

```bash
cd <worktree>
PATH=$HOME/.cargo/bin:$PATH cargo fmt --all -- --check
PATH=$HOME/.cargo/bin:$PATH cargo clippy --workspace --all-targets -- -D warnings
PATH=$HOME/.cargo/bin:$PATH cargo check --workspace
# Then any scripts/ci/test-*.sh that match files you touched.
```

No blanket agent-side skip exists (the global preflight skip var was
deleted per INFRA-2422). When origin/main itself is failing a gate,
`chump preflight` reads `.chump/main-preflight-state.json` and
auto-skips only the already-failing gates.

## Rust-first vs. shell-OK bypass trailer

See [`RUST_FIRST.md`](./RUST_FIRST.md) for the full criteria; the bypass
trailer is `Rust-First-Bypass: <reason>`, enforced by
`scripts/git-hooks/pre-commit-rust-first.sh`.

## Cache-first reads (INFRA-1081)

Default to `cache_lookup_pr` / `sqlite3 .chump/github_cache.db`; `gh pr
view` / `gh api` only on cache miss. Setup + healthcheck:
[`OPERATOR_PLAYBOOK.md §7.5`](./OPERATOR_PLAYBOOK.md#75-local-infrastructure--webhook--smee--cache--docker).
Already-migrated callers: queue-driver.sh, bot-merge.sh overlap scan,
pr-rescue.sh, chump-ambient-glance.sh.
