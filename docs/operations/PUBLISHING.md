---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Publishing Chump crates to crates.io

This repo is a **workspace**: day-to-day builds use `path` dependencies between members. For **downstream consumers** and for eventually publishing the root binary, each in-workspace dependency also declares a **`version`** (see root `Cargo.toml`). Cargo uses `path` while you are in the tree and uses the registry when you `cargo publish`.

## Security

- **Never paste API tokens in chat, tickets, or commits.** If a token was exposed, [revoke it on crates.io](https://crates.io/settings/tokens) and create a new one.
- Prefer **`CARGO_REGISTRY_TOKEN`** in your **local** shell (or a GitHub Actions **secret** named e.g. `CRATES_IO_TOKEN`) — not `cargo login` on shared machines.

### Variable name Cargo actually reads

**`cargo publish` and `cargo login` do not look at `CRATES_IO_API_KEY`.** The supported environment variable for a crates.io token is **`CARGO_REGISTRY_TOKEN`** (see [Cargo environment variables](https://doc.rust-lang.org/cargo/reference/environment-variables.html)).

If you already store the token in `.env` as `CRATES_IO_API_KEY`, pick one of these:

1. **Duplicate the line** (same secret value) as `CARGO_REGISTRY_TOKEN=…` in `.env`, then before publishing run:
   `set -a && source .env && set +a && cargo publish -p <CRATE>`
2. **Or** keep a single name and export the alias in your shell:
   `set -a && source .env && set +a && export CARGO_REGISTRY_TOKEN="$CRATES_IO_API_KEY"`

The `chump` binary loads `.env` via `dotenvy` for **its** process only; a separate **`cargo publish`** invocation does not load Chump’s `.env` unless your shell has sourced it (as above) or you use `cargo login` once (token then lives in `~/.cargo/credentials.toml`).

## What ships to crates.io today (intent)

| Tier | Crates | Notes |
|------|--------|--------|
| **Libraries (consumer-facing)** | `chump-tool-macro`, `chump-agent-lease`, `chump-mcp-lifecycle`, `chump-cancel-registry`, `chump-perception`, `chump-cost-tracker`, `chump-belief-state`, `chump-messaging`, `chump-coord`, `chump-orchestrator` | Publish in **dependency order** (leaves first). See [INFRA-025-crate-publish-audit.md](eval/INFRA-025-crate-publish-audit.md). |
| **MCP server binaries** | `chump-mcp-*` | **Default: repo-only** (install from git / release artifacts). Publishing them is optional noise on crates.io; dry-run still runs in CI. |
| **Root `chump` package** (binary **`chump`**) | — | Publish with `cargo publish -p chump` once every pinned in-tree dependency version exists on crates.io. (An unrelated third-party crate named **`rust-agent`** also exists on crates.io; this repo does not use that name.) |
| **`chump-desktop`** | — | Not publish-ready (`cargo publish --dry-run` fails until Tauri `frontendDist` packaging is fixed; add `license` in manifest before any publish). |

## One-shot: publish a single crate from your laptop

Replace `<CRATE>` with the package name (e.g. `chump-cost-tracker`).

```bash
cd /path/to/chump
export CARGO_REGISTRY_TOKEN="…"   # from crates.io — paste only in YOUR terminal
cargo publish -p <CRATE>
```

Use **`--dry-run`** until you are satisfied:

```bash
cargo publish -p <CRATE> --dry-run
```

## Recommended first wave (lowest risk)

1. `chump-cost-tracker`
2. `chump-cancel-registry`
3. `chump-perception`
4. `chump-belief-state`
5. `chump-tool-macro`
6. `chump-agent-lease` (bump **0.2.0** on crates.io if you own the crate; registry currently had 0.1.0 at audit time)
7. `chump-mcp-lifecycle` (**0.1.1**)
8. Remaining libraries in any order that respects any new cross-crate path deps (today there are **none** between these members).

After each publish, **`cargo publish -p chump --dry-run --allow-dirty`** (clean tree in CI) should get one step closer. Until every pinned `chump-*` version exists on crates.io, Cargo may error with “candidate versions found which didn’t match” — that is expected until the wave finishes.

## CI

Workflow **`.github/workflows/crates-publish-dry-run.yml`** runs `cargo publish -p … --dry-run` for publish-shaped workspace members (no token required).

## GitHub Actions (optional real publish)

Add repository secret **`CRATES_IO_TOKEN`**. Use a workflow with `cargo publish` only on tagged releases, with manual approval (`environment: production`), not on every PR.

## Ownership

If `cargo publish` says you are not an owner, the crate name may already be taken or owned by another team. Use `cargo owner --list -p <crate>` after `cargo login` to verify.
