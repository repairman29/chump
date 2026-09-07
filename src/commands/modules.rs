//! `chump modules list` (INFRA-5280) — lists every command module that has
//! self-registered via `register_command_module!`. Doubles as the proof
//! that main can discover registered modules at runtime: this module is
//! itself dispatched by `command_registry::dispatch` from main.rs, not by a
//! hand-written `if args.get(1) == Some("modules")` block.

use crate::command_registry;

pub fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        None | Some("list") => {
            for module in command_registry::all() {
                println!("{}", module.name);
            }
            0
        }
        Some(other) => {
            eprintln!("chump modules: unknown subcommand '{other}'");
            eprintln!("usage: chump modules [list]");
            2
        }
    }
}

crate::register_command_module!("modules", run);
