# Demo recipe: `chump ingest` against a small target repo (INFRA-1746 validation, INFRA-1785)

Reproducible end-to-end walkthrough for the `chump ingest <repo-path>`
takeover pipeline (INFRA-1780 phase-1a validation → INFRA-1784 phase 1b-4
orchestration). Uses a throwaway local git repo instead of a real axum
project so the recipe runs offline in under a minute — swap `TARGET` for
any real repo path to demo against something bigger.

## 1. Build

```bash
cargo build --bin chump
CHUMP_BIN=./target/debug/chump
```

## 2. Create a tiny target repo

```bash
TARGET=$(mktemp -d)
git -C "$TARGET" init -q
mkdir -p "$TARGET/src"
cat > "$TARGET/src/main.rs" <<'EOF'
fn main() {
    println!("hello from the ingest demo target");
}
EOF
git -C "$TARGET" add -A
git -C "$TARGET" -c user.email=demo@example.com -c user.name=demo commit -q -m "seed"
```

## 3. Phase 1a — read-only validation

```bash
"$CHUMP_BIN" ingest "$TARGET"
```

Expected: exits `0`, zero filesystem mutation under `$TARGET`, emits
`ingest_initiated` + `ingest_validated` to ambient. No orchestration runs
without `--confirm-mutations` — this is the safety contract INFRA-1746
requires (operator-owned repos only, read-only until explicit confirm).

## 4. Phase 5 — orchestration + takeover certificate

```bash
"$CHUMP_BIN" ingest "$TARGET" --confirm-mutations
```

Expected artifacts, all under `$TARGET`:

| Path | Written by |
|---|---|
| `.chump-ingest/triage.md` | Phase 1b Librarian (INFRA-1781) |
| `docs/ARCHITECTURE.md` | Phase 2 Cartographer (INFRA-1782) |
| `docs/HIDDEN_GEMS.md` | Phase 3 Evangelist (INFRA-1783) |
| `docs/CAPABILITIES_REGISTRY.json` | Phase 4 Systematizer (INFRA-1783) |
| `.chump-ingest/certificate.json` | Takeover certificate (INFRA-1784) — `entry_points`, `hot_paths`, `test_surface`, `dependency_graph`, cost + elapsed fields |
| `.chump-ingest/proposed-gaps.json` | Up to 5 auto-proposed follow-up gaps (INFRA-1784) |

Ambient emits (see
[`docs/process/INGEST_ORCHESTRATE_OBSERVABILITY.md`](../process/INGEST_ORCHESTRATE_OBSERVABILITY.md)
for the full event/cost/failure-class reference): `ingest_orchestrate_started`,
then `ingest_complete` with `phases_completed=[librarian, cartographer,
evangelist, systematizer]` and (in v1, all phases are static heuristics —
no LLM/network call) `total_cost_usd_cents=0`.

```bash
cat "$TARGET/.chump-ingest/certificate.json"
```

## 5. Cleanup

```bash
rm -rf "$TARGET"
```

## Automated equivalent

This recipe is exercised as CI in
[`scripts/ci/test-ingest-smoke.sh`](../../scripts/ci/test-ingest-smoke.sh)
(phase 1a) and
[`scripts/ci/test-ingest-orchestrate-smoke.sh`](../../scripts/ci/test-ingest-orchestrate-smoke.sh)
(phase 5 orchestration, certificate + proposed-gaps assertions). Run either
directly:

```bash
bash scripts/ci/test-ingest-orchestrate-smoke.sh
```
