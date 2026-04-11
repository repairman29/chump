//! Tool routing: detect installed CLI tools at startup, generate routing table for system prompt.
//! The routing table tells Chump which tool to reach for in each situation.
//! Called once at startup; cached for the process lifetime.

use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

static TOOL_AVAILABILITY: OnceLock<ToolAvailability> = OnceLock::new();
static LOGGED: AtomicBool = AtomicBool::new(false);

/// Check which CLI tools are installed and cache the result.
pub fn tools() -> &'static ToolAvailability {
    TOOL_AVAILABILITY.get_or_init(ToolAvailability::detect)
}

/// Log installed tools once per process at startup.
pub fn log_tool_inventory() {
    if LOGGED.swap(true, Ordering::Relaxed) {
        return;
    }
    let t = tools();
    let available: Vec<&str> = t
        .all_checks()
        .iter()
        .filter(|(_, installed)| *installed)
        .map(|(name, _)| *name)
        .collect();
    let missing: Vec<&str> = t
        .all_checks()
        .iter()
        .filter(|(_, installed)| !*installed)
        .map(|(name, _)| *name)
        .collect();
    let msg = format!(
        "Tools: {}/{} installed. Available: {}. Missing: {}",
        available.len(),
        available.len() + missing.len(),
        available.join(", "),
        if missing.is_empty() {
            "none".to_string()
        } else {
            missing.join(", ")
        }
    );
    eprintln!("[tool_routing] {}", msg);
}

pub struct ToolAvailability {
    // Code search & navigation
    pub rg: bool,
    pub fd: bool,
    pub tree: bool,
    pub tokei: bool,
    pub ast_grep: bool,
    // Code quality
    pub cargo_nextest: bool,
    pub cargo_audit: bool,
    pub cargo_outdated: bool,
    pub cargo_deny: bool,
    pub cargo_tarpaulin: bool,
    pub cargo_expand: bool,
    pub cargo_watch: bool,
    pub flamegraph: bool,
    // Data processing
    pub jq: bool,
    pub yq: bool,
    pub xsv: bool,
    pub sd: bool,
    pub htmlq: bool,
    // System monitoring
    pub btm: bool,
    pub dust: bool,
    pub procs: bool,
    pub bandwhich: bool,
    // Network
    pub xh: bool,
    pub dog: bool,
    // Git
    pub delta: bool,
    pub git_absorb: bool,
    pub gitleaks: bool,
    // Docs
    pub pandoc: bool,
    pub mdbook: bool,
    // Automation
    pub just: bool,
    pub watchexec: bool,
    pub hyperfine: bool,
    pub nu: bool,
    // AI
    pub ollama: bool,
}

impl ToolAvailability {
    fn detect() -> Self {
        Self {
            rg: has("rg"),
            fd: has("fd"),
            tree: has("tree"),
            tokei: has("tokei"),
            ast_grep: has("ast-grep"),
            cargo_nextest: has("cargo-nextest"),
            cargo_audit: has("cargo-audit"),
            cargo_outdated: has("cargo-outdated"),
            cargo_deny: has("cargo-deny"),
            cargo_tarpaulin: has("cargo-tarpaulin"),
            cargo_expand: has("cargo-expand"),
            cargo_watch: has("cargo-watch"),
            flamegraph: has("flamegraph"),
            jq: has("jq"),
            yq: has("yq"),
            xsv: has("xsv"),
            sd: has("sd"),
            htmlq: has("htmlq"),
            btm: has("btm"),
            dust: has("dust"),
            procs: has("procs"),
            bandwhich: has("bandwhich"),
            xh: has("xh"),
            dog: has("dog"),
            delta: has("delta"),
            git_absorb: has("git-absorb"),
            gitleaks: has("gitleaks"),
            pandoc: has("pandoc"),
            mdbook: has("mdbook"),
            just: has("just"),
            watchexec: has("watchexec"),
            hyperfine: has("hyperfine"),
            nu: has("nu"),
            ollama: has("ollama"),
        }
    }

