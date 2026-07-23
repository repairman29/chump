# Librarian sweep observability (INFRA-1781, INFRA-1746 phase 1b)

`chump audit librarian-sweep <target-repo> [--budget-usd N] [--json]`
(`src/ingest_librarian.rs`) runs a static, read-only dead-code/redundant-script
triage pass against a *target* repo — the Phase 1 half of the ingest pipeline
that `chump cartograph` (INFRA-1782, Phase 2) later documents architecturally.
This doc is the audit reference: what events it emits, how cost is tracked,
the failure-class taxonomy, and how to smoke-test it.

## Events

All events land in `.chump-locks/ambient.jsonl` (registered in
`docs/observability/EVENT_REGISTRY.yaml`, `effect_metric: self`).

### `kind=ingest_librarian_started`

Emitted once per invocation, before the sweep walks the target tree.

```json
{"ts":"...", "kind":"ingest_librarian_started", "target_repo_path":"/path/to/target"}
```

### `kind=ingest_librarian_completed`

Emitted on success, after `<target>/.chump-ingest/triage.md` has been
written.

```json
{"ts":"...", "kind":"ingest_librarian_completed", "target_repo_path":"...",
 "files_scanned":123, "dead_code_candidate_count":4,
 "redundant_script_group_count":1, "cost_usd_cents":0, "elapsed_ms":37}
```

### `kind=ingest_librarian_failed`

Emitted when the sweep aborts before producing a report. Carries
`failure_class` (see taxonomy below) and `transient` so a caller can decide
retry vs. surface-to-operator without string-matching `message`.

```json
{"ts":"...", "kind":"ingest_librarian_failed", "target_repo_path":"...",
 "failure_class":"path_not_found", "transient":false, "message":"..."}
```

Source: `src/ingest_librarian.rs::emit_started|emit_completed|emit_failed`.

## Cost tracking

The sweep is entirely static heuristics against the target's file tree
(dead-code-stem matching + byte-identical-script hashing) — it makes zero
LLM or network calls. `cost_usd_cents` is always `0` and is reported in
`ingest_librarian_completed` for parity with other ingest-pipeline phases
that *do* spend budget, so a downstream cost rollup (e.g. `chump ingest`'s
own accounting) can sum phases without special-casing "phase 1 is free."
`--budget-usd` is validated (must be a positive finite number) but not
metered against, since nothing is spent.

## Failure-class taxonomy

`FailureClass` (`src/ingest_librarian.rs`) classifies every abort into
exactly one of four classes, each with a `transient()` verdict:

| Class | `transient()` | Cause |
|---|---|---|
| `path_not_found` | no | `target_repo` does not exist |
| `not_a_git_repo` | no | `target_repo` exists but has no `.git` |
| `invalid_budget` | no | `--budget-usd` is non-positive or non-finite |
| `io_error` | **yes** | filesystem error while walking the tree or writing `triage.md` |

The first three are permanent — retrying with the same input never
succeeds; the caller (or the operator) must fix the argument. `io_error` is
the one class worth retrying (transient disk/permission hiccup, concurrent
writer, etc.) — `err.class.transient()` is the check to gate a retry loop
on rather than pattern-matching `message`.

## Smoke test

`bash scripts/ci/test-ingest-librarian-smoke.sh` — asserts:

1. `--help` exits 0
2. missing `target-repo` arg exits 2
3. a non-existent path exits 1 with `failure_class=path_not_found` on the
   `ingest_librarian_failed` event
4. a non-git directory exits 1 with `failure_class=not_a_git_repo`
5. a valid fixture git repo exits 0, writes
   `<target>/.chump-ingest/triage.md`, and emits
   `ingest_librarian_started` + `ingest_librarian_completed` with
   `cost_usd_cents=0`

The script isolates ambient writes via `CHUMP_REPO` pointed at a scratch
`$TMP/chump-home` so it never touches the real
`.chump-locks/ambient.jsonl`.
