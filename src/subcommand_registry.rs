//! Inventory-backed subcommand registration (INFRA-1687 slice, INFRA-4667).
//!
//! Lets any module declare a CLI subcommand at the definition site instead of
//! threading it through a central `match` in `src/main.rs`. Collection is
//! `inventory::iter::<SubcommandEntry>()` at startup; this slice only adds the
//! registration plumbing (entry type + macro), not the dispatch wiring.

/// One registered subcommand: its CLI name, a one-line help string, and the
/// handler invoked when that subcommand is selected.
pub struct SubcommandEntry {
    pub name: &'static str,
    pub help: &'static str,
    pub handler: fn(),
}

inventory::collect!(SubcommandEntry);

/// Registers a subcommand with the global inventory so it shows up in
/// `inventory::iter::<SubcommandEntry>()` without a central registration list.
///
/// ```ignore
/// fn run_hello() { println!("hello"); }
/// register_subcommand!("hello", "prints a greeting", run_hello);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $help:expr, $handler:expr) => {
        inventory::submit! {
            $crate::subcommand_registry::SubcommandEntry {
                name: $name,
                help: $help,
                handler: $handler,
            }
        }
    };
}

#[cfg(test)]
mod tests {
    use super::SubcommandEntry;

    fn noop() {}

    register_subcommand!("noop", "does nothing", noop);

    #[test]
    fn registered_subcommand_is_discoverable() {
        let names: Vec<&str> = inventory::iter::<SubcommandEntry>()
            .map(|e| e.name)
            .collect();
        assert!(names.contains(&"noop"));
    }
}
