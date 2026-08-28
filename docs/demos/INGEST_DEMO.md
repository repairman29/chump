# `chump ingest` demo recipe (INFRA-1746, validated INFRA-1785)

Reproducible end-to-end walkthrough of the existing-repo takeover
entrypoint. Two runs: a **dry-run** (phase 1a only, zero mutation) and a
**full orchestration** (`--confirm-mutations`, phases 1b-4 + certificate).

## Setup — a throwaway fixture repo

```bash
mkdir -p /tmp/ingest-demo-axum && cd /tmp/ingest-demo-axum
git init -q
mkdir -p src
cat > src/main.rs <<'EOF'
fn main() {
    println!("hello from a tiny fixture repo");
}
EOF
git add src/main.rs
git -c user.email=demo@example.com -c user.name=demo commit -q -m "init"
cd -
```

Any real git repo works — this is just a small, fast, offline stand-in for
"an axum app" so the recipe runs in seconds with no network dependency.

## Step 1 — dry run (phase 1a, read-only)

```bash
chump ingest /tmp/ingest-demo-axum
```

Expected: exits `0`, **zero filesystem mutation** (no `.chump-ingest/`
directory, no `git status` change). Emits `ingest_initiated` then
`ingest_validated` to `.chump-locks/ambient.jsonl`, `cost_usd_cents=0`.

## Step 2 — full orchestration

```bash
chump ingest /tmp/ingest-demo-axum --confirm-mutations
```

Expected: exits `0`, runs Librarian → Cartographer → Evangelist →
Systematizer in sequence, and writes:

```
/tmp/ingest-demo-axum/.chump-ingest/certificate.json
/tmp/ingest-demo-axum/.chump-ingest/proposed-gaps.json
```

`certificate.json` shape (abridged):

```json
{
  "target_repo_path": "/tmp/ingest-demo-axum",
  "phases_completed": ["librarian", "cartographer", "evangelist", "systematizer"],
  "ingestion_cost_usd_cents": 0,
  "ingestion_elapsed_min": 0.02
}
```

Ambient emits `ingest_orchestrate_started` then `ingest_complete` with
`total_cost_usd_cents=0`, `prs_attempted=0` (auto-PR opening is deferred
past v1 — see `docs/process/INGEST_ORCHESTRATE_OBSERVABILITY.md`), and
`gaps_proposed` reflecting up to 5 follow-up gaps written to
`proposed-gaps.json`.

## Cleanup

```bash
rm -rf /tmp/ingest-demo-axum
```

## What proves this recipe still works

`scripts/ci/test-ingest-smoke.sh` (phase 1a) and
`scripts/ci/test-ingest-orchestrate-smoke.sh` (phase 5 orchestration) are
this exact recipe encoded as CI assertions — same fixture-repo shape, same
success/failure paths, same ambient event + artifact checks, isolated from
the real `.chump-locks/ambient.jsonl` via a scratch `CHUMP_REPO`/`CHUMP_HOME`.
Run both locally in <30s, no network:

```bash
cargo build --bin chump
bash scripts/ci/test-ingest-smoke.sh
bash scripts/ci/test-ingest-orchestrate-smoke.sh
```

Full event/cost/failure-class reference:
[`docs/process/INGEST_ORCHESTRATE_OBSERVABILITY.md`](../process/INGEST_ORCHESTRATE_OBSERVABILITY.md).
