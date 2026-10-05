# `chump ingest` demo recipe (INFRA-1785, INFRA-1746 validation)

Reproducible end-to-end walkthrough of `chump ingest` against a throwaway
fixture repo — no network, no real target repo required. For the full
observability contract (events, cost, failure taxonomy), see
[`INGEST_ORCHESTRATE_OBSERVABILITY.md`](../process/INGEST_ORCHESTRATE_OBSERVABILITY.md)
and [`LIBRARIAN_OBSERVABILITY.md`](../process/LIBRARIAN_OBSERVABILITY.md).

## 1. Build the binary

```bash
cargo build --bin chump
CHUMP_BIN="$(pwd)/target/debug/chump"
```

## 2. Create a tiny fixture target repo

```bash
DEMO_TARGET=$(mktemp -d)
git -C "$DEMO_TARGET" init -q
echo 'fn main() { println!("hello"); }' > "$DEMO_TARGET/main.rs"
git -C "$DEMO_TARGET" add -A
git -C "$DEMO_TARGET" -c user.email=demo@example.com -c user.name=demo commit -qm "init"
```

## 3. Phase-1a: read-only validation (no mutation)

```bash
"$CHUMP_BIN" ingest "$DEMO_TARGET"
```

Expected: exits 0, prints a validation summary, writes nothing to
`$DEMO_TARGET`. Emits `kind=ingest_initiated` then `kind=ingest_validated`
to ambient (see `docs/observability/EVENT_REGISTRY.yaml`).

## 4. Phase 1b-4 + certificate: full orchestration

```bash
"$CHUMP_BIN" ingest "$DEMO_TARGET" --confirm-mutations
echo "exit=$?"
cat "$DEMO_TARGET/.chump-ingest/certificate.json"
cat "$DEMO_TARGET/.chump-ingest/proposed-gaps.json"
```

Expected certificate shape (`total_cost_usd_cents` is `0` in v1 — all four
phases are static scans, no LLM/API calls):

```json
{
  "target_repo_path": "...",
  "entry_points": [...],
  "hot_paths": [...],
  "test_surface": {...},
  "dependency_graph": {...},
  "ingestion_cost_usd_cents": 0,
  "ingestion_elapsed_min": 0.02
}
```

Ambient events fired, in order: `ingest_orchestrate_started` →
`ingest_complete` (carries `phases_completed`, `prs_attempted`,
`prs_green_first_pass`, `total_cost_usd_cents`, `elapsed_min`).

## 5. Failure path: bad target

```bash
"$CHUMP_BIN" ingest /tmp/does-not-exist-$$ --confirm-mutations
echo "exit=$?"   # 1
```

Phase-1a validation runs *before* orchestration starts, so this emits
`kind=ingest_failed` with `failure_class=path_not_found` —
`ingest_orchestrate_started` never fires.

## 6. Cleanup

```bash
rm -rf "$DEMO_TARGET"
```

## Automated equivalent

This recipe is codified as CI smoke tests — run them directly instead of
following the manual steps above:

```bash
scripts/ci/test-ingest-smoke.sh              # phase 1a (INFRA-1780)
scripts/ci/test-ingest-librarian-smoke.sh    # phase 1b (INFRA-1781)
scripts/ci/test-ingest-preflight-smoke.sh    # pre-flight safety
scripts/ci/test-ingest-orchestrate-smoke.sh  # phases 1b-4 + certificate (INFRA-1784)
```

All four build the binary if needed, run in well under 30s each, no
network, and isolate ambient writes from the real fleet
`.chump-locks/ambient.jsonl` via a scratch `CHUMP_REPO`/`CHUMP_HOME`.
