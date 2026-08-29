# `chump pr explain-block <PR>` observability (INFRA-1647, re-do of INFRA-1416)

`chump pr explain-block <PR#> [--json]` (`src/pr_explain.rs`) produces a
single coherent explanation for a stuck PR — classifying each blocking
check as `local` / `sibling_blocked` / `fleet_wide` and giving a next
mechanical action per row. This doc is the audit reference: what events
it emits, how cost is tracked, the failure-class taxonomy, and how to
smoke-test it.

## Events

**None are emitted.** `chump pr explain-block` is a synchronous,
read-only diagnostic — it prints a report to stdout (or `--json`) and
exits. It has no side effect on fleet state (`state.db`,
`.chump-locks/*.json`, `docs/gaps/*.yaml`), so there is nothing for a
downstream consumer (`waste-tally`, `fleet-brief`, a detector) to roll up
by watching `ambient.jsonl`. This mirrors the `bot-merge` doc-only
fastpath precedent (INFRA-920): a deterministic local classification with
no state mutation does not need an ambient event — the event's only
purpose would be to prove the command ran, and the operator already knows
that because they ran it interactively and read the output.

If `chump pr explain-block` grows a caller that invokes it unattended
(e.g. shepherd's PR-rescue loop shelling out to it instead of raw `gh pr
view`), that caller is the right place to emit an event (e.g.
`kind=pr_explain_block_invoked` with the resulting `overall` tag), not
`pr_explain.rs` itself — the library function is reused by both
interactive and future automated callers, and only the automated path
has an audience for a machine-readable trace.

## Cost tracking

Zero LLM cost — `pr_explain.rs` makes no model call. Its only cost is two
`gh` CLI invocations per run:

1. `gh pr view <PR#> --json statusCheckRollup` (`gh_rollup_provider`,
   `src/pr_explain.rs:193-210`) — one call for the target PR.
2. `gh pr list --state open --limit 100 --json
   number,statusCheckRollup` (`gh_fleet_failing_provider` →
   `build_fleet_failing_map`, `src/pr_explain.rs:214-282`) — one call,
   cached in-process (`RefCell<Option<HashMap<...>>>`) so a report with N
   blocking checks still only pays for a single fleet-wide list fetch,
   not N.

Both are REST-shaped `gh` calls, not GraphQL, so they draw from the REST
core rate-limit bucket rather than the GraphQL bucket that
`graphql_exhausted` cascades drain (see CLAUDE.md § GraphQL exhaustion
handling). There is no `cost_usd_cents` to report because there is no
billed API call — the "cost" that matters here is the ~2 `gh` calls this
command replaces the "~6× manual `gh pr view ... statusCheckRollup`
digging" pattern documented in the file's own header comment
(`src/pr_explain.rs:1-3`) with.

## Failure-class taxonomy

| Outcome | Trigger | Transient or permanent | Observed as |
|---|---|---|---|
| Empty rollup / hard error | `gh pr view` fails, PR doesn't exist, or caller isn't authenticated | Transient (auth/network) or permanent (bad PR number) — indistinguishable from the error alone | `Err(anyhow!("no statusCheckRollup for PR #{pr_number} — does it exist? are you authenticated?"))` (`src/pr_explain.rs:289-293`); process exits non-zero, printed to stderr in `main.rs` |
| `overall: green` | every row is `SUCCESS`/`NEUTRAL`/`SKIPPED`, or `conclusion` empty with `status: COMPLETED` | N/A — success state, not a failure class | `summary: "all checks green or in progress — no mechanical action needed"` |
| `overall: local` | ≥1 blocking check with zero (or all-self) matching failures elsewhere in the fleet | Permanent for the current diff — same fix (clippy/fmt/test/rebase per `local_action_hint`, `src/pr_explain.rs:166-190`) applies until the author pushes | per-row `next_action` hint, e.g. `"fix locally: cargo clippy --workspace --all-targets -- -D warnings, then push"` |
| `overall: sibling_blocked` | 1–2 other open PRs also failing the same check name | Transient — resolves once the first sibling merges and this PR rebases | `"sibling PRs also failing '<check>': #A, #B — likely shared root cause; rebase after the first one merges"` |
| `overall: fleet_wide` | ≥`FLEET_WIDE_THRESHOLD` (3, `src/pr_explain.rs:21`) other open PRs also failing the same check name | Transient at the fleet level, but blocking for every affected PR until a keystone fix lands | `"fleet-wide failure on '<check>' (N other PRs also red) — wait for keystone fix or file P0; see kind=ci_failure_cluster ambient events"` |
| Pending check | `status` is `QUEUED` or `IN_PROGRESS` | Transient by construction | classified `local`, `next_action: "pending — let CI finish before debugging"` |

`overall` is the max-severity row across the report (`fleet_wide` >
`sibling_blocked` > `local` > `green`, `update_worst_scope`,
`src/pr_explain.rs:118-130`), so a PR with one local clippy failure and
one fleet-wide failure reports `overall: fleet_wide` — the operator
should chase the fleet-wide row first since fixing the local one alone
won't unblock the PR.

## Smoke test

`bash scripts/ci/test-pr-explain-block.sh` (pre-existing, INFRA-1416) —
asserts, without a live PR:

1. `src/pr_explain.rs` exists and exports `ExplainReport`, `CheckRow`,
   `build_report`, `render_text`, `run`, `FLEET_WIDE_THRESHOLD`
2. `src/main.rs` declares `mod pr_explain;` and dispatches
   `Some("explain-block")`
3. `cargo test --bin chump pr_explain -- --test-threads=1` — runs the 8
   unit tests in `src/pr_explain.rs`'s `#[cfg(test)] mod tests`, covering
   green/local/sibling/fleet-wide classification, self-PR exclusion from
   sibling counts, pending-check advice, and text rendering.

To exercise the live-`gh` path against a real PR (not covered by the
smoke test, which is fixture-only):

```bash
chump pr explain-block <PR#>          # human-readable
chump pr explain-block <PR#> --json   # machine-readable ExplainReport
```
