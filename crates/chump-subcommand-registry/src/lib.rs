//! Inventory-based subcommand self-registration (INFRA-1687 slice).
//!
//! Each subcommand module calls `register_subcommand!(name, run, help)` at
//! its own definition site; `inventory::collect!` wires link-time submission
//! for free, so `src/main.rs` never needs to know a new subcommand exists.

/// Re-exported so downstream crates can invoke `register_subcommand!` without
/// taking a direct `inventory` dependency themselves.
pub use inventory;

/// A single CLI subcommand, submitted at link time via [`register_subcommand!`].
pub struct Subcommand {
    pub name: &'static str,
    pub help: &'static str,
    pub run: fn(&[String]) -> i32,
}

inventory::collect!(Subcommand);

/// Iterate every subcommand registered anywhere in the link graph.
pub fn all() -> impl Iterator<Item = &'static Subcommand> {
    inventory::iter::<Subcommand>()
}

/// Look up a registered subcommand by name.
pub fn find(name: &str) -> Option<&'static Subcommand> {
    all().find(|s| s.name == name)
}

/// Register a subcommand for link-time self-registration.
///
/// ```ignore
/// fn run_greet(_args: &[String]) -> i32 {
///     println!("hello");
///     0
/// }
/// register_subcommand!("greet", run_greet, "print a greeting");
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $run:expr, $help:expr) => {
        $crate::inventory::submit! {
            $crate::Subcommand {
                name: $name,
                run: $run,
                help: $help,
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_noop(_args: &[String]) -> i32 {
        0
    }

    register_subcommand!(
        "noop-test-subcommand",
        run_noop,
        "test-only no-op subcommand"
    );

    #[test]
    fn registered_subcommand_is_discoverable() {
        let found = find("noop-test-subcommand").expect("macro-registered subcommand missing");
        assert_eq!(found.help, "test-only no-op subcommand");
        assert_eq!((found.run)(&[]), 0);
    }

    #[test]
    fn all_includes_registered_entries() {
        assert!(all().any(|s| s.name == "noop-test-subcommand"));
    }
}
