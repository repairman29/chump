//! Deliberately **invalid Rust** (missing `}`) so the first `cargo check` fails with a syntax error.
//! After fixing the brace, `cargo check` fails on the bogus dependency in `Cargo.toml`.
//! After fixing the dependency, `cargo test` still fails until `add` matches the unit test.

pub fn add(a: i32, b: i32) -> i32 {
    a + b
