//! Link-time subcommand self-registration (INFRA-1687 slice, INFRA-4667).
//!
//! Each subcommand module submits a `Subcommand` via `register_subcommand!` instead of
//! main.rs growing a hand-maintained match arm per command. This slice only lands the
//! `inventory` dependency + macro; wiring `main()`'s dispatch loop to read from
//! `inventory::iter::<Subcommand>()` and migrating existing arms is follow-up work.

/// One self-registered CLI subcommand: name, help text, and its entrypoint.
pub struct Subcommand {
    pub name: &'static str,
    pub help: &'static str,
    pub run: fn(&[String]) -> anyhow::Result<()>,
}

inventory::collect!(Subcommand);

/// Register a subcommand for link-time discovery via `inventory::iter::<Subcommand>()`.
///
/// ```ignore
/// register_subcommand!("fanout", "Fan work out across N workers", cmd_fanout::run);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $help:expr, $run:expr) => {
        $crate::subcommand_registry::inventory::submit! {
            $crate::subcommand_registry::Subcommand {
                name: $name,
                help: $help,
                run: $run,
            }
        }
    };
}

// Re-exported so `register_subcommand!` can reference `$crate::subcommand_registry::inventory`
// from any calling module without every caller needing its own `inventory` dependency line.
pub use inventory;

#[cfg(test)]
mod tests {
    use super::Subcommand;

    fn noop(_args: &[String]) -> anyhow::Result<()> {
        Ok(())
    }

    register_subcommand!("infra-4667-selftest", "self-registration smoke test", noop);

    #[test]
    fn registered_subcommand_is_discoverable() {
        let found = inventory::iter::<Subcommand>()
            .into_iter()
            .any(|s| s.name == "infra-4667-selftest");
        assert!(
            found,
            "register_subcommand! entry not found via inventory::iter"
        );
    }

    #[test]
    fn registered_run_fn_executes() {
        let entry = inventory::iter::<Subcommand>()
            .into_iter()
            .find(|s| s.name == "infra-4667-selftest")
            .expect("entry present");
        assert_eq!(entry.help, "self-registration smoke test");
        (entry.run)(&[]).expect("run fn should succeed");
    }
}
