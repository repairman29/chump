//! Inventory-backed self-registration for CLI subcommands (INFRA-1687 slice).
//!
//! First step toward decomposing `src/main.rs`'s dispatch table: each
//! subcommand will eventually live in its own `src/cmd/<name>.rs` and submit
//! itself here at link time via [`register_subcommand!`], instead of
//! `main.rs` growing a new `match` arm per command. This gap only lands the
//! registration primitive; wiring the dispatcher to consume it is a
//! follow-up slice.

/// One self-registered CLI subcommand: its name, one-line help, and entry point.
pub struct Subcommand {
    pub name: &'static str,
    pub help: &'static str,
    pub run: fn(&[String]) -> anyhow::Result<()>,
}

inventory::collect!(Subcommand);

/// Register a subcommand at link time. Usage:
///
/// ```ignore
/// fn run_foo(_args: &[String]) -> anyhow::Result<()> { Ok(()) }
/// register_subcommand!("foo", "Does foo things", run_foo);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $help:expr, $run:expr) => {
        inventory::submit! {
            $crate::cmd_registry::Subcommand {
                name: $name,
                help: $help,
                run: $run,
            }
        }
    };
}

/// All self-registered subcommands, in registration order (inventory does not guarantee order,
/// so callers that need determinism should sort by `name`).
pub fn registered_subcommands() -> Vec<&'static Subcommand> {
    inventory::iter::<Subcommand>().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_noop(_args: &[String]) -> anyhow::Result<()> {
        Ok(())
    }

    register_subcommand!("cmd-registry-selftest", "self-test subcommand", run_noop);

    #[test]
    fn registers_and_runs() {
        let found = registered_subcommands()
            .into_iter()
            .find(|s| s.name == "cmd-registry-selftest")
            .expect("self-test subcommand should be registered via inventory");
        assert_eq!(found.help, "self-test subcommand");
        (found.run)(&[]).expect("run should succeed");
    }
}
