//! Inventory-backed CLI subcommand self-registration (INFRA-1687 slice).
//!
//! Mirrors the `tool_inventory::ToolEntry` pattern: a subcommand module calls
//! `register_subcommand!("name", handler)` at its own definition site instead
//! of `main.rs` growing one more `"name" => ...` match arm. This gap only
//! introduces the primitive (dependency + macro + registry) — porting
//! existing `main.rs` match arms onto it is later slice work.

/// A single self-registered CLI subcommand.
pub struct SubcommandEntry {
    /// Subcommand name as typed on the CLI (e.g. `"doctor"`).
    pub name: &'static str,
    /// Entry point invoked with the remaining CLI args (after the subcommand name).
    pub handler: fn(&[String]) -> anyhow::Result<()>,
}

inventory::collect!(SubcommandEntry);

/// Register a CLI subcommand for inventory-based dispatch.
///
/// ```ignore
/// fn run_doctor(args: &[String]) -> anyhow::Result<()> { Ok(()) }
/// register_subcommand!("doctor", run_doctor);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $handler:expr) => {
        inventory::submit! {
            $crate::subcommand_registry::SubcommandEntry {
                name: $name,
                handler: $handler,
            }
        }
    };
}

/// Look up a self-registered subcommand handler by name.
pub fn find_subcommand(name: &str) -> Option<&'static SubcommandEntry> {
    inventory::iter::<SubcommandEntry>().find(|e| e.name == name)
}

/// All self-registered subcommand names, sorted.
pub fn registered_subcommand_names() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = inventory::iter::<SubcommandEntry>()
        .map(|e| e.name)
        .collect();
    names.sort_unstable();
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noop_handler(_args: &[String]) -> anyhow::Result<()> {
        Ok(())
    }

    register_subcommand!("subcommand-registry-test-probe", noop_handler);

    #[test]
    fn registered_subcommand_is_discoverable() {
        let entry = find_subcommand("subcommand-registry-test-probe")
            .expect("registered subcommand should be discoverable via inventory");
        (entry.handler)(&[]).expect("noop handler should succeed");
    }

    #[test]
    fn registered_names_include_probe() {
        assert!(registered_subcommand_names().contains(&"subcommand-registry-test-probe"));
    }

    #[test]
    fn unknown_subcommand_is_none() {
        assert!(find_subcommand("definitely-not-a-real-subcommand-name").is_none());
    }
}
