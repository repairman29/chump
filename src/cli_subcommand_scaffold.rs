//! EFFECTIVE-1547 (EFFECTIVE-178 slice): common CLI scaffolding for new
//! `chump` subcommands.
//!
//! EFFECTIVE-178 catalogs a set of harness-neutral recovery/orchestration
//! verbs (`lease`, `unwedge`, `wait`, `loop`, `daemons`) that don't exist
//! as chump commands yet. Rather than land five one-off `if args.get(1) ==
//! Some("x")` blocks with divergent help/parsing conventions, this module
//! is the single registry + dispatcher: each verb's real implementation
//! (a future per-verb gap) replaces its `run` closure here without
//! touching main.rs's dispatch site or the help text.
//!
//! Stub exit code: `SCAFFOLD_STUB_EXIT_CODE` (3), distinct from 78
//! (EX_CONFIG, already meaningful in this codebase as the daemon
//! crash-loop signal per `farmer_status.rs`) so a stub verb can never be
//! mistaken for a crashed daemon by `chump farmer status`.

/// Exit code returned by a scaffolded verb that has no real implementation
/// yet. Distinct from 0 (success) and 78 (daemon crash-loop, see
/// `farmer_status.rs`) so callers can tell "not implemented" apart from
/// both.
pub const SCAFFOLD_STUB_EXIT_CODE: i32 = 3;

/// One scaffolded subcommand: name, one-line help description, and usage
/// string shown by `chump <name> --help`.
pub struct ScaffoldSubcommand {
    pub name: &'static str,
    pub description: &'static str,
    pub usage: &'static str,
}

/// EFFECTIVE-178 verbs not yet implemented. Adding a real implementation
/// for one of these means: write `run_<name>`, replace its arm in
/// `dispatch`, and leave this table (name/description/usage) as the
/// command's help surface — no other call site changes.
pub const SCAFFOLD_SUBCOMMANDS: &[ScaffoldSubcommand] = &[
    ScaffoldSubcommand {
        name: "lease",
        description: "single verb over state.db + NATS-KV + git claim-branch lease stores (RESILIENT-103)",
        usage: "Usage: chump lease <ls|release|reconcile> [--gap ID] [--session ID] [--all-stores]",
    },
    ScaffoldSubcommand {
        name: "unwedge",
        description: "on-demand kill+recover of a wedged bot-merge (RESILIENT-100)",
        usage: "Usage: chump unwedge <gap-id>",
    },
    ScaffoldSubcommand {
        name: "wait",
        description: "block until a fleet condition holds (e.g. a PR merges)",
        usage: "Usage: chump wait <condition> [--gap ID] [--timeout SECS]",
    },
    ScaffoldSubcommand {
        name: "daemons",
        description: "list all fleet daemons + last-exit + crash-loop flag, harness-neutral (not launchctl-coupled)",
        usage: "Usage: chump daemons --status [--json]",
    },
];

/// Look up a scaffolded subcommand by name.
pub fn find(name: &str) -> Option<&'static ScaffoldSubcommand> {
    SCAFFOLD_SUBCOMMANDS.iter().find(|s| s.name == name)
}

/// Parse + dispatch a scaffolded subcommand's remaining args (everything
/// after `chump <name>`). `--help`/`-h` always exits 0 with usage text
/// (INFRA-1238 convention, enforced by
/// `scripts/ci/test-chump-subcommand-help.sh`); otherwise flags are parsed
/// (accepted, not yet acted on) and the call returns the stub exit code.
pub fn dispatch(sub: &ScaffoldSubcommand, args: &[String]) -> i32 {
    if args
        .iter()
        .any(|a| a == "--help" || a == "-h" || a == "help")
    {
        println!("{}", sub.usage);
        println!();
        println!("{}", sub.description);
        println!();
        println!("STATUS: scaffolded, not yet implemented (EFFECTIVE-178).");
        return 0;
    }

    // Positional args and flags are collected but not yet acted on — real
    // per-verb parsing lands with each verb's implementation gap.
    let positionals: Vec<&String> = args.iter().filter(|a| !a.starts_with('-')).collect();
    let flags: Vec<&String> = args.iter().filter(|a| a.starts_with('-')).collect();

    eprintln!(
        "chump {}: scaffolded verb, not yet implemented (EFFECTIVE-178). args={:?} flags={:?}",
        sub.name, positionals, flags
    );
    SCAFFOLD_STUB_EXIT_CODE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_scaffold_names_are_unique() {
        let mut names: Vec<&str> = SCAFFOLD_SUBCOMMANDS.iter().map(|s| s.name).collect();
        let before = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), before, "duplicate scaffold subcommand name");
    }

    #[test]
    fn find_known_verb() {
        assert!(find("daemons").is_some());
        assert!(find("not-a-real-verb").is_none());
    }

    #[test]
    fn help_flag_exits_zero() {
        let sub = find("lease").unwrap();
        let rc = dispatch(sub, &["--help".to_string()]);
        assert_eq!(rc, 0);
    }

    #[test]
    fn no_flags_returns_stub_exit_code() {
        let sub = find("wait").unwrap();
        let rc = dispatch(sub, &["some-condition".to_string()]);
        assert_eq!(rc, SCAFFOLD_STUB_EXIT_CODE);
    }

    #[test]
    fn parses_flags_without_erroring() {
        let sub = find("daemons").unwrap();
        let rc = dispatch(sub, &["--status".to_string(), "--json".to_string()]);
        assert_eq!(rc, SCAFFOLD_STUB_EXIT_CODE);
    }
}
