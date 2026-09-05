//! RESILIENT-376: `chump node <list|status>` — SEE + health + place every
//! node in the fleet, including rescued/ad-hoc boxes like the Pixel.
//!
//! Component #2 of the Node Fabric (docs/design/NODE_FABRIC.md): the node
//! self-describe seed (RESILIENT-291, `scripts/dispatch/node-describe.sh`)
//! populates `docs/fleet/nodes/*.json`, but nothing read that registry back
//! out with a health signal — a node could sit there silently stale (or
//! simply never get a profile filed, as happened to pixel-8-pro: a 29-day
//! uptime node running heartbeat + postgres + discord-gateway with zero
//! ambient visibility) and nobody would notice. This subcommand is the SEE
//! half: list every declared node with an age-derived health class.
//!
//! Health is derived from the profile file's mtime, not a field inside the
//! JSON, so `node-describe.sh` doesn't need to change — re-running it (or
//! `chump node touch`) to refresh the file IS the heartbeat.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

const FRESH_MAX_SECS: u64 = 24 * 60 * 60; // < 1 day
const STALE_MAX_SECS: u64 = 7 * 24 * 60 * 60; // < 7 days

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Health {
    Fresh,
    Stale,
    Dead,
}

impl Health {
    fn as_str(self) -> &'static str {
        match self {
            Health::Fresh => "fresh",
            Health::Stale => "stale",
            Health::Dead => "dead",
        }
    }
}

