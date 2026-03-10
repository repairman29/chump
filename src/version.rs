//! Chump version for logs and health. From env CHUMP_VERSION or Cargo.toml at compile time.

/// Version string: CHUMP_VERSION env if set, else CARGO_PKG_VERSION.
pub fn chump_version() -> String {
    std::env::var("CHUMP_VERSION").unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string())
}
