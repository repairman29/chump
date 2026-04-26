# broken_rust_app

Fixture for **Vector 3** battle simulations (`scripts/ci/run-battle-sim-suite.sh`).

1. **Syntax:** `src/lib.rs` is missing a closing `}`.
2. **Dependencies:** `Cargo.toml` references a nonexistent crate.
3. **Tests:** `tests/smoke.rs` expects `add(2,2) == 5` while `add` returns `4`.

A successful agent run should end with `cargo test` passing and may reply with `DONE`.
