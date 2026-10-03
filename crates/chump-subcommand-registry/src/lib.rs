//! Compile-time subcommand self-registration, backed by `inventory`.
//!
//! Prep crate for the `src/main.rs` decomposition (INFRA-1687): each future
//! `src/cmd/<name>.rs` module calls [`register_subcommand!`] once at module
//! scope, and the binary collects every registration via
//! [`inventory::iter::<SubcommandEntry>`] instead of a long `if`/`match`
//! chain. This crate only defines the registration primitive; wiring
//! `src/main.rs` to dispatch through it is a follow-up slice.

/// A single self-registered subcommand.
pub struct SubcommandEntry {
    pub name: &'static str,
    pub run: fn(&[String]) -> i32,
}

inventory::collect!(SubcommandEntry);

/// Registers a subcommand handler at compile time.
///
/// ```
/// use chump_subcommand_registry::{register_subcommand, SubcommandEntry};
///
/// fn run_hello(_args: &[String]) -> i32 {
///     0
/// }
///
/// register_subcommand!("hello", run_hello);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $run:expr) => {
        $crate::inventory::submit! {
            $crate::SubcommandEntry {
                name: $name,
                run: $run,
            }
        }
    };
}

#[doc(hidden)]
pub use inventory;

/// Returns every subcommand registered via [`register_subcommand!`].
pub fn iter() -> impl Iterator<Item = &'static SubcommandEntry> {
    inventory::iter::<SubcommandEntry>.into_iter()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_noop(_args: &[String]) -> i32 {
        42
    }

    register_subcommand!("noop", run_noop);

    #[test]
    fn registered_subcommand_is_discoverable() {
        let found = iter().find(|entry| entry.name == "noop");
        assert!(found.is_some(), "expected 'noop' to be registered");
        let entry = found.unwrap();
        assert_eq!((entry.run)(&[]), 42);
    }
}
