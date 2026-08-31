//! Bat-phone mission intake (EFFECTIVE-513).
//!
//! `POST /api/mission` — an authenticated external task/mission intake. The
//! operator (or any authorized caller) posts a mission; the server turns it
//! into a *decomposed* gap — born with acceptance criteria + slices via the
//! free-tier `chump gap decompose` path — and hands the fleet a new job
//! WITHOUT halting anything. This is the second dispatch source alongside
//! `next_best_action`: the normal worker/orchestrator queue picks up the
//! reserved slices on its own cadence.
//!
//! ## Flow
//!
//! 1. `chump gap reserve` — mints a fresh gap id (fast).
//! 2. `chump gap set` — attaches description + seed AC (fast).
//! 3. `chump gap decompose --apply` — spawned DETACHED. The decomposer runs
//!    an LLM (free-tier local/openrouter) for ~1–2 min, so it must never block
//!    the HTTP response or the async runtime. The child is intentionally not
//!    awaited; on Unix, dropping the handle does not kill it, so it runs to
//!    completion and files the slices, which the fleet then drains normally.
//!
//! ## Security
//!
//! An open mission-injection endpoint is dangerous, so the route is
//! **fail-closed**: it requires a bearer token from `CHUMP_BATPHONE_TOKEN`. If
//! that env var is unset/empty the route refuses every request. The token
//! comparison is constant-time.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

/// Env var holding the shared bearer token. Fail-closed when unset/empty.
pub const BATPHONE_TOKEN_ENV: &str = "CHUMP_BATPHONE_TOKEN";
/// Optional override for the chump binary path.
pub const CHUMP_BIN_ENV: &str = "CHUMP_BIN";

/// Default gap domain for operator missions when the body omits `domain`.
const DEFAULT_DOMAIN: &str = "MISSION";
/// Default priority when the body omits `priority`.
const DEFAULT_PRIORITY: &str = "P1";
/// Default effort. `l` guarantees `chump gap decompose` actually slices
/// (effort=s is a decomposer no-op), so the gap is born sliced.
const DEFAULT_EFFORT: &str = "l";

/// Inbound mission payload for `POST /api/mission`.
#[derive(Debug, Deserialize)]
pub struct MissionRequest {
    /// Short human-readable title (required).
    pub title: String,
    /// The mission intent / what to do. Alias of `description`.
    #[serde(default)]
    pub intent: Option<String>,
    /// Longer description (used if `intent` is absent).
    #[serde(default)]
    pub description: Option<String>,
    /// Priority `P0`..`P3` (default `P1`).
    #[serde(default)]
    pub priority: Option<String>,
    /// The desired outcome; seeds acceptance criteria when `acceptance_criteria`
    /// is not supplied.
    #[serde(default)]
    pub outcome: Option<String>,
    /// Gap domain / id prefix (default `MISSION`).
    #[serde(default)]
    pub domain: Option<String>,
    /// Effort `s|m|l|xl` (default `l`).
    #[serde(default)]
    pub effort: Option<String>,
    /// Explicit `a|b|c` acceptance criteria; overrides `outcome`.
    #[serde(default)]
    pub acceptance_criteria: Option<String>,
}

/// Result of a successful intake, serialized back to the caller.
#[derive(Debug, Serialize)]
pub struct MissionOutcome {
    pub gap_id: String,
    pub domain: String,
    pub priority: String,
    pub status: String,
    pub decompose: String,
    pub detail: String,
}

/// Read the configured token. `None` when unset or empty (fail-closed).
pub fn configured_token() -> Option<String> {
    match std::env::var(BATPHONE_TOKEN_ENV) {
        Ok(t) if !t.trim().is_empty() => Some(t),
        _ => None,
    }
}

/// Constant-time string comparison to avoid leaking the token via timing.
/// Length is not treated as secret.
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let a = a.as_bytes();
    let b = b.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Resolve the chump binary: `CHUMP_BIN` env, else the built release binary in
/// the repo, else bare `chump` on PATH.
fn resolve_chump_bin(repo_root: &Path) -> PathBuf {
    if let Ok(p) = std::env::var(CHUMP_BIN_ENV) {
        if !p.trim().is_empty() {
            return PathBuf::from(p);
        }
    }
    let built = repo_root.join("target").join("release").join("chump");
    if built.exists() {
        return built;
    }
    PathBuf::from("chump")
}

/// True when `s` looks like a gap id, e.g. `MISSION-42` / `INFRA-3860`.
fn is_gap_id(s: &str) -> bool {
    let Some((prefix, num)) = s.split_once('-') else {
        return false;
    };
    !prefix.is_empty()
        && prefix.chars().all(|c| c.is_ascii_uppercase())
        && !num.is_empty()
        && num.chars().all(|c| c.is_ascii_digit())
}