/// Pure classifier — no filesystem, no clock. Testable without racing on
/// real mtimes.
pub fn classify_health(age_secs: u64) -> Health {
    if age_secs < FRESH_MAX_SECS {
        Health::Fresh
    } else if age_secs < STALE_MAX_SECS {
        Health::Stale
    } else {
        Health::Dead
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct NodeProfile {
    pub node_id: String,
    #[serde(default)]
    pub tailnet_ip: String,
    #[serde(default)]
    pub os: String,
    #[serde(default)]
    pub roles_fit: Vec<String>,
    #[serde(default)]
    pub services_running: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct NodeStatus {
    #[serde(flatten)]
    pub profile: NodeProfile,
    pub health: &'static str,
    pub age_secs: u64,
    pub source_file: String,
}

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        let p = PathBuf::from(r);
        if p.is_dir() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Default registry location: `<repo>/docs/fleet/nodes`.
pub fn nodes_dir() -> PathBuf {
    repo_root().join("docs/fleet/nodes")
}

fn file_age_secs(path: &Path) -> Result<u64> {
    let meta = fs::metadata(path).with_context(|| format!("stat {}", path.display()))?;
    let modified = meta.modified().with_context(|| "no mtime")?;
    let age = SystemTime::now()
        .duration_since(modified)
        .unwrap_or_default();
    Ok(age.as_secs())
}

/// Read every `*.json` node profile under `dir` and classify its health
/// from the file's mtime. Explicit `dir` param (rather than always reading
/// the env-resolved default) so tests can point at an isolated fixture
/// directory instead of racing on `CHUMP_REPO_ROOT` mutation.
pub fn list_nodes(dir: &Path) -> Result<Vec<NodeStatus>> {
    let mut out = Vec::new();
    if !dir.is_dir() {
        return Ok(out);
    }
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    entries.sort();

    for path in entries {
        let raw =
            fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
        let profile: NodeProfile = serde_json::from_str(&raw)
            .with_context(|| format!("parsing {} as NodeProfile", path.display()))?;
        let age_secs = file_age_secs(&path)?;
        let health = classify_health(age_secs).as_str();
        out.push(NodeStatus {
            profile,
            health,
            age_secs,
            source_file: path
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_default(),
        });
    }
    Ok(out)
}

fn print_help() {
    println!("Usage: chump node <subcommand> [args]");
    println!();
    println!("SEE + health + place every node in the fleet (RESILIENT-376).");
    println!();
    println!("Subcommands:");
    println!("  list [--json]              every declared node + health (fresh/stale/dead)");
    println!("  status <node_id> [--json]  single node detail");
}

fn print_table(rows: &[NodeStatus]) {
    if rows.is_empty() {
        println!(
            "(no nodes declared under docs/fleet/nodes/ — run scripts/dispatch/node-describe.sh)"
        );
        return;
    }
    println!(
        "{:<20} {:<10} {:<8} {:>10} ROLES_FIT",
        "NODE_ID", "OS", "HEALTH", "AGE(min)"
    );
    for r in rows {
        println!(
            "{:<20} {:<10} {:<8} {:>10} {}",
            r.profile.node_id,
            r.profile.os,
            r.health,
            r.age_secs / 60,
            r.profile.roles_fit.join(",")
        );
    }
}

pub fn run(args: &[String]) -> i32 {
    let sub = args.first().map(String::as_str);
    let json = args.iter().any(|a| a == "--json");

    match sub {
        Some("list") => {
            let dir = nodes_dir();
            match list_nodes(&dir) {
                Ok(rows) => {
                    if json {
                        match serde_json::to_string_pretty(&rows) {
                            Ok(s) => println!("{s}"),
                            Err(e) => {
                                eprintln!("chump node list: serialization error: {e}");
                                return 1;
                            }
                        }
                    } else {
                        print_table(&rows);
                    }
                    0
                }
                Err(e) => {
                    eprintln!("chump node list: {e:#}");
                    1
                }
            }
        }
        Some("status") => {
            let node_id = match args.get(1) {
                Some(id) if !id.starts_with("--") => id.clone(),
                _ => {
                    eprintln!("chump node status: missing <node_id>");
                    return 1;
                }
            };
            let dir = nodes_dir();
            match list_nodes(&dir) {
                Ok(rows) => match rows.into_iter().find(|r| r.profile.node_id == node_id) {
                    Some(row) => {
                        if json {
                            match serde_json::to_string_pretty(&row) {
                                Ok(s) => println!("{s}"),
                                Err(e) => {
                                    eprintln!("chump node status: serialization error: {e}");
                                    return 1;
                                }
                            }
                        } else {
                            print_table(std::slice::from_ref(&row));
                        }
                        0
                    }
                    None => {
                        eprintln!("chump node status: no profile for node_id '{node_id}' under docs/fleet/nodes/");
                        1
                    }
                },
                Err(e) => {
                    eprintln!("chump node status: {e:#}");
                    1
                }
            }
        }
        _ => {
            print_help();
            if sub.is_some() {
                1
            } else {
                0
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write_profile(dir: &Path, node_id: &str, contents: &str) {
        fs::write(dir.join(format!("{node_id}.json")), contents).unwrap();
    }

    #[test]
    fn classify_health_boundaries() {
        assert_eq!(classify_health(0), Health::Fresh);
        assert_eq!(classify_health(FRESH_MAX_SECS - 1), Health::Fresh);
        assert_eq!(classify_health(FRESH_MAX_SECS), Health::Stale);
        assert_eq!(classify_health(STALE_MAX_SECS - 1), Health::Stale);
        assert_eq!(classify_health(STALE_MAX_SECS), Health::Dead);
    }

    #[test]
    fn list_nodes_reads_every_profile_and_places_pixel() {
        let tmp = std::env::temp_dir().join(format!(
            "chump-node-test-{}-{}",
            std::process::id(),
            "list_nodes_reads_every_profile_and_places_pixel"
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        write_profile(
            &tmp,
            "mac",
            r#"{"node_id":"mac","os":"Darwin","roles_fit":["build-worker"]}"#,
        );
        write_profile(
            &tmp,
            "pixel",
            r#"{"node_id":"pixel-8-pro","os":"Android","tailnet_ip":"100.84.132.93","roles_fit":["atc-heartbeat"],"services_running":["chumpnode-heartbeat","postgres","discord-gateway"]}"#,
        );
        // A non-JSON file must be ignored, not error the whole read.
        fs::write(tmp.join("README.md"), "not a node profile").unwrap();

        let rows = list_nodes(&tmp).expect("list_nodes should succeed");
        assert_eq!(
            rows.len(),
            2,
            "expected exactly the 2 json profiles, got {rows:?}"
        );

        let pixel = rows
            .iter()
            .find(|r| r.profile.node_id == "pixel-8-pro")
            .expect("pixel-8-pro must be present in the registry read-back");
        assert_eq!(pixel.health, "fresh");
        assert!(pixel
            .profile
            .services_running
            .iter()
            .any(|s| s == "chumpnode-heartbeat"));

        fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn list_nodes_missing_dir_returns_empty_not_error() {
        let tmp = std::env::temp_dir().join("chump-node-test-does-not-exist-xyz");
        let _ = fs::remove_dir_all(&tmp);
        let rows = list_nodes(&tmp).expect("missing dir should not error");
        assert!(rows.is_empty());
    }
}