    /// Return all (name, installed) pairs for logging and inventory.
    pub fn all_checks(&self) -> Vec<(&str, bool)> {
        vec![
            ("rg", self.rg),
            ("fd", self.fd),
            ("tree", self.tree),
            ("tokei", self.tokei),
            ("ast-grep", self.ast_grep),
            ("cargo-nextest", self.cargo_nextest),
            ("cargo-audit", self.cargo_audit),
            ("cargo-outdated", self.cargo_outdated),
            ("cargo-deny", self.cargo_deny),
            ("cargo-tarpaulin", self.cargo_tarpaulin),
            ("cargo-expand", self.cargo_expand),
            ("cargo-watch", self.cargo_watch),
            ("flamegraph", self.flamegraph),
            ("jq", self.jq),
            ("yq", self.yq),
            ("xsv", self.xsv),
            ("sd", self.sd),
            ("htmlq", self.htmlq),
            ("btm", self.btm),
            ("dust", self.dust),
            ("procs", self.procs),
            ("bandwhich", self.bandwhich),
            ("xh", self.xh),
            ("dog", self.dog),
            ("delta", self.delta),
            ("git-absorb", self.git_absorb),
            ("gitleaks", self.gitleaks),
            ("pandoc", self.pandoc),
            ("mdbook", self.mdbook),
            ("just", self.just),
            ("watchexec", self.watchexec),
            ("hyperfine", self.hyperfine),
            ("nu", self.nu),
            ("ollama", self.ollama),
        ]
    }

    /// Generate the routing table string for the system prompt.
    /// Only includes tools that are actually installed; provides fallbacks for missing ones.
    pub fn routing_table(&self) -> String {
        let mut r = String::from("\n## Tool Routing — check this before every run_cli call\n\n");

        // Search
        r.push_str("SEARCH CODE:\n");
        if self.rg {
            r.push_str(
                "  find text in code → run_cli \"rg 'pattern' src/\" (fast, .gitignore-aware)\n",
            );
        } else {
            r.push_str("  find text in code → run_cli \"grep -rn 'pattern' src/\"\n");
        }
        if self.fd {
            r.push_str(
                "  find files by name → run_cli \"fd 'pattern'\" (fast, .gitignore-aware)\n",
            );
        } else {
            r.push_str("  find files by name → run_cli \"find . -name 'pattern'\"\n");
        }
        if self.ast_grep {
            r.push_str("  find code by structure → run_cli \"ast-grep -p 'pattern' src/\"\n");
        }
        if self.tokei {
            r.push_str("  count lines / languages → run_cli \"tokei\"\n");
        }
        if self.tree {
            r.push_str("  show directory tree → run_cli \"tree -L 2\" (not ls -R)\n");
        }

        // Read / edit (native tools — always available)
        r.push_str("\nREAD/EDIT CODE:\n");
        r.push_str("  read file in repo → read_file (native, not cat)\n");
        r.push_str("  list directory → list_dir (native, not ls)\n");
        r.push_str("  change code → patch_file (unified diff; safer than blind write_file)\n");
        r.push_str("  create/overwrite file → write_file (native)\n");
        r.push_str("  read GitHub file → github_repo_read (native, not curl)\n");

        // Test
        r.push_str("\nTEST:\n");
        if self.cargo_nextest {
            r.push_str("  run tests → run_cli \"cargo nextest run\" (faster, better output)\n");
            r.push_str("  run one test → run_cli \"cargo nextest run -E 'test(name)'\"\n");
        } else {
            r.push_str("  run tests → run_cli \"cargo test\"\n");
            r.push_str("  run one test → run_cli \"cargo test test_name\"\n");
        }
        if self.cargo_tarpaulin {
            r.push_str("  test coverage → run_cli \"cargo tarpaulin --out stdout\"\n");
        }

        // Quality
        r.push_str("\nQUALITY:\n");
        r.push_str("  lint → run_cli \"cargo clippy 2>&1\"\n");
        if self.cargo_audit {
            r.push_str("  security audit → run_cli \"cargo audit\"\n");
        }
        if self.cargo_outdated {
            r.push_str("  outdated deps → run_cli \"cargo outdated\"\n");
        }
        if self.cargo_deny {
            r.push_str("  license + advisory check → run_cli \"cargo deny check\"\n");
        }

        // Git (mix of native + CLI)
        r.push_str("\nGIT:\n");
        r.push_str("  see changes → run_cli \"git diff --stat\" then \"git diff\"\n");
        if self.delta {
            r.push_str("  readable diff → run_cli \"git diff | delta\"\n");
        }
        r.push_str("  commit → git_commit (native, not run_cli)\n");
        if std::env::var("CHUMP_AUTO_PUBLISH")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
        {
            r.push_str("  push → git_push (native; may push to main, tag releases, push --tags)\n");
        } else {
            r.push_str("  push → git_push (native, always to chump/* branch)\n");
        }
        r.push_str("  create branch → gh_create_branch (native)\n");
        r.push_str("  open PR → gh_create_pr (native)\n");
        r.push_str("  check CI → gh_pr_checks (native)\n");
        r.push_str("  self-review before commit → diff_review (native)\n");
        if self.git_absorb {
            r.push_str("  clean up fixup commits → run_cli \"git absorb\"\n");
        }
        if self.gitleaks {
            r.push_str("  scan for leaked secrets → run_cli \"gitleaks detect\"\n");
        }

        // Data
        r.push_str("\nDATA PROCESSING:\n");
        if self.jq {
            r.push_str("  parse/query JSON → run_cli with jq (not grep on JSON)\n");
        }
        if self.yq {
            r.push_str("  parse YAML/TOML → run_cli with yq\n");
        }
        if self.xsv {
            r.push_str("  process CSV → run_cli with xsv\n");
        }
        if self.sd {
            r.push_str("  find-replace in text → run_cli with sd (not sed)\n");
        }
        if self.htmlq {
            r.push_str("  extract from HTML → run_cli with htmlq (not regex on HTML)\n");
        }

        // Web / research (native tools)
        r.push_str("\nWEB / RESEARCH:\n");
        r.push_str(
            "  search for info → web_search (Tavily, limited credits — one focused query)\n",
        );
        r.push_str("  read full web page → read_url (native) or run_cli \"curl -s URL\"\n");
        r.push_str("  check what CLI tools are installed → toolkit_status (native)\n");

        // System
        r.push_str("\nSYSTEM:\n");
        if self.dust {
            r.push_str("  disk space → run_cli \"dust\" (visual, better than df)\n");
        } else {
            r.push_str("  disk space → run_cli \"df -h\"\n");
        }
        if self.procs {
            r.push_str("  processes → run_cli \"procs\" (better than ps aux)\n");
        }

        // Task management (native tools — always available)
        r.push_str("\nTASK MANAGEMENT:\n");
        r.push_str("  track work → task (native)\n");
        r.push_str("  set reminder → schedule (native, fire_at as 4h/2d/30m)\n");
        r.push_str("  tell Jeff → notify (native, Discord DM)\n");

        // Self (native tools — always available)
        r.push_str("\nSELF:\n");
        r.push_str("  inner state → ego (native)\n");
        r.push_str("  log events → episode (native)\n");
        r.push_str("  wiki/notes → memory_brain (native)\n");
        r.push_str("  facts → memory (native)\n");

        // Rules
        r.push_str("\nRULES:\n");
        r.push_str("  Native tool > run_cli (when both can do it)\n");
        r.push_str("  Specialized CLI > generic (rg > grep, jq > grep on JSON, fd > find)\n");
        r.push_str("  Before complex CLI ops, check your notes: memory_brain read tools/<n>.md\n");

        r
    }