/// Extract the last gap-id line from `chump gap reserve` stdout.
fn parse_gap_id(stdout: &str) -> Option<String> {
    stdout
        .lines()
        .map(str::trim)
        .rfind(|l| is_gap_id(l))
        .map(str::to_string)
}

/// Keep a domain to uppercase alphanumerics (id prefixes only). Command args
/// are passed directly (no shell), so this is field-hygiene, not injection
/// defense.
fn sanitize_domain(s: &str) -> String {
    let cleaned: String = s
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    if cleaned.is_empty() {
        DEFAULT_DOMAIN.to_string()
    } else {
        cleaned.to_uppercase()
    }
}

fn sanitize_priority(p: Option<&str>) -> String {
    match p.map(|s| s.trim().to_uppercase()) {
        Some(s) if matches!(s.as_str(), "P0" | "P1" | "P2" | "P3") => s,
        _ => DEFAULT_PRIORITY.to_string(),
    }
}

fn sanitize_effort(e: Option<&str>) -> String {
    match e.map(|s| s.trim().to_lowercase()) {
        Some(s) if matches!(s.as_str(), "s" | "m" | "l" | "xl") => s,
        _ => DEFAULT_EFFORT.to_string(),
    }
}

/// Reserve a gap from the mission, attach description + AC, and spawn a
/// detached decompose. Blocking (shells out to `chump`); call from
/// `spawn_blocking`.
pub fn create_mission_gap(repo_root: &Path, req: MissionRequest) -> anyhow::Result<MissionOutcome> {
    let title = req.title.trim().to_string();
    if title.is_empty() {
        anyhow::bail!("title is required");
    }
    let chump = resolve_chump_bin(repo_root);
    let domain = sanitize_domain(req.domain.as_deref().unwrap_or(DEFAULT_DOMAIN));
    let priority = sanitize_priority(req.priority.as_deref());
    let effort = sanitize_effort(req.effort.as_deref());

    // 1. Reserve — mints the gap id.
    let reserve = Command::new(&chump)
        .current_dir(repo_root)
        .args([
            "gap",
            "reserve",
            "--domain",
            &domain,
            "--title",
            &title,
            "--priority",
            &priority,
            "--effort",
            &effort,
        ])
        .output()
        .map_err(|e| anyhow::anyhow!("failed to spawn `chump gap reserve`: {e}"))?;
    if !reserve.status.success() {
        anyhow::bail!(
            "`chump gap reserve` failed: {}",
            String::from_utf8_lossy(&reserve.stderr).trim()
        );
    }
    let stdout = String::from_utf8_lossy(&reserve.stdout);
    let gap_id = parse_gap_id(&stdout).ok_or_else(|| {
        anyhow::anyhow!(
            "could not parse gap id from reserve output: {}",
            stdout.trim()
        )
    })?;

    // 2. Set description + seed AC. Best-effort: the gap already exists, so a
    //    set failure is logged, not fatal.
    let description = req
        .intent
        .as_deref()
        .or(req.description.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(&title)
        .to_string();
    let ac = req
        .acceptance_criteria
        .as_deref()
        .or(req.outcome.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let mut set_args: Vec<String> = vec![
        "gap".into(),
        "set".into(),
        gap_id.clone(),
        "--description".into(),
        description,
    ];
    if let Some(ac) = ac.as_ref() {
        set_args.push("--acceptance-criteria".into());
        set_args.push(ac.clone());
    }
    match Command::new(&chump)
        .current_dir(repo_root)
        .args(&set_args)
        .output()
    {
        Ok(o) if !o.status.success() => {
            tracing::warn!(
                gap = %gap_id,
                "`chump gap set` failed: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
        }
        Err(e) => tracing::warn!(gap = %gap_id, "failed to spawn `chump gap set`: {e}"),
        _ => {}
    }

    // 3. Spawn `chump gap decompose --apply` DETACHED — never awaited.
    let decompose = spawn_decompose(&chump, repo_root, &gap_id)
        .map(|_| "spawned".to_string())
        .unwrap_or_else(|e| format!("spawn_failed: {e}"));

    Ok(MissionOutcome {
        gap_id,
        domain,
        priority,
        status: "reserved".into(),
        decompose,
        detail:
            "gap reserved; decompose-at-file spawned in background; fleet queue picks up the slices"
                .into(),
    })
}

/// Spawn a detached `chump gap decompose <id> --apply`, logging to
/// `.chump/batphone-decompose.log`. The child is dropped (not awaited); on Unix
/// this does not kill it.
///
/// The decompose is routed through the sovereign free-tier PROVIDER SELECTOR
/// (`scripts/dispatch/lib/decompose-provider.sh::pick_decompose_provider`,
/// shipped in #4314; already used by gap-drain.sh + worker.sh). Without it the
/// spawned `chump` would inherit the fleet-server process env, auto-select the
/// local `llama3.2:3b`, and emit schema-invalid JSON -> parse error -> zero
/// slices (EFFECTIVE-513). We therefore spawn a LOGIN SHELL that first sources
/// the selector and calls `pick_decompose_provider` (which exports
/// OPENAI_API_BASE/KEY/MODEL to a capable free-tier model — gemini-3.6-flash /
/// groq, never the 3B), then execs the decompose. All paths + the gap id are
/// passed as positional args (\$1..\$3) so nothing is interpolated into the
/// shell string. Still fully DETACHED — the HTTP handler never waits on it.
fn spawn_decompose(chump: &Path, repo_root: &Path, gap_id: &str) -> anyhow::Result<()> {
    let log_path = repo_root.join(".chump").join("batphone-decompose.log");
    if let Some(dir) = log_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let (out, err) = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        Ok(f) => match f.try_clone() {
            Ok(f2) => (Stdio::from(f), Stdio::from(f2)),
            Err(_) => (Stdio::null(), Stdio::null()),
        },
        Err(_) => (Stdio::null(), Stdio::null()),
    };
    let provider_sh = repo_root
        .join("scripts")
        .join("dispatch")
        .join("lib")
        .join("decompose-provider.sh");
    // Login shell: source the selector (defines + runs pick_decompose_provider,
    // which self-sources providers.env and exports OPENAI_*), then exec the
    // decompose so it inherits the capable free-tier route. Positional args:
    //   \$0 label  \$1 selector path  \$2 chump bin  \$3 gap id
    let wrapper = r#"
if [ -f "$1" ]; then
  # shellcheck disable=SC1090
  . "$1" 2>&1 && pick_decompose_provider || echo "[batphone] provider selection failed; proceeding with inherited env" >&2
else
  echo "[batphone] decompose-provider.sh not found at $1; proceeding with inherited env" >&2
fi
echo "[batphone] decompose route: OPENAI_API_BASE=${OPENAI_API_BASE:-<unset>} OPENAI_MODEL=${OPENAI_MODEL:-<unset>}" >&2
exec "$2" gap decompose "$3" --apply
"#;
    Command::new("bash")
        .current_dir(repo_root)
        .arg("-lc")
        .arg(wrapper)
        .arg("chump-batphone-decompose")
        .arg(&provider_sh)
        .arg(chump)
        .arg(gap_id)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .spawn()
        .map(|_child| ())
        .map_err(|e| anyhow::anyhow!("failed to spawn decompose login-shell: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constant_time_eq_matches_and_mismatches() {
        assert!(constant_time_eq("s3cret", "s3cret"));
        assert!(!constant_time_eq("s3cret", "s3crat"));
        assert!(!constant_time_eq("s3cret", "s3cre"));
        assert!(!constant_time_eq("", "x"));
        assert!(constant_time_eq("", ""));
    }

    #[test]
    fn parse_gap_id_takes_last_id_line() {
        let out = "checking registry health... ok\nreserving ID... done MISSION-42\nMISSION-42\n";
        assert_eq!(parse_gap_id(out).as_deref(), Some("MISSION-42"));
        assert_eq!(parse_gap_id("no id here\n"), None);
        assert_eq!(parse_gap_id("INFRA-3860\n").as_deref(), Some("INFRA-3860"));
    }

    #[test]
    fn is_gap_id_rules() {
        assert!(is_gap_id("MISSION-42"));
        assert!(is_gap_id("INFRA-3860"));
        assert!(!is_gap_id("mission-42"));
        assert!(!is_gap_id("MISSION-"));
        assert!(!is_gap_id("-42"));
        assert!(!is_gap_id("MISSION42"));
        assert!(!is_gap_id("MISSION-4a2"));
    }

    #[test]
    fn sanitizers_clamp_to_valid_values() {
        assert_eq!(sanitize_domain("mission"), "MISSION");
        assert_eq!(sanitize_domain("  in-fra! "), "INFRA");
        assert_eq!(sanitize_domain(""), "MISSION");
        assert_eq!(sanitize_priority(Some("p0")), "P0");
        assert_eq!(sanitize_priority(Some("garbage")), "P1");
        assert_eq!(sanitize_priority(None), "P1");
        assert_eq!(sanitize_effort(Some("XL")), "xl");
        assert_eq!(sanitize_effort(Some("huge")), "l");
        assert_eq!(sanitize_effort(None), "l");
    }
}
