use anyhow::{Context, Result};
use chrono::Utc;
/// RESILIENT-1614: Node pause/resume commands to enforce paused mode as an invariant.
/// Makes fleet pause honored by all work organs (node-converge, organ-reconcile,
/// organ-deploy, paramedic, process-organ-heal, self-doctor, worker loop).
///
/// `chump node pause --reason "reason"` and `chump node resume` manage the pause state
/// by writing to node.env + emitting lifecycle events.
use std::fs;
use std::path::PathBuf;

pub struct NodeModeState {
    node_env_path: PathBuf,
    state_dir: PathBuf,
    /// Repo root the kill-switch sentinel path resolves against — the same root
    /// the farmer gate and the shared pause predicate read (RESILIENT-1652).
    repo_root: PathBuf,
}

impl NodeModeState {
    /// Resolve node.env and state directory paths.
    pub fn new(state_dir: Option<PathBuf>) -> Result<Self> {
        let state_dir = state_dir
            .or_else(|| std::env::var("CHUMP_STATE_DIR").ok().map(PathBuf::from))
            .or_else(|| {
                let home = std::env::var("HOME").ok()?;
                Some(PathBuf::from(home).join(".chump"))
            })
            .context("unable to resolve state directory; set CHUMP_STATE_DIR or HOME")?;

        let node_env_path = state_dir.join("node.env");
        Ok(NodeModeState {
            node_env_path,
            state_dir,
            repo_root: crate::repo_path::repo_root(),
        })
    }

    /// Pause the node: set CHUMP_NODE_MODE=paused in node.env and emit the pause
    /// event.
    ///
    /// RESILIENT-1652/1653: the durable pause signal is `node.env`
    /// `CHUMP_NODE_MODE=paused` — the shared predicate ([`crate::node_pause`])
    /// and the farmer gate both read it. `chump node pause` deliberately does
    /// NOT write the `.chump/fleet-paused` kill-switch sentinel: that sentinel
    /// is owned by the ci-health-gate / waste-SLO path and is a HARD RED the
    /// farmer gate never relaxes (RESILIENT-1636 RED2). Writing it here would
    /// wall every bot-merge re-entry on a verb-paused node — the exact
    /// ship-wall this program fixes. (The former write landed at the doubled
    /// `~/.chump/.chump/fleet-paused` path no reader checked; un-doubling it to
    /// the real kill-switch path would have activated that wall, so it is
    /// removed entirely. The operator's reason is carried by the
    /// `kind=node_paused` ambient event.)
    pub fn pause(&self, reason: &str) -> Result<()> {
        // Read current node.env
        let mut contents = if self.node_env_path.exists() {
            fs::read_to_string(&self.node_env_path)?
        } else {
            String::new()
        };

        // Update CHUMP_NODE_MODE line
        self.update_or_add_line(&mut contents, "CHUMP_NODE_MODE", "paused");

        // Write updated node.env
        fs::write(&self.node_env_path, &contents).context("failed to write node.env")?;

        // Emit node_paused event (carries the operator reason + actor).
        let actor = std::env::var("USER").unwrap_or_else(|_| "unknown".to_string());
        self.emit_ambient(
            "node_paused",
            &format!(
                r#""reason":"{}","actor":"{}""#,
                escape_json_string(reason),
                escape_json_string(&actor)
            ),
        )?;

        Ok(())
    }

    /// Resume the node: set CHUMP_NODE_MODE=work-ready in node.env and emit the
    /// resume event. RESILIENT-1652/1653: pause never wrote the kill-switch
    /// sentinel, so resume never removes it — the `.chump/fleet-paused` sentinel
    /// is the ci-health-gate's to clear on its own recovery, not node resume's.
    pub fn resume(&self) -> Result<()> {
        // Read current node.env
        let mut contents = if self.node_env_path.exists() {
            fs::read_to_string(&self.node_env_path)?
        } else {
            String::new()
        };

        // Update CHUMP_NODE_MODE line
        self.update_or_add_line(&mut contents, "CHUMP_NODE_MODE", "work-ready");

        // Write updated node.env
        fs::write(&self.node_env_path, &contents).context("failed to write node.env")?;

        // Emit node_resumed event
        self.emit_ambient("node_resumed", "")?;

        Ok(())
    }

    /// Check if the node is currently paused — the pause DETECTOR half of the
    /// ONE predicate shared with the farmer gate (RESILIENT-1652). Reads
    /// `node.env` (both line forms + the legacy control-plane form) and the repo
    /// `.chump/fleet-paused` kill switch.
    pub fn is_paused(&self) -> Result<bool> {
        Ok(crate::node_pause::is_paused(
            &self.repo_root,
            &self.node_env_path,
        ))
    }

