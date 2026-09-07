//! Self-registration inventory pattern for CLI command modules (INFRA-5280,
//! sliced from INFRA-1748). main.rs today dispatches every subcommand via a
//! hand-written `if args.get(1) == Some("...")` block, so adding a command
//! means editing main.rs *and* pays a full-binary recompile on every edit.
//!
//! This module lets a command module register itself with
//! [`register_command_module!`] (built on the `inventory` crate, same
//! primitive already used by [`crate::tool_inventory`] for LLM tools). main
//! calls [`dispatch`] once — no per-command edit required — and it resolves
//! any module that has registered itself, wherever that module lives.
//!
//! Migrating the existing hand-written `if` blocks in main.rs onto this
//! pattern is the follow-up slice of INFRA-1748; this gap only lands the
//! reusable primitive plus a first self-registering consumer
//! ([`crate::commands::modules`]) that proves discovery works end to end.

/// One self-registered command module: its subcommand name and its
/// `argv[2..]`-style entry point returning a process exit code.
pub struct CommandModule {
    pub name: &'static str,
    pub run: fn(&[String]) -> i32,
}

inventory::collect!(CommandModule);

/// Register a command module so it is discoverable via [`all`] / [`dispatch`]
/// without touching main.rs. `$run` must be `fn(&[String]) -> i32`.
#[macro_export]
macro_rules! register_command_module {
    ($name:expr, $run:expr) => {
        inventory::submit! {
            $crate::command_registry::CommandModule { name: $name, run: $run }
        }
    };
}

/// All registered command modules, sorted by name for deterministic order.
pub fn all() -> Vec<&'static CommandModule> {
    let mut modules: Vec<_> = inventory::iter::<CommandModule>().collect();
    modules.sort_by_key(|m| m.name);
    modules
}

/// Look up a registered module by subcommand name and run it, forwarding
/// `sub_args` (`argv[2..]`). Returns `None` when no module has registered
/// under `name` — the caller falls through to any other dispatch path.
pub fn dispatch(name: &str, sub_args: &[String]) -> Option<i32> {
    all()
        .into_iter()
        .find(|m| m.name == name)
        .map(|m| (m.run)(sub_args))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeModule;
    impl FakeModule {
        fn run(_args: &[String]) -> i32 {
            0
        }
    }
    inventory::submit! {
        CommandModule { name: "__command_registry_test_fixture", run: FakeModule::run }
    }

    #[test]
    fn discovers_registered_module_by_name() {
        let names: Vec<&str> = all().iter().map(|m| m.name).collect();
        assert!(
            names.contains(&"__command_registry_test_fixture"),
            "expected test fixture module to be discoverable, got {names:?}"
        );
    }

    #[test]
    fn dispatch_finds_and_runs_registered_module() {
        let code = dispatch("__command_registry_test_fixture", &[]);
        assert_eq!(code, Some(0));
    }

    #[test]
    fn dispatch_returns_none_for_unknown_name() {
        assert_eq!(dispatch("__no_such_command_module__", &[]), None);
    }

    #[test]
    fn all_is_sorted_by_name() {
        let names: Vec<&str> = all().iter().map(|m| m.name).collect();
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
    }
}
