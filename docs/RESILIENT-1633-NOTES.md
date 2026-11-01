# RESILIENT-1633 — closed already-shipped: CI-red repair organ landed in PR #5701

The review organ (`scripts/dispatch/review-organ-tick.sh`, `maybe_dispatch_ci_red_repair`)
shipped in PR #5701 (`feat(review-organ): fail-closed Rust auto-merge gate, organ approve
policy, and CI-red repair dispatch`). Mapping to the acceptance criteria:

1. Deterministic required-check FAILURE (cargo-check / cargo-test-shard / fast-checks /
   verified) -> one `chump dispatch <GAP> --backend headless --repair` (CLI flag, no env
   override), stamped per (PR, head sha), emits registered `kind=pr_repair_dispatched`.
2. Flake-catalogued, CANCELLED, and non-required checks never trigger it.
3. Per-tick cap of 1 dispatch; `pr-cut`, `no-auto-merge`, `hold`, `do-not-merge`,
   `CHUMP_HOLD` labels skip it.
4. `review-held` is applied so the repaired head needs a fresh `VERDICT: APPROVE`;
   dispatch never passes `--auto-merge`.

Verified 2026-10-31: `LC_ALL=C bash scripts/ci/test-arm-policy.sh` — all nine
"RESILIENT-1633" assertions PASS (the two unrelated FAILs are `$HOME`-path env artifacts
of the local host).
