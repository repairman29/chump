//! INFRA-5754 (INFRA-1748 slice): command registration interface + inventory
//! dispatch infrastructure.
//!
//! This is the pilot scaffolding for the main.rs decomposition described in
//! `docs/refactor/MAIN_RS_DECOMPOSITION.md`. Each self-registering subcommand
//! module will `::inventory::submit!` a `CommandEntry` naming itself and a
//! `run` fn; `main.rs` can then look the subcommand up via [`dispatch`]
//! instead of growing another `args.get(1) == Some("<name>")` block.
//!
//! No subcommands are ported to this pattern yet (that is later slices of
//! INFRA-1748) — this gap only defines the interface and lookup logic.

/// A self-registered CLI subcommand entry point.
///
/// `name` is the subcommand as typed on the command line (e.g. `"fanout"`).
/// `run` receives the remaining args (everything after the subcommand name)
/// and returns the process exit code, mirroring the `commands::<mod>::run`
/// convention already used by the manually-dispatched entries in
/// `src/commands/`.
pub struct CommandEntry {
    pub name: &'static str,
    pub run: fn(&[String]) -> i32,
}

::inventory::collect!(CommandEntry);

/// Look up and run a self-registered subcommand by name.
///
/// Returns `None` if no `CommandEntry` was registered under `name` (the
/// caller should fall through to the legacy dispatch chain in that case).
/// Returns `Some(exit_code)` if a matching entry was found and run.
pub fn dispatch(name: &str, args: &[String]) -> Option<i32> {
    ::inventory::iter::<CommandEntry>()
        .find(|entry| entry.name == name)
        .map(|entry| (entry.run)(args))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatch_returns_none_for_unregistered_name() {
        assert!(dispatch("definitely-not-a-registered-subcommand", &[]).is_none());
    }
}
