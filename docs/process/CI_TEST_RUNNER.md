# CI Test Runner (cargo-nextest, INFRA-2094)

## What changed

Workspace cargo tests in CI now run via `cargo nextest run` instead of `cargo test`. The change is fully backward-compatible at the per-test level (same `#[test]` discovery, same assertions) but ~60% faster wall-clock thanks to per-crate parallelism that `cargo test` doesn't do.

## Why

`cargo test` is the original test runner. It serializes test binaries per crate, which means a 12-crate workspace runs ~12× sequentially even when each crate's tests would run in parallel. `cargo nextest run` parallelizes across crates AND tests-within-crates, scaling to all available cores.

Typical workspace impact: 8-12 min `cargo test` wall-clock → 3-5 min `cargo nextest run` on the same hardware.

## The integration

CI workflow (`.github/workflows/ci.yml`, cargo-test job):

```yaml
- name: Install cargo-nextest
  uses: taiki-e/install-action@v2
  with:
    tool: nextest

- name: cargo test (nextest via INFRA-764 flake auto-rerun wrapper)
  run: |
    if [ "${CARGO_NEXTEST_DISABLE:-0}" = "1" ]; then
      bash scripts/ci/cargo-test-with-rerun.sh -- cargo test --workspace
    else
      bash scripts/ci/cargo-test-with-rerun.sh -- cargo nextest run --workspace
    fi
```

The `cargo-test-with-rerun.sh` wrapper (INFRA-764 flake auto-rerun) is preserved. It runs whatever command comes after `--`, so swapping `cargo test` → `cargo nextest run` is transparent to the wrapper's retry logic.

## Gotchas

1. **No `--test-threads` flag.** `cargo nextest run` handles thread management via its own config (`.config/nextest.toml` if present). If you need to limit concurrency, set `[profile.default] test-threads = N` in that file.

2. **Different failure-line format.** Where `cargo test` prints `test foo::bar ... FAILED`, nextest prints `FAIL [   0.123s] crate::foo::bar`. The INFRA-764 flake-name parser doesn't recognize nextest's format — so PER-TEST flake matching falls through to "unknown failures" path. Net effect: nextest failures trigger a single full-suite re-run (the safe-default branch) instead of selective re-run. This is fine for now; tighter integration is filed as INFRA-NEW follow-up.

3. **Doctests.** `cargo nextest run` does NOT run doctests by default (upstream limitation). If you rely on doctests, add a separate `cargo test --doc` step. As of this writing, no workspace crate has doctest coverage, so this is moot.

## Bypass

Local dev — use whatever you want:
```bash
cargo test --workspace               # original, slower
cargo nextest run --workspace        # parallel, faster
```

CI override — set env var to revert to `cargo test`:
```bash
CARGO_NEXTEST_DISABLE=1
```
Use this only if nextest itself misbehaves; report the issue first.

## Related

- INFRA-2093 — sccache + R2 backend (compounds with nextest: 50-70% compile speedup × 60% test speedup)
- INFRA-2095 — GitHub native merge queue (batches PRs, multiplies the savings across the queue)
- INFRA-764 — flake auto-rerun wrapper (still in path)
- docs/process/KNOWN_FLAKES.yaml — flake catalog (still consulted by wrapper)