    /// Short routing table for companion/Mabel mode (CHUMP_MABEL=1).
    /// Omits dev-only CLI sections so the prompt stays small and relevant on Pixel.
    pub fn routing_table_companion(&self) -> String {
        let mut r = String::from("\n## Tools (companion)\n\n");
        r.push_str("  memory — store/recall facts (key/value)\n");
        r.push_str("  calculator — math expressions\n");
        r.push_str("  read_file, list_dir, write_file, patch_file — paths under current dir (~/chump on Pixel)\n");
        r.push_str("  task — track work (native)\n");
        r.push_str("  schedule — set reminder; fire_at as 4h/2d/30m (native)\n");
        r.push_str("  notify — tell user via Discord DM (native)\n");
        r.push_str("  ego — inner state (native)\n");
        r.push_str("  episode — log events (native)\n");
        r.push_str("  memory_brain — wiki/notes (native)\n");
        r.push_str("  read_url — fetch a URL's content (native)\n");
        r.push_str("  run_cli — only when CHUMP_CLI_ALLOWLIST permits; use sparingly\n");
        r.push_str("  web_search — when TAVILY_API_KEY set (one focused query)\n");
        if std::env::var("CHUMP_A2A_PEER_USER_ID")
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
        {
            r.push_str("  message_peer — send a message to the other bot (Chump/Mabel) over Discord; they can reply here\n");
        }
        r.push_str("\nUse native tools over run_cli when both can do the job. Reply with final answer only; no <think> or think> in output.\n");
        r
    }
}

fn has(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_does_not_panic() {
        let t = ToolAvailability::detect();
        let _ = t.rg;
        let _ = t.jq;
    }

    #[test]
    fn routing_table_is_not_empty() {
        let t = ToolAvailability::detect();
        let table = t.routing_table();
        assert!(table.contains("SEARCH CODE"));
        assert!(table.contains("RULES"));
        assert!(table.len() > 200);
    }

    #[test]
    fn all_checks_returns_all_tools() {
        let t = ToolAvailability::detect();
        let checks = t.all_checks();
        assert!(checks.len() >= 30);
    }

    #[test]
    fn routing_table_companion_contains_tools() {
        let t = ToolAvailability::detect();
        let table = t.routing_table_companion();
        assert!(table.contains("memory"));
        assert!(table.contains("read_file"));
        assert!(table.contains("CHUMP_CLI_ALLOWLIST"));
        assert!(table.contains("companion"));
    }
}
