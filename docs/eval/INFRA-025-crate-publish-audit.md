# INFRA-025 — Crate publish audit (Phase 1)

**Date:** 2026-04-22  
**Scope:** Workspace members from root `Cargo.toml` `[workspace].members`, plus the root package (`rust-agent`) that hosts the `chump` binary. Out of scope for this pass: `examples/*`, `wasm/*`, `repos/*`, `tests/mock_projects/*` (not workspace members).

**MSRV:** No repo-root `rust-toolchain.toml` today. CI uses `dtolnay/rust-toolchain@stable` (`.github/workflows/ci.yml` and siblings). **Gap:** declare `package.rust-version` on publish candidates before first real publish, and align CI with a pinned MSRV job if we commit to one.

## Summary

| Bucket | Count | Notes |
|--------|------:|-------|
| Publish candidates (library-shaped, dry-run OK) | 13 | All `crates/chump-*` workspace libs + `chump-tool-macro`; MCP server *binaries* technically dry-run but see policy below |
| Monolith / not crates.io-shaped | 1 | `rust-agent` — path-only workspace deps; also **crates.io name `rust-agent` is already taken** by another crate (unrelated). Renaming would be a separate product decision |
| Desktop / packaging blocker | 1 | `chump-desktop` — `cargo publish --dry-run` fails in verify: Tauri `frontendDist` path missing in packaged tarball |
| Policy: keep repo-only | 5 | `chump-mcp-*` — gap text marks MCP binaries as repo-only unless explicitly decided; they dry-run today but add noise on crates.io |

**crates.io name check** (HTTP GET `https://crates.io/api/v1/crates/<name>`, 404 = name appears free as of audit date):

| Crate | On crates.io? |
|-------|---------------|
| `chump-agent-lease` | Yes — published `0.1.0`; workspace is `0.2.0` (semver path clear) |
| `chump-mcp-lifecycle` | Yes — `0.1.0`; workspace `0.1.1` |
| `rust-agent` | Yes — **foreign** crate at `0.0.5`; not this repo |
| Other `chump-*` in table below | No 404 → treat as **unreserved** until first publish |

## Per-crate table

**Legend:** **P** = publish candidate, **I** = internal / monolith, **R** = repo-only by policy, **B** = blocked on packaging. License = SPDX from `Cargo.toml`. Dry-run = `cargo publish -p <name> --dry-run` from repo root on audit date.

| Crate | Path | Class | License | `readme` | `homepage` | `rust-version` | Dry-run | crates.io name |
|-------|------|-------|---------|----------|------------|------------------|---------|----------------|
| `rust-agent` | `.` | **I** | MIT | yes | yes | — | **Fail** — path deps lack version for publish | Taken (other project) |
| `chump-tool-macro` | `chump-tool-macro/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-agent-lease` | `crates/chump-agent-lease/` | **P** | MIT | yes | yes | — | Pass | Taken (this line of crates; bump to 0.2.0 on publish) |
| `chump-mcp-lifecycle` | `crates/chump-mcp-lifecycle/` | **P** | MIT | yes | yes | — | Pass | Taken |
| `chump-cancel-registry` | `crates/chump-cancel-registry/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-perception` | `crates/chump-perception/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-cost-tracker` | `crates/chump-cost-tracker/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-belief-state` | `crates/chump-belief-state/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-messaging` | `crates/chump-messaging/` | **P** | MIT | yes | yes | — | Pass | Free |
| `chump-coord` | `crates/chump-coord/` | **P** | MIT | no | no | — | Pass | Free |
| `chump-orchestrator` | `crates/chump-orchestrator/` | **P** | MIT | no | no | — | Pass | Free |
| `chump-mcp-github` | `crates/mcp-servers/chump-mcp-github/` | **R** / **P?** | MIT | yes | yes | — | Pass | Free |
| `chump-mcp-tavily` | `crates/mcp-servers/chump-mcp-tavily/` | **R** / **P?** | MIT | yes | yes | — | Not re-run; same shape as github | Free |
| `chump-mcp-adb` | `crates/mcp-servers/chump-mcp-adb/` | **R** / **P?** | MIT | yes | yes | — | Not re-run | Free |
| `chump-mcp-gaps` | `crates/mcp-servers/chump-mcp-gaps/` | **R** / **P?** | MIT | yes | yes | — | Not re-run | Free |
| `chump-mcp-eval` | `crates/mcp-servers/chump-mcp-eval/` | **R** / **P?** | MIT | yes | yes | — | Not re-run | Free |
| `chump-desktop` | `desktop/src-tauri/` | **B** | *missing in manifest* | no | no | 1.77.2 | **Fail** — Tauri `frontendDist` | Free |

## Dry-run failure detail

### `rust-agent`

```
all dependencies must have a version requirement specified when publishing.
dependency `chump-agent-lease` does not specify a version
```

Publishing the app requires either crates.io versions for all `chump-*` path deps or a split workspace (published libs first, then version pins in root).

### `chump-desktop`

Compile error during verify: `frontendDist` set to `"../../web"` but path absent in packaged crate tree. Fix would be Tauri-specific packaging (embed dist, or publish only from a release job that materializes `web/`).

## Recommended publish order (topological intuition)

1. **Leaves:** `chump-cost-tracker`, `chump-cancel-registry`, `chump-perception`, `chump-belief-state`  
2. **Small deps:** `chump-tool-macro` (proc-macro; no internal chump deps)  
3. **`chump-agent-lease`** — already on crates.io; next publish should align `0.2.0` + changelog  
4. **`chump-mcp-lifecycle`**, **`chump-messaging`**, **`chump-coord`**, **`chump-orchestrator`** — verify public API surface before 0.1.0 commitment  
5. **Root `rust-agent`** — last; rename consideration if crates.io distribution is ever desired  

## Phase 2+ (remaining INFRA-025 acceptance)

Not done in this document: CI `cargo publish --dry-run` gate per touched crate, `cargo audit` / `cargo outdated` policy, release-plz wiring, placeholder publishes for squatting, CLAUDE/AGENTS publish-hygiene rules.

## References

- Gap definition: `docs/gaps.yaml` — `INFRA-025`
- Workspace manifest: `Cargo.toml`
