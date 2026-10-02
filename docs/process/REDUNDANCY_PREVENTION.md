# Redundancy prevention (META-063)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

Before writing a new `*.sh` under `scripts/coord/`, `scripts/ops/`, or
`scripts/dispatch/`, check whether existing files in the same dir already
do most of the work. The 2026-05-14 audit found: 7 worktree-scanning
reapers, 4 stacked `gh` wrapper layers, 8 lease-JSON parsers reinventing
the same regex, 6 CI tests hard-coding `src/gap_store.rs` for content
greps. Each looked unique at filing time but ended up consolidated
retroactively. `pre-commit-redundancy.sh` catches the worst class: bash
function-name shape overlapping Jaccard ≥ 0.6 with an existing sibling.

**Bypass:** for intentional overlap (a deliberate variant that legitimately
can't extend the existing file):
```
Redundancy-OK: <one-sentence reason>
```
Logged to ambient as `kind=redundancy_bypass_used`.

**Recorded exception — the two Thompson-sampling bandits (INFRA-1573).**
`crates/chump-orchestrator/src/thompson.rs` and `src/provider_bandit.rs`
are algorithm-identical Beta(α, β) Thompson samplers with disjoint
vocabularies, kept separate because they sit in different crates with
independent release cadences and concurrency models. See
[`docs/design/ADAPTIVE_ROUTING.md`](../design/ADAPTIVE_ROUTING.md).

Sibling rules: [`RUST_FIRST.md`](./RUST_FIRST.md) (META-064).
