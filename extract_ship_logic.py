import sys

with open('src/main.rs', 'r') as f:
    lines = f.readlines()

def extract_fn(name, start_marker):
    out = []
    i = 0
    found = False
    while i < len(lines):
        if start_marker in lines[i] and not found:
            found = True
            brace_count = 0
            started = False
            while i < len(lines):
                l = lines[i]
                out.append(l)
                brace_count += l.count('{')
                brace_count -= l.count('}')
                if '{' in l: started = True
                i += 1
                if started and brace_count == 0:
                    break
            break
        i += 1
    return "".join(out)

fns = [
    ('ship_plan_cli', 'async fn ship_plan_cli'),
    ('ship_plan_count_behind_ahead', 'fn ship_plan_count_behind_ahead'),
    ('ship_plan_fetch_pr_snapshot', 'fn ship_plan_fetch_pr_snapshot'),
    ('ship_plan_fetch_checks', 'fn ship_plan_fetch_checks'),
    ('ship_plan_print_human', 'fn ship_plan_print_human'),
    ('ship_execute_cli', 'async fn ship_execute_cli'),
]

header = """use anyhow::{Context, Result};
use crate::{repo_path, gap_store, chump_init, chump_log, audit, version};
use serde::{Deserialize, Serialize};
use serde_json;
use std::io::{self, Read};

"""

with open('src/cmd/ship.rs', 'w') as f:
    f.write(header)
    # Define structs needed for ship plan
    f.write("// Define structs used by ship plan\\n")
    # I'll need to find these structs in main.rs too or just move them.
    # For now I'll just write the run function and the extracted functions.
    
    run_fn = """
pub async fn run(args: &[String]) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("ship") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        match sub {
            "plan" => ship_plan_cli(&args[1..]).await?,
            "execute" => ship_execute_cli(&args[1..]).await?,
            "help" | _ => {
                println!("Usage: chump ship <plan|execute> [args]");
            }
        }
        return Ok(());
    }
    Ok(())
}
"""
    f.write(run_fn)
    for name, marker in fns:
        f.write("\\n")
        content = extract_fn(name, marker)
        # Make functions public if they were not
        if content.startswith('fn'):
            content = 'pub(crate) ' + content
        elif content.startswith('async fn'):
            content = 'pub(crate) ' + content
        f.write(content)

