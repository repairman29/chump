//! RESILIENT-1902: `chump registry restore <path|refs/stash/registry/<date>>` —
//! seed a hub registry (state.db) from an off-node snapshot. Thin wrapper over
//! scripts/ops/registry-snapshot.sh so the CLI and the daily timer share one path.

use super::registry::CommandEntry;

fn run(args: &[String]) -> anyhow::Result<()> {
    let sub = args.get(2).map(String::as_str);
    if !matches!(sub, Some("restore" | "snapshot")) {
        anyhow::bail!("usage: chump registry restore <path|refs/stash/registry/<date>> | snapshot");
    }
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let script = std::path::Path::new(&root).join("scripts/ops/registry-snapshot.sh");
    let status = std::process::Command::new("bash")
        .arg(script)
        .args(&args[2..])
        .status()?;
    if !status.success() {
        anyhow::bail!("registry-snapshot.sh exited {status}");
    }
    Ok(())
}

inventory::submit! { CommandEntry::new("registry", run) }
