# Ingest orchestration observability (INFRA-1784, INFRA-1746 phase 5)

`chump ingest <repo-path> --confirm-mutations` (`src/ingest_orchestrate.rs`,
dispatched from `src/ingest.rs::run_orchestration`) runs the four static
read-only phase-1b-4 scans (Librarian INFRA-1781, Cartographer INFRA-1782,
Evangelist INFRA-1783, Systematizer) against a *target* repo in sequence,
writes a takeover certificate (`<target>/.chump-ingest/certificate.json`)
and up to 5 proposed follow-up gaps
(`<target>/.chump-ingest/proposed-gaps.json`), and records a PR-attempt
stub for the future auto-PR pipeline. This doc is the audit reference: what
events it emits, how cost is tracked, the failure-class taxonomy, and how
to smoke-test it. Sibling doc for the phase-1b Librarian sweep alone:
[`LIBRARIAN_OBSERVABILITY.md`](./LIBRARIAN_OBSERVABILITY.md).

Without `--confirm-mutations`, `chump ingest <repo-path>` stays phase-1a
only (INFRA-1780): validates the target is a directory containing `.git`
and emits `ingest_initiated` / `ingest_validated` / `ingest_failed` —
zero filesystem mutation, zero orchestration events. Phase-1a validation
runs *before* orchestration starts even when `--confirm-mutations` is
passed, so a bad path fails fast with `ingest_failed` and
`ingest_orchestrate_started` never fires.

## Events

All events land in `.chump-locks/ambient.jsonl` (registered in
`docs/observability/EVENT_REGISTRY.yaml`, `effect_metric: self`), keyed off
`chump_repo_root` (honours `CHUMP_REPO`) — **not** the target repo being
ingested, since the target may not be (and doesn't need to be) a Chump
checkout.

### `kind=ingest_orchestrate_started`

Emitted once, immediately before phase 1b (Librarian) starts, only after
phase-1a validation has already passed.

```json
{"ts":"...", "kind":"ingest_orchestrate_started", "target_repo":"/path/to/target"}
```

### `kind=ingest_complete`

Emitted on success, after the certificate and proposed-gaps files have been
written.

```json
{"ts":"...", "kind":"ingest_complete", "target_repo_path":"...",
 "phases_completed":["librarian","cartographer","evangelist","systematizer"],
 "prs_attempted":0, "prs_green_first_pass":0, "gaps_proposed":3,
 "total_cost_usd_cents":0, "elapsed_min":0.02}
```

`prs_attempted` and `prs_green_first_pass` are always `0` in v1 — auto-PR
opening (real `git`/`gh` mutation against the target repo) is deliberately
out of scope until a code-generation pipeline exists to back it (see
module doc in `src/ingest_orchestrate.rs`). The fields are reported now,
not added later, so a downstream PR-success-rate rollup doesn't need a
schema migration once phase 5b lands.

### `kind=ingest_orchestrate_failed`

Emitted when orchestration aborts mid-sequence, after at least one phase
has started. Carries `phase` (which of librarian/cartographer/evangelist/
systematizer/certificate/propose_gaps aborted) plus `failure_class` and
`transient` so a caller can decide retry vs. surface-to-operator without
string-matching `message`.

```json
{"ts":"...", "kind":"ingest_orchestrate_failed", "target_repo":"...",
 "phase":"cartographer", "failure_class":"io_error", "transient":true,
 "message":"..."}
```

Note: a bad/missing target path is caught by phase-1a validation in
`src/ingest.rs` *before* orchestration starts, so that failure mode emits
`ingest_failed` (phase-1a's event kind, see
[`test-ingest-smoke.sh`](../../scripts/ci/test-ingest-smoke.sh)), not
`ingest_orchestrate_failed`.

Source: `src/ingest_orchestrate.rs::emit_started|emit_completed|emit_failed`.

## Cost tracking

All four orchestrated phases are static heuristics against the target's
file tree — none makes an LLM or network call, so `total_cost_usd_cents`
is always `0` in v1 and `ingest_complete` reports it as such. The
`OrchestrateConfig::budget_usd` ceiling is checked after every phase
(`check_budget`) so enforcement starts the moment a phase adds a real
paid call, without a code change to the orchestrator itself — but that
also means `FailureClass::BudgetExceeded` is currently unreachable via the
CLI: `chump ingest` rejects any non-positive `--budget-usd` before
orchestration runs, and cumulative cost can never exceed a positive
budget while every phase costs `$0`.

## Failure-class taxonomy

`FailureClass` (`src/ingest_orchestrate.rs`) classifies every abort into
exactly one of three classes, each with a `transient()` verdict:

| Class | `transient()` | Cause |
|---|---|---|
| `path_not_found` | no | a phase reported a bad/missing path (maps from that phase's own `PathNotFound`/`NotAGitRepo`/`InvalidBudget` variants — see `map_*_class` in `src/ingest_orchestrate.rs`) |
| `io_error` | **yes** | filesystem error mid-scan, or while writing a phase artifact / the certificate / proposed-gaps.json |
| `budget_exceeded` | no | cumulative phase cost exceeded `budget_usd` (currently unreachable in v1 — see Cost tracking above) |

Phases run in order; the **first failure aborts the remaining phases**.
Artifacts already written by earlier phases (e.g. `triage.md` from a
Librarian pass that succeeded before Cartographer failed) are left in
place — they're independently useful, not rolled back. `permanent`
classes (`path_not_found`, `budget_exceeded`) require operator action
before a retry can succeed; `io_error` is the one class worth an automatic
retry (transient disk/permission hiccup, concurrent writer, etc.) — gate a
retry loop on `err.class.transient()` rather than pattern-matching
`message`.

## Smoke test

`bash scripts/ci/test-ingest-orchestrate-smoke.sh` — asserts:

1. a non-existent target path with `--confirm-mutations` exits 1 with
   `failure_class=path_not_found` on the phase-1a `ingest_failed` event,
   and confirms `ingest_orchestrate_started` correctly does **not** fire
   (phase-1a validation gates before orchestration starts)
2. a valid fixture git repo with `--confirm-mutations` exits 0, writes
   `<target>/.chump-ingest/certificate.json` and
   `<target>/.chump-ingest/proposed-gaps.json`, and emits
   `ingest_orchestrate_started` + `ingest_complete`
3. `ingest_complete` reports `total_cost_usd_cents=0`, `prs_attempted=0`,
   and `phases_completed` containing all four phase names

The script isolates ambient writes via `CHUMP_REPO`/`CHUMP_HOME` pointed at
a scratch temp dir so it never touches the real `.chump-locks/ambient.jsonl`
(same isolation pattern as
[`test-ingest-smoke.sh`](../../scripts/ci/test-ingest-smoke.sh) and
[`test-ingest-librarian-smoke.sh`](../../scripts/ci/test-ingest-librarian-smoke.sh)).
Runs in <30s, no network.
