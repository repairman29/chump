# Rollup — the converge side of fan-out (INFRA-1455)

> "If my reward for triggering a 12-microservices fan-out is a 40-PR firehose,
> I will uninstall within 72 hours." — Persona-5

`chump fanout` (INFRA-1484) is half of the Marcus M-B story. **This** is the
other half: when the N agents finish, the operator does **not** want N
unrelated PRs. They want to see **strategy classes**: "12 PRs converged on
Strategy A, 2 on Strategy B, 1 blocked."

## Usage

```bash
# Flat list (default — no clustering signal, no false-strategy claims)
chump rollup shared-lib-bump

# Cluster by file-list Jaccard similarity
chump rollup shared-lib-bump --semantic

# JSON for the cockpit / dashboards
chump rollup shared-lib-bump --semantic --json
```

The `<fanout-group>` argument is the `name:` field from your
`chump.fanout.yaml`. Each gap reserved by `chump fanout apply` carries
`fanout_group=<name>` in its `notes`, which is how rollup finds them.

## How clustering works (v1)

1. Find every gap whose `notes` contains `fanout_group=<name>`.
2. For each gap that has `closed_pr`, fetch the touched-file list via
   `gh api repos/{owner}/{repo}/pulls/N/files`.
3. Pair-wise Jaccard similarity over file lists. Pairs with ≥ 0.8
   similarity end up in the same cluster.
4. Sort clusters by size; biggest = "Strategy A", next = "Strategy B", ...
5. Gaps without a closed PR (or whose PR file list is empty) land in
   the **blocked** list with a one-line reason.

## Example output

```
=== chump rollup: shared-lib-bump (12 entries) ===

  ⚙ Strategy A — 9 PR(s) converged on 3 touched file(s)
      INFRA-1700 PR#2210
      INFRA-1701 PR#2211
      INFRA-1702 PR#2212
      ...
      files: src/main.rs, Cargo.toml, scripts/integration.sh

  ⚙ Strategy B — 2 PR(s) converged on 4 touched file(s)
      INFRA-1709 PR#2219
      INFRA-1710 PR#2220
      files: src/main.rs, Cargo.toml, scripts/integration.sh, README.md

  ⚠ blocked: 1
      INFRA-1711 — PR not yet closed
```

## Asymmetric fallback (AC#7)

If the fan-out wasn't actually symmetric (each repo's agent did something
different), Jaccard converges nothing and clustering returns zero strategy
classes. In that case rollup prints **"no semantic clustering signal — see
flat list below"** and falls through to the flat per-gap view. It does
not invent fake strategies; that would be worse than no rollup.

## v1 → v2 (filed as follow-ups)

- **Diff-signature clustering** beyond file-list. Today two PRs that both
  touch `Cargo.toml` cluster together even if one ran `cargo add anyhow`
  and the other ran `cargo add thiserror`. v2 adds AST-signature
  hashing over diffs to split those into different strategies.
- **`chump rollup accept-strategy <name>` auto-merge.** Today the command
  is read-only; AC#5 requires a one-operator-decision merge of all PRs in
  a class. v2 wires `gh pr merge --auto` per class with a confirmation
  prompt.
- **PWA reviewable surface** (AC#4 — side-by-side strategy diffs in
  `chump --web`). Lands in a separate front-end gap.
- **Pluggable provider** today supports the default `gh api` path and an
  in-process fixture for tests. v2 adds a `.chump/github_cache.db` read
  path so rollup works offline against the local PR cache.

## Telemetry

- `kind=rollup_invoked` emitted on every run (fanout_group, semantic,
  strategy_count, blocked_count, entry_count) so the dashboard can show
  rollup adoption alongside fan-out adoption — they should grow
  together if Marcus M-B is landing.