    /// Update or add a line in node.env. INFRA-8588: node.env must be the single
    /// systemd-compatible form (bare `KEY=VALUE`, no `export` — systemd's
    /// EnvironmentFile parser rejects `export` lines), so we match an EXISTING
    /// line in either form (to migrate a pre-INFRA-8588 file in place) but always
    /// write the bare form via chump_provision::node_env::render_line.
    fn update_or_add_line(&self, contents: &mut String, key: &str, value: &str) {
        let bare_prefix = format!("{}=", key);
        let export_prefix = format!("export {}=", key);
        let is_match = |line: &str| {
            let t = line.trim_start();
            t.starts_with(&bare_prefix) || t.starts_with(&export_prefix)
        };
        let new_line = chump_provision::node_env::render_line(key, value);

        if contents.lines().any(is_match) {
            // Replace existing line (migrates `export KEY=` → bare `KEY=`).
            *contents = contents
                .lines()
                .map(|line| {
                    if is_match(line) {
                        new_line.clone()
                    } else {
                        line.to_string()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            if !contents.ends_with('\n') {
                contents.push('\n');
            }
        } else {
            // Add new line
            if !contents.ends_with('\n') && !contents.is_empty() {
                contents.push('\n');
            }
            contents.push_str(&new_line);
            contents.push('\n');
        }
    }

    /// Emit an ambient event.
    fn emit_ambient(&self, kind: &str, extra: &str) -> Result<()> {
        let ambient_path = self.state_dir.join("ambient.jsonl");

        let ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let event = if extra.is_empty() {
            format!(r#"{{"ts":"{}","kind":"{}"}}"#, ts, kind)
        } else {
            format!(r#"{{"ts":"{}","kind":"{}",{}}}"#, ts, kind, extra)
        };

        // Try to create the ambient file if it doesn't exist, but don't fail if we can't
        if let Some(parent) = ambient_path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        match fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient_path)
        {
            Ok(mut file) => {
                use std::io::Write;
                let _ = writeln!(file, "{}", event);
            }
            Err(_) => {
                // Ambient emit is best-effort; don't fail if we can't write it
            }
        }

        Ok(())
    }
}

/// Escape special characters in JSON strings.
fn escape_json_string(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Build a state whose repo_root and state_dir are both the temp dir, so
    /// the pause detector reads node.env + the (absent) repo sentinel there.
    fn state_at(path: &std::path::Path) -> NodeModeState {
        NodeModeState {
            node_env_path: path.join("node.env"),
            state_dir: path.to_path_buf(),
            repo_root: path.to_path_buf(),
        }
    }

    #[test]
    fn test_pause_resume_cycle() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();

        fs::create_dir_all(state_path.join(".chump"))?;

        let state = state_at(state_path);

        // Initially not paused
        assert!(!state.is_paused()?);

        // Pause the node
        state.pause("test pause reason")?;
        assert!(state.is_paused()?);

        // Verify node.env was updated — INFRA-8588: bare, no `export`.
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("CHUMP_NODE_MODE=paused"));
        assert!(
            chump_provision::node_env::export_violations(&contents).is_empty(),
            "pause must not write an export line: {contents:?}"
        );

        // RESILIENT-1652/1653: pause does NOT write the `.chump/fleet-paused`
        // kill switch (that would wall re-entry on a verb-paused node), and
        // NEVER the old doubled `.chump/.chump` path.
        assert!(!state_path.join(".chump").join("fleet-paused").exists());
        assert!(!state_path
            .join(".chump")
            .join(".chump")
            .join("fleet-paused")
            .exists());

        // Resume the node
        state.resume()?;
        assert!(!state.is_paused()?);

        // Verify node.env was updated — INFRA-8588: bare, no `export`.
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        assert!(contents.contains("CHUMP_NODE_MODE=work-ready"));
        assert!(
            chump_provision::node_env::export_violations(&contents).is_empty(),
            "resume must not write an export line: {contents:?}"
        );

        Ok(())
    }

    #[test]
    fn pause_detector_recognises_legacy_control_plane_form() -> Result<()> {
        // RESILIENT-1652: the cuphead pause form (control-plane + WORK_ENABLED=0,
        // set before the pause verb existed) must read as paused.
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(
            state_path.join("node.env"),
            "export CHUMP_NODE_MODE=control-plane\nexport CHUMP_NODE_WORK_ENABLED=0\n",
        )?;
        let state = state_at(state_path);
        assert!(state.is_paused()?);
        Ok(())
    }

    #[test]
    fn pause_detector_reads_repo_kill_switch_sentinel() -> Result<()> {
        // RESILIENT-1653 AC2: the detector reads the repo `.chump/fleet-paused`
        // sentinel — the same path the farmer and ci-health-gate share.
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(state_path.join("node.env"), "CHUMP_NODE_MODE=work-ready\n")?;
        let state = state_at(state_path);
        assert!(!state.is_paused()?);
        fs::write(crate::node_pause::sentinel_path(state_path), "slo_breach")?;
        assert!(state.is_paused()?);
        Ok(())
    }

    #[test]
    fn pause_preserves_existing_line_forms_of_other_keys() -> Result<()> {
        // RESILIENT-1653 AC3 / task (4): writing node.env preserves each OTHER
        // existing line verbatim (bare stays bare, export stays export); only
        // the CHUMP_NODE_MODE line is normalised to the single documented
        // systemd-compatible bare form (INFRA-8588).
        let temp_dir = TempDir::new()?;
        let state_path = temp_dir.path();
        fs::create_dir_all(state_path.join(".chump"))?;
        fs::write(
            state_path.join("node.env"),
            "export CHUMP_STATE_DIR=/home/ubuntu/.chump\n\
             CHUMP_MAX_CONCURRENT_CARGO_JOBS=2\n\
             export CHUMP_RUN_USER=ubuntu\n\
             export CHUMP_NODE_MODE=work-ready\n",
        )?;
        let state = state_at(state_path);
        state.pause("maintenance")?;
        let contents = fs::read_to_string(state_path.join("node.env"))?;
        // Other lines kept verbatim — bare stays bare, export stays export.
        assert!(
            contents.contains("export CHUMP_STATE_DIR=/home/ubuntu/.chump"),
            "bare/export form of other keys must be preserved: {contents:?}"
        );
        assert!(contents.contains("\nCHUMP_MAX_CONCURRENT_CARGO_JOBS=2"));
        assert!(contents.contains("export CHUMP_RUN_USER=ubuntu"));
        // The written key is the single documented bare form.
        assert!(contents.contains("CHUMP_NODE_MODE=paused"));
        assert!(!contents.contains("export CHUMP_NODE_MODE="));
        Ok(())
    }
}
