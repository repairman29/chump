//! Tool policy: which tools require human approval before execution.
//! Set CHUMP_TOOLS_ASK to a comma-separated list of tool names (e.g. run_cli,write_file).

use std::collections::HashSet;
use std::sync::OnceLock;

static TOOLS_ASK: OnceLock<HashSet<String>> = OnceLock::new();

fn parse_tools_ask() -> HashSet<String> {
    std::env::var("CHUMP_TOOLS_ASK")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_lowercase())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Set of tool names that require approval before execution. Empty when CHUMP_TOOLS_ASK is unset.
pub fn tools_requiring_approval() -> &'static HashSet<String> {
    TOOLS_ASK.get_or_init(parse_tools_ask)
}

/// True if the named tool requires approval.
pub fn requires_approval(tool_name: &str) -> bool {
    tools_requiring_approval().contains(&tool_name.to_lowercase())
}
