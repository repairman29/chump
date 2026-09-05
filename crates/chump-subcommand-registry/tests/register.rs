use chump_subcommand_registry::{all_subcommands, register_subcommand};

fn run_hello(_args: &[String]) -> anyhow::Result<()> {
    Ok(())
}

register_subcommand!("hello", run_hello);

#[test]
fn registers_and_iterates() {
    let names: Vec<&str> = all_subcommands().map(|s| s.name).collect();
    assert!(names.contains(&"hello"));
}
