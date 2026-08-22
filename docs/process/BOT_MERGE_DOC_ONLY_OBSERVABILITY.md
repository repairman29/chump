# bot-merge doc-only fastpath observability (INFRA-920, builds on INFRA-1042/INFRA-1061)

`scripts/coord/bot-merge.sh` auto-detects shell/doc-only diffs (no `.rs`
files, nothing outside `scripts/*`, `docs/*`, `*.md`, `*.yaml`, `*.sh`) and
skips `cargo test` + `cargo clippy` without requiring the caller to pass
`--skip-tests`. This doc is the audit reference: what events it emits, how
cost is tracked, the failure-class taxonomy, and how to smoke-test it.

## Events

All events land in `.chump-locks/ambient.jsonl` (registered in
`docs/observability/EVENT_REGISTRY.yaml`, `effect_metric: self`).

### `kind=bot_merge_doc_only_fastpath`

Emitted once, immediately after detection classifies the diff as doc-only
— i.e. on **success** of the classification (a doc-only diff was found and
tests+clippy were skipped as a result).

```json
{"ts":"...", "kind":"bot_merge_doc_only_fastpath", "branch":"...",
 "files_changed":3, "saved_steps":["cargo_test","cargo_clippy"]}
```

Source: `scripts/coord/bot-merge.sh` (search `bot_merge_doc_only_fastpath`).

### No failure or timeout event exists — by design

Detection is a synchronous, local `git diff --name-only` classification
against already-fetched refs — no network call, no LLM call, no subprocess
that can hang. There is nothing to time out. If `git diff` itself errors
(detached HEAD edge case, corrupt ref, etc.), the command is wrapped
`2>/dev/null || true`, `_changed_files` comes back empty, `DOC_ONLY` stays
`0`, and bot-merge silently falls through to the full test+clippy pipeline
— the safe default. That fallthrough is intentionally unobserved: it's
equivalent to "not doc-only," which is the common case for every Rust PR,
so emitting an event for it would be noise on every non-doc ship rather
than a signal.

## Cost tracking

Zero. The detection is a `git diff --name-only` classification over
already-local refs — no LLM tokens, no network I/O, no billed API call.
The event's value isn't cost avoidance on the detection itself; it's the
**downstream** savings from skipping `cargo test` + `cargo clippy`
(~2-3 min per doc PR — DOC-036 baseline: 2m36s clippy on a 1-line README
diff; INFRA-1038 observed clippy timing out at 245s on some doc PRs before
this fastpath existed). `waste-tally` and `fleet-brief` consume
`saved_steps` + `files_changed` from the event to roll that savings up;
there is no `cost_usd_cents` field because there is no cost to report.

## Failure-class taxonomy

There is exactly one classification outcome pair, not a multi-class
taxonomy, because the detector has no external dependency that can fail
independently of its own logic:

| Outcome | Trigger | Observed as |
|---|---|---|
| `DOC_ONLY=1` (fastpath) | zero `.rs` files changed AND every changed file matches `scripts/*`, `docs/*`, `*.md`, `*.yaml`, `*.sh` | `bot_merge_doc_only_fastpath` event; `SKIP_TESTS` flipped to `1` if not already set by `--fast`/`--skip-tests` |
| `DOC_ONLY=0` (full pipeline) | any `.rs` file changed, OR any file outside the safe-extension allowlist, OR `git diff` itself failed/returned empty | no event; `cargo test` + `cargo clippy` run as normal |

Both outcomes are **permanent, not transient** for a given diff — the
classification is a pure function of `git diff --name-only
$REMOTE/$BASE_BRANCH...HEAD`. Re-running bot-merge against the same commit
always reproduces the same `DOC_ONLY` value; there is no retry-worthy
failure mode to distinguish.

## Smoke test

`bash scripts/ci/test-doc-only-clippy-skip.sh` — asserts, by grepping
`scripts/coord/bot-merge.sh` directly (no live PR needed):

1. `DOC_ONLY=0` initializer and `DOC_ONLY=1` setter are both present
2. detection runs **unconditionally** (`_changed_files=` at column 0, not
   nested inside `if [[ $SKIP_TESTS -eq 0 ]]`) — the INFRA-1061 regression
   check, since the original INFRA-1042 wrap silently disabled doc-only
   detection under `--fast` (which pre-sets `SKIP_TESTS=1`)
3. the `cargo clippy` stage gates on `DOC_ONLY` before the `FAST` /
   full-clippy branches, and in that order
4. the INFRA-920 `SKIP_TESTS=1` setter is still present (no regression)
5. file-count uses `wc -l`, not `grep -c .` (which returns exit 1 on zero
   matches and breaks under `set -o pipefail`)
