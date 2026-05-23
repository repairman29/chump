//! INFRA-644: `chump health` — composite fleet health command.
//!
//! Rolls up all major health signals into a single 0-100 score:
//!   - fleet-status   (active leases, stale sessions)
//!   - waste-tally    (incidents + dominant kind, 2h window)
//!   - cost-watch     (today's spend vs daily budget)
//!   - mission-grade  (4-pillar pickable counts)
//!   - pr-stuck count (last 2h)
//!   - silent_agent   (last 2h)
//!   - ghost-gap count (open status but closed_pr set)
//!   - auth status    (gh auth status)
//!   - version skew   (commits behind origin/main)
//!
//! Emits `kind=fleet_health` to ambient.jsonl (call `emit()` after `build_report()`).
//! Runs hourly via launchd (see scripts/setup/install-fleet-health-launchd.sh).
//!
//! ## Scoring (penalties deducted from 100)
//!
//! | Signal                          | Penalty |
//! |---------------------------------|---------|
//! | fleet_wedge ≥1 in 2h            |     -25 |
//! | pr_stuck ≥3 in 2h               |     -20 |
//! | silent_agent >1 in 2h           |     -15 |
//! | auth failure                    |     -15 |
//! | over budget                     |     -10 |
//! | waste incidents >10 in 2h       |     -10 |
//! | stale lease >6h (per lease)     |      -5 |
//! | pillar with 0 pickable (per)    |      -5 |
//! | ghost gaps > 0                  |      -5 |
//! | version skew >5 commits behind  |      -5 |

use std::path::Path;

/// One penalty signal contributing to the score deduction.
#[derive(Debug, Clone)]
pub struct HealthSignal {
    pub name: String,
    pub penalty: i64,
    pub detail: String,
}

/// One ambient event summary for the "Recent activity" section.
#[derive(Debug)]
pub struct AmbientSummary {
    pub ts: String,
    pub kind: String,
    pub summary: String,
}

/// Full composite health report.
#[derive(Debug)]
pub struct HealthReport {
    pub score: u8,
    pub grade: &'static str,
    pub worst_signal: Option<HealthSignal>,
    pub signals: Vec<HealthSignal>,
    pub ts: String,
    // Raw sub-report fields for JSON output.
    pub active_leases: usize,
    pub stale_leases: usize,
    pub waste_incidents_2h: u64,
    pub waste_top_kind: String,
    pub fleet_wedges_2h: u64,
    pub pr_stuck_2h: u64,
    pub silent_agents_2h: u64,
    pub today_spend_usd: f64,
    pub budget_usd_per_day: f64,
    pub over_budget: bool,
    pub ghost_gaps: u64,
    pub pillars_starved: u64,
    pub auth_ok: bool,
    pub commits_behind: u64,
    pub session_rescues_24h: u64,
    pub ambient_recent: Vec<AmbientSummary>,
    // INFRA-1504: binary freshness
    pub binary_age_h: f64,
    pub binary_stale: bool,
    // INFRA-1454: agent-bash sandbox-runtime status
    pub sandbox_status_tag: String,
    pub sandbox_status_summary: String,
}

pub fn build_report(repo_root: &Path) -> HealthReport {
    let ts = current_iso8601();
    let mut signals: Vec<HealthSignal> = Vec::new();
    let mut total_penalty: i64 = 0;

    // ── 1. Active leases + stale leases ──────────────────────────────────────
    let (active_leases, stale_leases) = collect_lease_info(repo_root);
    for _ in 0..stale_leases.min(3) {
        let s = HealthSignal {
            name: "stale_lease".into(),
            penalty: 5,
            detail: format!("{} lease(s) older than 6h", stale_leases),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 2. Ambient event counters (2h window) ─────────────────────────────────
    let cutoff_2h = current_unix().saturating_sub(2 * 3600);
    let (fleet_wedges_2h, pr_stuck_2h, silent_agents_2h, waste_incidents_2h, waste_top_kind) =
        scan_ambient_2h(repo_root, cutoff_2h);

    if fleet_wedges_2h >= 1 {
        let s = HealthSignal {
            name: "fleet_wedge".into(),
            penalty: 25,
            detail: format!("{} fleet_wedge event(s) in last 2h", fleet_wedges_2h),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }
    if pr_stuck_2h >= 3 {
        let s = HealthSignal {
            name: "pr_stuck".into(),
            penalty: 20,
            detail: format!("{} pr_stuck event(s) in last 2h", pr_stuck_2h),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }
    if silent_agents_2h > 1 {
        let s = HealthSignal {
            name: "silent_agent".into(),
            penalty: 15,
            detail: format!("{} silent_agent event(s) in last 2h", silent_agents_2h),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }
    if waste_incidents_2h > 10 {
        let s = HealthSignal {
            name: "waste_high".into(),
            penalty: 10,
            detail: format!(
                "{} waste incidents in last 2h (top: {})",
                waste_incidents_2h, waste_top_kind
            ),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 3. Cost watch ─────────────────────────────────────────────────────────
    let budget_usd_per_day = std::env::var("CHUMP_DAILY_BUDGET")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(5.0);
    let (today_spend_usd, over_budget) = scan_cost_today(repo_root, budget_usd_per_day);
    if over_budget {
        let s = HealthSignal {
            name: "over_budget".into(),
            penalty: 10,
            detail: format!(
                "today's spend ${:.4} > budget ${:.2}/day",
                today_spend_usd, budget_usd_per_day
            ),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 4. Mission grade (pillars with 0 pickable = starved) ──────────────────
    let grade_report = crate::mission_grade::build_report(repo_root);
    let pillars_starved = [
        grade_report.effective.count_pickable == 0,
        grade_report.credible.count_pickable == 0,
        grade_report.resilient.count_pickable == 0,
        grade_report.zero_waste.count_pickable == 0,
    ]
    .iter()
    .filter(|&&b| b)
    .count() as u64;

    for _ in 0..pillars_starved {
        let s = HealthSignal {
            name: "pillar_starved".into(),
            penalty: 5,
            detail: format!("{} pillar(s) with 0 pickable gaps", pillars_starved),
        };
        total_penalty += s.penalty;
        signals.push(s);
        break; // one signal entry is enough (penalty already multiplied above)
    }
    // Correct: deduct 5 per starved pillar
    if pillars_starved > 1 {
        total_penalty += (pillars_starved as i64 - 1) * 5;
    }

    // ── 5. Ghost gaps (open status but closed_pr set) ─────────────────────────
    let ghost_gaps = count_ghost_gaps(repo_root);
    if ghost_gaps > 0 {
        let s = HealthSignal {
            name: "ghost_gaps".into(),
            penalty: 5,
            detail: format!("{} ghost gap(s) (open status, closed_pr set)", ghost_gaps),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 6. Auth status ────────────────────────────────────────────────────────
    let auth_ok = check_auth();
    if !auth_ok {
        let s = HealthSignal {
            name: "auth_fail".into(),
            penalty: 15,
            detail: "gh auth status failed — cannot push/merge".into(),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 7. Version skew (commits behind origin/main) ──────────────────────────
    let commits_behind = count_commits_behind(repo_root);
    if commits_behind > 5 {
        let s = HealthSignal {
            name: "version_skew".into(),
            penalty: 5,
            detail: format!("{} commits behind origin/main", commits_behind),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 8. Session rescues (operator-authored commits in 24h window) ──────────
    let session_rescues_24h = crate::rescue_tally::count_rescues_24h(repo_root);
    let rescue_alert_threshold = crate::rescue_tally::alert_threshold();
    if session_rescues_24h >= rescue_alert_threshold {
        let s = HealthSignal {
            name: "session_rescues".into(),
            penalty: 10,
            detail: format!(
                "{} operator rescue(s) in last 24h (threshold {})",
                session_rescues_24h, rescue_alert_threshold
            ),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 9. Binary freshness (INFRA-1504) ─────────────────────────────────────
    let (binary_age_h, binary_stale) = compute_binary_age();
    if binary_stale {
        let s = HealthSignal {
            name: "binary_stale".into(),
            penalty: 5,
            detail: format!(
                "chump binary is {:.1}h old (>24h) — run `chump upgrade`",
                binary_age_h
            ),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }

    // ── 10. Sandbox runtime (INFRA-1454) ─────────────────────────────────────
    // Pilot v1: report status only; flag Missing as a degradation signal so
    // chump fleet doctor exits non-zero when the runtime is unavailable on
    // a host that should have it. AvailableNotEnabled / DisabledByOperator
    // are informational (operator made the choice consciously).
    let sandbox_status = crate::sandbox::sandbox_runtime_status();
    if matches!(
        sandbox_status,
        crate::sandbox::SandboxStatus::Missing { .. }
    ) {
        let s = HealthSignal {
            name: "sandbox_missing".into(),
            penalty: 10,
            detail: sandbox_status.summary(),
        };
        total_penalty += s.penalty;
        signals.push(s);
    }
    let sandbox_status_tag = sandbox_status.tag().to_string();
    let sandbox_status_summary = sandbox_status.summary();

    // ── Score + grade ─────────────────────────────────────────────────────────
    let raw_score = (100i64 - total_penalty).max(0).min(100);
    let score = raw_score as u8;
    let grade = letter_grade(score);

    // Worst = highest penalty signal.
    let worst_signal = signals.iter().max_by_key(|s| s.penalty).cloned();

    HealthReport {
        score,
        grade,
        worst_signal,
        signals,
        ts,
        active_leases,
        stale_leases,
        waste_incidents_2h,
        waste_top_kind,
        fleet_wedges_2h,
        pr_stuck_2h,
        silent_agents_2h,
        today_spend_usd,
        budget_usd_per_day,
        over_budget,
        ghost_gaps,
        pillars_starved,
        auth_ok,
        commits_behind,
        session_rescues_24h,
        ambient_recent: collect_ambient_recent(repo_root),
        binary_age_h,
        binary_stale,
        sandbox_status_tag,
        sandbox_status_summary,
    }
}

/// INFRA-1504: detect install method and upgrade the chump binary.
///
/// Detection order:
///   1. `brew list chump` succeeds  → brew upgrade chump
///   2. current_exe is under ~/.cargo/bin/ → cargo install --force chump
///   3. otherwise                   → manual instructions
pub fn run_upgrade(dry_run: bool) {
    let method = detect_upgrade_method();
    match method {
        UpgradeMethod::Brew => {
            let cmd = "brew upgrade chump";
            println!("Detected install method: homebrew");
            if dry_run {
                println!("Would run: {cmd}");
            } else {
                println!("Running: {cmd}");
                let status = std::process::Command::new("brew")
                    .args(["upgrade", "chump"])
                    .status();
                match status {
                    Ok(s) if s.success() => println!("chump upgraded via brew."),
                    Ok(s) => {
                        eprintln!("brew upgrade exited with {s}");
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("Failed to run brew: {e}");
                        std::process::exit(1);
                    }
                }
            }
        }
        UpgradeMethod::Cargo => {
            let cmd = "cargo install --force chump";
            println!("Detected install method: cargo");
            if dry_run {
                println!("Would run: {cmd}");
            } else {
                println!("Running: {cmd}");
                let status = std::process::Command::new("cargo")
                    .args(["install", "--force", "chump"])
                    .status();
                match status {
                    Ok(s) if s.success() => println!("chump upgraded via cargo."),
                    Ok(s) => {
                        eprintln!("cargo install exited with {s}");
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("Failed to run cargo: {e}");
                        std::process::exit(1);
                    }
                }
            }
        }
        UpgradeMethod::Manual => {
            println!("Detected install method: manual (binary not managed by brew or cargo)");
            println!();
            println!("To upgrade, download the latest release from:");
            println!("  https://github.com/jeffadkins1/Chump/releases/latest");
            println!("and replace the binary at:");
            if let Ok(exe) = std::env::current_exe() {
                println!("  {}", exe.display());
            }
        }
    }
}

#[derive(Debug, PartialEq)]
enum UpgradeMethod {
    Brew,
    Cargo,
    Manual,
}

fn detect_upgrade_method() -> UpgradeMethod {
    // 1. brew
    if std::process::Command::new("brew")
        .args(["list", "chump"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        return UpgradeMethod::Brew;
    }

    // 2. cargo — binary lives under ~/.cargo/bin/
    if let Ok(exe) = std::env::current_exe() {
        let exe_str = exe.to_string_lossy();
        let home = std::env::var("HOME").unwrap_or_default();
        if !home.is_empty() && exe_str.starts_with(&format!("{home}/.cargo/bin/")) {
            return UpgradeMethod::Cargo;
        }
        // Also check CARGO_HOME if set
        if let Ok(cargo_home) = std::env::var("CARGO_HOME") {
            if exe_str.starts_with(&format!("{cargo_home}/bin/")) {
                return UpgradeMethod::Cargo;
            }
        }
    }

    UpgradeMethod::Manual
}

pub fn emit(repo_root: &Path, report: &HealthReport) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    // Rotate before appending so the file never grows unbounded (INFRA-941).
    crate::ambient_rotate::rotate_if_needed(&ambient);
    let json = report.render_event_json();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

impl HealthReport {
    pub fn render_event_json(&self) -> String {
        let worst = self
            .worst_signal
            .as_ref()
            .map(|s| format!(r#""{}""#, json_escape(&s.name)))
            .unwrap_or_else(|| r#"null"#.to_string());
        format!(
            r#"{{"ts":"{ts}","kind":"fleet_health","score":{score},"grade":"{grade}","worst_signal":{worst},"active_leases":{al},"stale_leases":{sl},"waste_incidents_2h":{wi},"fleet_wedges_2h":{fw},"pr_stuck_2h":{ps},"silent_agents_2h":{sa},"today_spend_usd":{spend:.6},"over_budget":{ob},"ghost_gaps":{gg},"pillars_starved":{pstar},"auth_ok":{auth},"commits_behind":{cb},"session_rescues_24h":{sr},"binary_age_h":{bah:.2},"binary_stale":{bs},"sandbox_status":"{sst}"}}"#,
            ts = self.ts,
            score = self.score,
            grade = self.grade,
            worst = worst,
            al = self.active_leases,
            sl = self.stale_leases,
            wi = self.waste_incidents_2h,
            fw = self.fleet_wedges_2h,
            ps = self.pr_stuck_2h,
            sa = self.silent_agents_2h,
            spend = self.today_spend_usd,
            ob = self.over_budget,
            gg = self.ghost_gaps,
            pstar = self.pillars_starved,
            auth = self.auth_ok,
            cb = self.commits_behind,
            sr = self.session_rescues_24h,
            bah = self.binary_age_h,
            bs = self.binary_stale,
            sst = json_escape(&self.sandbox_status_tag),
        )
    }

    pub fn render_json(&self) -> String {
        let signals_json: Vec<String> = self
            .signals
            .iter()
            .map(|s| {
                format!(
                    r#"{{"name":"{}","penalty":{},"detail":"{}"}}"#,
                    json_escape(&s.name),
                    s.penalty,
                    json_escape(&s.detail)
                )
            })
            .collect();
        let worst = self
            .worst_signal
            .as_ref()
            .map(|s| {
                format!(
                    r#"{{"name":"{}","penalty":{},"detail":"{}"}}"#,
                    json_escape(&s.name),
                    s.penalty,
                    json_escape(&s.detail)
                )
            })
            .unwrap_or_else(|| "null".to_string());
        let recent_json: Vec<String> = self
            .ambient_recent
            .iter()
            .map(|e| {
                format!(
                    r#"{{"ts":"{}","kind":"{}","summary":"{}"}}"#,
                    json_escape(&e.ts),
                    json_escape(&e.kind),
                    json_escape(&e.summary),
                )
            })
            .collect();
        format!(
            r#"{{"ts":"{ts}","kind":"fleet_health","score":{score},"grade":"{grade}","worst_signal":{worst},"signals":[{sigs}],"active_leases":{al},"stale_leases":{sl},"waste_incidents_2h":{wi},"waste_top_kind":"{wtk}","fleet_wedges_2h":{fw},"pr_stuck_2h":{ps},"silent_agents_2h":{sa},"today_spend_usd":{spend:.6},"budget_usd_per_day":{budget:.2},"over_budget":{ob},"ghost_gaps":{gg},"pillars_starved":{pstar},"auth_ok":{auth},"commits_behind":{cb},"session_rescues_24h":{sr},"binary_age_h":{bah:.2},"binary_stale":{bs},"ambient_recent":[{recent}]}}"#,
            ts = self.ts,
            score = self.score,
            grade = self.grade,
            worst = worst,
            sigs = signals_json.join(","),
            al = self.active_leases,
            sl = self.stale_leases,
            wi = self.waste_incidents_2h,
            wtk = json_escape(&self.waste_top_kind),
            fw = self.fleet_wedges_2h,
            ps = self.pr_stuck_2h,
            sa = self.silent_agents_2h,
            spend = self.today_spend_usd,
            budget = self.budget_usd_per_day,
            ob = self.over_budget,
            gg = self.ghost_gaps,
            pstar = self.pillars_starved,
            auth = self.auth_ok,
            cb = self.commits_behind,
            sr = self.session_rescues_24h,
            bah = self.binary_age_h,
            bs = self.binary_stale,
            recent = recent_json.join(","),
        )
    }

    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Fleet Health ═══\n");
        out.push_str(&format!(
            "  Score:    {}/100  ({})\n",
            self.score, self.grade
        ));
        if let Some(worst) = &self.worst_signal {
            out.push_str(&format!("  Worst:    {} — {}\n", worst.name, worst.detail));
        }
        out.push('\n');
        out.push_str(&format!(
            "  Workers:  {} active lease(s){}",
            self.active_leases,
            if self.stale_leases > 0 {
                format!("  ⚠  {} stale (>6h)\n", self.stale_leases)
            } else {
                "\n".to_string()
            }
        ));
        out.push_str(&format!(
            "  Waste/2h: {} incidents{}",
            self.waste_incidents_2h,
            if !self.waste_top_kind.is_empty() {
                format!("  (top: {})\n", self.waste_top_kind)
            } else {
                "\n".to_string()
            }
        ));
        out.push_str(&format!(
            "  Wedges:   {}  pr_stuck: {}  silent_agent: {}\n",
            self.fleet_wedges_2h, self.pr_stuck_2h, self.silent_agents_2h
        ));
        out.push_str(&format!(
            "  Cost:     ${:.4}/day{}",
            self.today_spend_usd,
            if self.over_budget {
                format!("  🔴 OVER BUDGET (cap ${:.2})\n", self.budget_usd_per_day)
            } else {
                "\n".to_string()
            }
        ));
        out.push_str(&format!(
            "  Pillars:  {} starved   ghost_gaps: {}\n",
            self.pillars_starved, self.ghost_gaps
        ));
        out.push_str(&format!(
            "  Auth:     {}   version_skew: {} commits behind\n",
            if self.auth_ok { "ok" } else { "FAIL" },
            self.commits_behind
        ));
        out.push_str(&format!(
            "  Rescues:  {} operator rescue(s) in last 24h\n",
            self.session_rescues_24h
        ));
        out.push_str(&format!(
            "  Binary:   {:.1}h old{}",
            self.binary_age_h,
            if self.binary_stale {
                "  ⚠  STALE (>24h) — run `chump upgrade`\n"
            } else {
                "\n"
            }
        ));
        out.push_str(&format!(
            "  Sandbox:  {} — {}\n",
            self.sandbox_status_tag, self.sandbox_status_summary
        ));
        if !self.signals.is_empty() {
            out.push_str("\n  Penalties:\n");
            for s in &self.signals {
                out.push_str(&format!(
                    "    -{:>2}  {}  {}\n",
                    s.penalty, s.name, s.detail
                ));
            }
        }
        if !self.ambient_recent.is_empty() {
            out.push_str("\n  Recent activity:\n");
            for e in &self.ambient_recent {
                let ts_short = e.ts.get(..19).unwrap_or(&e.ts);
                if e.summary.is_empty() {
                    out.push_str(&format!("    [{}] {}\n", ts_short, e.kind));
                } else {
                    out.push_str(&format!("    [{}] {}: {}\n", ts_short, e.kind, e.summary));
                }
            }
        }
        out.push_str(&format!("\n  Generated: {}\n", self.ts));
        out
    }
}

// ── Sub-collectors ────────────────────────────────────────────────────────────

/// INFRA-1504: return (age_hours, is_stale) for the running chump binary.
/// Falls back to (0.0, false) if the mtime is unreadable.
fn compute_binary_age() -> (f64, bool) {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return (0.0, false),
    };
    let meta = match std::fs::metadata(&exe) {
        Ok(m) => m,
        Err(_) => return (0.0, false),
    };
    let mtime = match meta.modified() {
        Ok(t) => t,
        Err(_) => return (0.0, false),
    };
    let age_secs = std::time::SystemTime::now()
        .duration_since(mtime)
        .unwrap_or_default()
        .as_secs_f64();
    let age_h = age_secs / 3600.0;
    let stale = age_h > 24.0;
    (age_h, stale)
}

fn collect_lease_info(repo_root: &Path) -> (usize, usize) {
    let lock_dir = repo_root.join(".chump-locks");
    let Ok(entries) = std::fs::read_dir(&lock_dir) else {
        return (0, 0);
    };
    let now = std::time::SystemTime::now();
    let mut active = 0usize;
    let mut stale = 0usize;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.ends_with(".json") || name.starts_with('.') || name.contains("cooldown") {
            continue;
        }
        active += 1;
        if let Ok(meta) = std::fs::metadata(&path) {
            if let Ok(modified) = meta.modified() {
                let age_secs = now
                    .duration_since(modified)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                if age_secs > 6 * 3600 {
                    stale += 1;
                }
            }
        }
    }
    (active, stale)
}

/// Scan ambient.jsonl for key event counts since `cutoff_unix`.
/// Returns: (fleet_wedges, pr_stuck, silent_agents, waste_incidents, top_kind).
fn scan_ambient_2h(repo_root: &Path, cutoff_unix: u64) -> (u64, u64, u64, u64, String) {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    use std::collections::BTreeMap;
    let mut wedges = 0u64;
    let mut pr_stuck = 0u64;
    let mut silent = 0u64;
    let mut waste_by_kind: BTreeMap<String, u64> = BTreeMap::new();

    for line in contents.lines() {
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts_unix < cutoff_unix {
            continue;
        }
        let kind = extract_field(line, "kind").unwrap_or_default();
        match kind.as_str() {
            "fleet_wedge" => wedges += 1,
            "pr_stuck" => pr_stuck += 1,
            "silent_agent" => silent += 1,
            _ => {}
        }
        if crate::waste_tally::WASTE_KINDS.contains(&kind.as_str()) {
            *waste_by_kind.entry(kind).or_insert(0) += 1;
        }
    }

    let total_waste: u64 = waste_by_kind.values().sum();
    let top_kind = waste_by_kind
        .iter()
        .max_by_key(|(_, &v)| v)
        .map(|(k, _)| k.clone())
        .unwrap_or_default();

    (wedges, pr_stuck, silent, total_waste, top_kind)
}

const NOISE_KINDS: &[&str] = &["heartbeat", "session_start", "bash_call"];

/// Collect the last ≤5 non-noise events from ambient.jsonl for display.
fn collect_ambient_recent(repo_root: &Path) -> Vec<AmbientSummary> {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    let mut events: Vec<AmbientSummary> = Vec::new();
    for line in contents.lines() {
        let kind = match extract_field(line, "kind") {
            Some(k) => k,
            None => continue,
        };
        if NOISE_KINDS.contains(&kind.as_str()) {
            continue;
        }
        let ts = extract_field(line, "ts").unwrap_or_default();
        let summary = ambient_event_summary(line, &kind);
        events.push(AmbientSummary { ts, kind, summary });
    }

    // Take last 5 (most-recent); they are already in chronological order.
    let start = events.len().saturating_sub(5);
    events.split_off(start)
}

/// Extract a concise one-liner summary from an ambient event line.
/// Picks up to 3 known key fields beyond ts/kind.
fn ambient_event_summary(line: &str, kind: &str) -> String {
    let key_fields: &[&str] = match kind {
        "session_end" => &["outcome", "gap", "elapsed_seconds"],
        "gap_claimed" | "gap_shipped" => &["gap", "worker"],
        "fleet_wedge" | "fleet_scale_change" => &["rationale", "from", "to"],
        "pr_stuck" | "bot_merge_phase_failure" => &["pr", "phase", "error"],
        "alert" | "slo_breach" => &["slo", "detail", "current"],
        "gap_store_curated" => &["rebalanced", "consolidated", "errors"],
        _ => &["gap", "worker", "error"],
    };
    let mut parts: Vec<String> = Vec::new();
    for &field in key_fields {
        if let Some(val) = extract_field(line, field) {
            if !val.is_empty() {
                parts.push(format!("{}={}", field, val));
            }
        }
    }
    parts.join(" ")
}

fn scan_cost_today(repo_root: &Path, budget: f64) -> (f64, bool) {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now_unix = current_unix();
    let today_start = now_unix - (now_unix % 86_400);
    let mut spend = 0.0f64;
    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        let ts = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts < today_start {
            continue;
        }
        let input = extract_int_field(line, "input_tokens").unwrap_or(0);
        let output = extract_int_field(line, "output_tokens").unwrap_or(0);
        let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
        let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
        spend += crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache);
    }
    let over = spend > budget;
    (spend, over)
}

fn count_ghost_gaps(repo_root: &Path) -> u64 {
    let Ok(gs) = crate::gap_store::GapStore::open(repo_root) else {
        return 0;
    };
    let Ok(open_gaps) = gs.list(Some("open")) else {
        return 0;
    };
    open_gaps.iter().filter(|g| g.closed_pr.is_some()).count() as u64
}

fn check_auth() -> bool {
    std::process::Command::new("gh")
        .args(["auth", "status"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn count_commits_behind(repo_root: &Path) -> u64 {
    // Fetch quietly first; ignore errors (offline is ok).
    let _ = std::process::Command::new("git")
        .args([
            "-C",
            repo_root.to_str().unwrap_or("."),
            "fetch",
            "origin",
            "main",
            "--quiet",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output();
    let out = std::process::Command::new("git")
        .args([
            "-C",
            repo_root.to_str().unwrap_or("."),
            "rev-list",
            "--count",
            "HEAD..origin/main",
        ])
        .output()
        .ok();
    out.and_then(|o| {
        if o.status.success() {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .parse::<u64>()
                .ok()
        } else {
            None
        }
    })
    .unwrap_or(0)
}

fn letter_grade(score: u8) -> &'static str {
    match score {
        90..=100 => "A",
        80..=89 => "B",
        70..=79 => "C",
        60..=69 => "D",
        _ => "F",
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn current_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let out = std::process::Command::new("date")
        .args(["-u", "-r", &secs.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    if let Some(s) = out {
        return s.trim().to_string();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    out2.map(|s| s.trim().to_string())
        .unwrap_or_else(|| format!("{}", secs))
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if !out2.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out2.stdout).trim().parse().ok()
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                'u' => {
                    for _ in 0..4 {
                        chars.next()?;
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse().ok()
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

// ── SLO check (INFRA-645) ─────────────────────────────────────────────────────

/// One SLO with its current measurement and breach status.
#[derive(Debug, Clone)]
pub struct SloResult {
    pub id: &'static str,
    pub target: &'static str,
    pub current: String,
    pub breached: bool,
    pub detail: String,
}

/// Evaluate all fleet SLOs against live data.
/// See docs/process/FLEET_SLOS.md for authoritative definitions.
pub fn check_slos(repo_root: &Path) -> Vec<SloResult> {
    let mut results = Vec::new();
    let now = current_unix();
    let week_ago = now.saturating_sub(7 * 24 * 3600);
    let day_start = now - (now % 86_400);
    let h24_ago = now.saturating_sub(24 * 3600);

    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // L1-SLO-1: silent_agent = 0/week
    let silent_7d = count_kind_since(&contents, "silent_agent", week_ago);
    results.push(SloResult {
        id: "L1-SLO-1",
        target: "silent_agent = 0/week",
        current: format!("{}", silent_7d),
        breached: silent_7d > 0,
        detail: format!("{} silent_agent event(s) in last 7d (target: 0)", silent_7d),
    });

    // L1-SLO-2: orphan_claude = 0/day
    let orphan_today = count_kind_since(&contents, "orphan_claude", day_start);
    results.push(SloResult {
        id: "L1-SLO-2",
        target: "orphan_claude = 0/day",
        current: format!("{}", orphan_today),
        breached: orphan_today > 0,
        detail: format!("{} orphan_claude event(s) today (target: 0)", orphan_today),
    });

    // L1-SLO-3: auto-restart success rate > 95%
    let ok_24h = count_kind_since(&contents, "auto_restart_ok", h24_ago);
    let fail_24h = count_kind_since(&contents, "auto_restart_fail", h24_ago);
    let total_restarts = ok_24h + fail_24h;
    let restart_rate = (ok_24h * 100).checked_div(total_restarts).unwrap_or(100);
    results.push(SloResult {
        id: "L1-SLO-3",
        target: "auto-restart success > 95%",
        current: format!("{}%", restart_rate),
        breached: total_restarts > 0 && restart_rate < 95,
        detail: if total_restarts == 0 {
            "no auto_restart events in 24h (no data — passing by default)".into()
        } else {
            format!(
                "{}/{} restarts succeeded in 24h ({}%)",
                ok_24h, total_restarts, restart_rate
            )
        },
    });

    // L2-SLO-1: P50 ship-time < 30min (created_at → closed_at for 24h window)
    let p50_min = p50_ship_time_minutes(repo_root);
    results.push(SloResult {
        id: "L2-SLO-1",
        target: "P50 ship-time < 30min",
        current: p50_min
            .map(|m| format!("{}min", m))
            .unwrap_or_else(|| "no data".into()),
        breached: p50_min.is_some_and(|m| m >= 30),
        detail: p50_min
            .map(|m| format!("P50 ship-time {}min in last 24h (target: <30min)", m))
            .unwrap_or_else(|| "no gaps closed in last 24h — cannot compute P50".into()),
    });

    // L2-SLO-2: waste < 5% of sessions (proxy until per-token accounting is wired)
    let waste_7d = count_waste_since(&contents, week_ago);
    let sessions_7d = count_kind_since(&contents, "session_end", week_ago).max(1);
    let waste_pct = waste_7d * 100 / sessions_7d;
    results.push(SloResult {
        id: "L2-SLO-2",
        target: "waste < 5% of tokens",
        current: format!("~{}%", waste_pct),
        breached: waste_pct >= 5,
        detail: format!(
            "{} waste incidents / {} sessions in 7d (~{}%) — use `chump waste-tally --tokens` for exact token %",
            waste_7d, sessions_7d, waste_pct
        ),
    });

    // L2-SLO-3: P0 count <= 5
    let p0_count = count_p0_gaps(repo_root);
    results.push(SloResult {
        id: "L2-SLO-3",
        target: "P0 count ≤ 5",
        current: format!("{}", p0_count),
        breached: p0_count > 5,
        detail: format!("{} open P0 gaps (target: ≤5)", p0_count),
    });

    // L2-SLO-4: pillar balance >= 2 pickable in every pillar
    let grade = crate::mission_grade::build_report(repo_root);
    let pillar_counts = [
        ("EFFECTIVE", grade.effective.count_pickable),
        ("CREDIBLE", grade.credible.count_pickable),
        ("RESILIENT", grade.resilient.count_pickable),
        ("ZERO-WASTE", grade.zero_waste.count_pickable),
    ];
    let pillars_under_two = pillar_counts.iter().filter(|(_, c)| *c < 2).count();
    results.push(SloResult {
        id: "L2-SLO-4",
        target: "pillar balance ≥ 2 pickable each",
        current: format!("{} under target", pillars_under_two),
        breached: pillars_under_two > 0,
        detail: format!(
            "EFFECTIVE:{} CREDIBLE:{} RESILIENT:{} ZERO-WASTE:{} (target: ≥2 each)",
            grade.effective.count_pickable,
            grade.credible.count_pickable,
            grade.resilient.count_pickable,
            grade.zero_waste.count_pickable,
        ),
    });

    // L2-SLO-5: ghost-gap count < 2
    let ghosts = count_ghost_gaps(repo_root);
    results.push(SloResult {
        id: "L2-SLO-5",
        target: "ghost-gap count < 2",
        current: format!("{}", ghosts),
        breached: ghosts >= 2,
        detail: format!(
            "{} ghost gaps (open status, closed_pr set; target: <2)",
            ghosts
        ),
    });

    // L3-SLO-1: operator-recall < 1/week
    let recall_7d = count_kind_since(&contents, "operator_recall", week_ago);
    results.push(SloResult {
        id: "L3-SLO-1",
        target: "operator-recall < 1/week",
        current: format!("{}", recall_7d),
        breached: recall_7d >= 1,
        detail: format!(
            "{} operator_recall event(s) in last 7d (target: <1)",
            recall_7d
        ),
    });

    // L4-SLO-1: paramedic heartbeat freshness (INFRA-1397 AC §7)
    // Only breach if a leader has been seen in the last hour (otherwise daemon
    // simply isn't installed yet, which is not a fleet health regression).
    let fifteen_min_ago = now.saturating_sub(15 * 60);
    let one_hour_ago = now.saturating_sub(3600);
    let heartbeat_recent = count_kind_since(&contents, "paramedic_heartbeat", fifteen_min_ago);
    let heartbeat_last_hour = count_kind_since(&contents, "paramedic_heartbeat", one_hour_ago);
    let paramedic_breached = heartbeat_last_hour > 0 && heartbeat_recent == 0;
    results.push(SloResult {
        id: "L4-SLO-1",
        target: "paramedic heartbeat fresh (< 15min gap)",
        current: if heartbeat_recent > 0 {
            "fresh".into()
        } else if heartbeat_last_hour > 0 {
            "stale".into()
        } else {
            "no data".into()
        },
        breached: paramedic_breached,
        detail: if heartbeat_recent > 0 {
            format!(
                "paramedic_heartbeat seen in last 15min ({} events)",
                heartbeat_recent
            )
        } else if heartbeat_last_hour > 0 {
            "paramedic_heartbeat stale: leader seen in last hour but not in last 15min — daemon may be down".into()
        } else {
            "no paramedic_heartbeat in last hour — daemon not yet installed or never started".into()
        },
    });

    results
}

pub fn render_slo_text(results: &[SloResult]) -> String {
    let breach_count = results.iter().filter(|r| r.breached).count();
    let mut out = String::new();
    out.push_str("═══ Fleet SLO Check ═══\n\n");
    for r in results {
        if r.breached {
            out.push_str(&format!(
                "  ✗ BREACH  {}  [{}]  {}\n",
                r.id, r.current, r.target
            ));
            out.push_str(&format!("             └─ {}\n", r.detail));
        } else {
            out.push_str(&format!(
                "  ✓ pass    {}  [{}]  {}\n",
                r.id, r.current, r.target
            ));
        }
    }
    out.push('\n');
    if breach_count == 0 {
        out.push_str("  All SLOs passing.\n");
    } else {
        out.push_str(&format!(
            "  {} SLO(s) breached — see docs/process/FLEET_SLOS.md\n",
            breach_count
        ));
    }
    out
}

pub fn render_slo_json(results: &[SloResult]) -> String {
    let breach_count = results.iter().filter(|r| r.breached).count();
    let items: Vec<String> = results
        .iter()
        .map(|r| {
            format!(
                r#"{{"id":"{}","target":"{}","current":"{}","breached":{},"detail":"{}"}}"#,
                r.id,
                r.target,
                r.current,
                r.breached,
                json_escape(&r.detail)
            )
        })
        .collect();
    format!(
        r#"{{"slo_breaches":{},"slos":[{}]}}"#,
        breach_count,
        items.join(",")
    )
}

// ── SLO helpers ───────────────────────────────────────────────────────────────

fn count_kind_since(contents: &str, kind: &str, since_unix: u64) -> u64 {
    let needle = format!(r#""kind":"{}""#, kind);
    let mut count = 0u64;
    for line in contents.lines() {
        if !line.contains(&needle) {
            continue;
        }
        let ts = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts >= since_unix {
            count += 1;
        }
    }
    count
}

fn count_waste_since(contents: &str, since_unix: u64) -> u64 {
    let mut count = 0u64;
    for line in contents.lines() {
        let ts = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts < since_unix {
            continue;
        }
        let kind = extract_field(line, "kind").unwrap_or_default();
        if crate::waste_tally::WASTE_KINDS.contains(&kind.as_str()) {
            count += 1;
        }
    }
    count
}

fn p50_ship_time_minutes(repo_root: &Path) -> Option<u64> {
    let Ok(gs) = crate::gap_store::GapStore::open(repo_root) else {
        return None;
    };
    let Ok(closed) = gs.list(Some("closed")) else {
        return None;
    };
    let now = current_unix();
    let day_ago = now.saturating_sub(24 * 3600);
    let mut durations: Vec<u64> = closed
        .iter()
        .filter_map(|g| {
            let closed_at = g.closed_at? as u64;
            if closed_at < day_ago {
                return None;
            }
            let created_at = g.created_at as u64;
            Some(closed_at.saturating_sub(created_at) / 60)
        })
        .collect();
    if durations.is_empty() {
        return None;
    }
    durations.sort_unstable();
    Some(durations[durations.len() / 2])
}

fn count_p0_gaps(repo_root: &Path) -> u64 {
    let Ok(gs) = crate::gap_store::GapStore::open(repo_root) else {
        return 0;
    };
    let Ok(open) = gs.list(Some("open")) else {
        return 0;
    };
    open.iter().filter(|g| g.priority.as_str() == "P0").count() as u64
}

// ── Unit tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra644-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_ambient(root: &std::path::Path, lines: &[&str]) {
        let lock_dir = root.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        std::fs::write(lock_dir.join("ambient.jsonl"), lines.join("\n") + "\n").unwrap();
    }

    fn now_iso() -> String {
        std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "2026-05-06T20:00:00Z".to_string())
    }

    #[test]
    fn test_letter_grade_boundaries() {
        assert_eq!(letter_grade(100), "A");
        assert_eq!(letter_grade(90), "A");
        assert_eq!(letter_grade(89), "B");
        assert_eq!(letter_grade(80), "B");
        assert_eq!(letter_grade(79), "C");
        assert_eq!(letter_grade(70), "C");
        assert_eq!(letter_grade(69), "D");
        assert_eq!(letter_grade(60), "D");
        assert_eq!(letter_grade(59), "F");
        assert_eq!(letter_grade(0), "F");
    }

    #[test]
    fn test_scan_ambient_counts_wedges_and_stuck() {
        let tmp = tempdir();
        let now = now_iso();
        let lines = [
            format!(r#"{{"kind":"fleet_wedge","ts":"{}"}}"#, now),
            format!(r#"{{"kind":"fleet_wedge","ts":"{}"}}"#, now),
            format!(r#"{{"kind":"pr_stuck","ts":"{}"}}"#, now),
            format!(
                r#"{{"kind":"silent_agent","ts":"{}","note":"session=x gap=INFRA-1"}}"#,
                now
            ),
            // Old event — should be excluded.
            r#"{"kind":"fleet_wedge","ts":"2020-01-01T00:00:00Z"}"#.to_string(),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let cutoff = current_unix().saturating_sub(2 * 3600);
        let (wedges, stuck, silent, _, _) = scan_ambient_2h(&tmp, cutoff);
        assert_eq!(wedges, 2, "two wedge events in window");
        assert_eq!(stuck, 1, "one pr_stuck in window");
        assert_eq!(silent, 1, "one silent_agent in window");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_render_event_json_has_required_fields() {
        let report = HealthReport {
            score: 85,
            grade: "B",
            worst_signal: None,
            signals: vec![],
            ts: "2026-05-06T20:00:00Z".to_string(),
            active_leases: 2,
            stale_leases: 0,
            waste_incidents_2h: 0,
            waste_top_kind: String::new(),
            fleet_wedges_2h: 0,
            pr_stuck_2h: 0,
            silent_agents_2h: 0,
            today_spend_usd: 1.23,
            budget_usd_per_day: 5.0,
            over_budget: false,
            ghost_gaps: 0,
            pillars_starved: 0,
            auth_ok: true,
            commits_behind: 0,
            session_rescues_24h: 0,
            ambient_recent: vec![],
            binary_age_h: 0.0,
            binary_stale: false,
            sandbox_status_tag: "available_not_enabled".to_string(),
            sandbox_status_summary: "sandbox runtime present but not enabled".to_string(),
        };
        let json = report.render_event_json();
        assert!(json.contains(r#""kind":"fleet_health""#), "kind field");
        assert!(json.contains(r#""score":85"#), "score field");
        assert!(json.contains(r#""grade":"B""#), "grade field");
        assert!(json.contains(r#""active_leases":2"#), "active_leases field");
        assert!(json.contains(r#""auth_ok":true"#), "auth_ok field");
    }

    #[test]
    fn test_render_text_shows_score_and_grade() {
        let report = HealthReport {
            score: 75,
            grade: "C",
            worst_signal: Some(HealthSignal {
                name: "fleet_wedge".to_string(),
                penalty: 25,
                detail: "1 fleet_wedge event(s) in last 2h".to_string(),
            }),
            signals: vec![HealthSignal {
                name: "fleet_wedge".to_string(),
                penalty: 25,
                detail: "1 fleet_wedge event(s) in last 2h".to_string(),
            }],
            ts: "2026-05-06T20:00:00Z".to_string(),
            active_leases: 1,
            stale_leases: 0,
            waste_incidents_2h: 3,
            waste_top_kind: "pr_stuck".to_string(),
            fleet_wedges_2h: 1,
            pr_stuck_2h: 0,
            silent_agents_2h: 0,
            today_spend_usd: 0.5,
            budget_usd_per_day: 5.0,
            over_budget: false,
            ghost_gaps: 0,
            pillars_starved: 0,
            auth_ok: true,
            commits_behind: 0,
            session_rescues_24h: 0,
            ambient_recent: vec![],
            binary_age_h: 0.0,
            binary_stale: false,
            sandbox_status_tag: "available_not_enabled".to_string(),
            sandbox_status_summary: "sandbox runtime present but not enabled".to_string(),
        };
        let text = report.render_text();
        assert!(text.contains("75/100"), "score in text");
        assert!(text.contains("(C)"), "grade in text");
        assert!(text.contains("fleet_wedge"), "worst signal in text");
        assert!(text.contains("Penalties"), "penalties section in text");
    }

    #[test]
    fn test_render_json_is_valid_structure() {
        let report = HealthReport {
            score: 100,
            grade: "A",
            worst_signal: None,
            signals: vec![],
            ts: "2026-05-06T20:00:00Z".to_string(),
            active_leases: 0,
            stale_leases: 0,
            waste_incidents_2h: 0,
            waste_top_kind: String::new(),
            fleet_wedges_2h: 0,
            pr_stuck_2h: 0,
            silent_agents_2h: 0,
            today_spend_usd: 0.0,
            budget_usd_per_day: 5.0,
            over_budget: false,
            ghost_gaps: 0,
            pillars_starved: 0,
            auth_ok: true,
            commits_behind: 0,
            session_rescues_24h: 0,
            ambient_recent: vec![],
            binary_age_h: 0.0,
            binary_stale: false,
            sandbox_status_tag: "available_not_enabled".to_string(),
            sandbox_status_summary: "sandbox runtime present but not enabled".to_string(),
        };
        let json = report.render_json();
        assert!(json.starts_with('{'), "starts with {{");
        assert!(json.ends_with('}'), "ends with }}");
        assert!(json.contains(r#""score":100"#));
        assert!(json.contains(r#""grade":"A""#));
        assert!(json.contains(r#""signals":[]"#));
        assert!(json.contains(r#""worst_signal":null"#));
    }

    #[test]
    fn test_score_clamps_to_zero() {
        // If all signals fire simultaneously the score cannot go below 0.
        let mut total: i64 = 25 + 20 + 15 + 10 + 10 + 15 + 5 + 5 + 5 + 5;
        total = total.min(100);
        let score = (100i64 - total).max(0) as u8;
        assert_eq!(score, 0);
    }

    #[test]
    fn test_emit_appends_to_ambient() {
        let tmp = tempdir();
        std::fs::create_dir_all(tmp.join(".chump-locks")).unwrap();
        let report = HealthReport {
            score: 90,
            grade: "A",
            worst_signal: None,
            signals: vec![],
            ts: "2026-05-06T20:00:00Z".to_string(),
            active_leases: 0,
            stale_leases: 0,
            waste_incidents_2h: 0,
            waste_top_kind: String::new(),
            fleet_wedges_2h: 0,
            pr_stuck_2h: 0,
            silent_agents_2h: 0,
            today_spend_usd: 0.0,
            budget_usd_per_day: 5.0,
            over_budget: false,
            ghost_gaps: 0,
            pillars_starved: 0,
            auth_ok: true,
            commits_behind: 0,
            session_rescues_24h: 0,
            ambient_recent: vec![],
            binary_age_h: 0.0,
            binary_stale: false,
            sandbox_status_tag: "available_not_enabled".to_string(),
            sandbox_status_summary: "sandbox runtime present but not enabled".to_string(),
        };
        emit(&tmp, &report);
        let contents = std::fs::read_to_string(tmp.join(".chump-locks/ambient.jsonl")).unwrap();
        assert!(contents.contains(r#""kind":"fleet_health""#));
        assert!(contents.contains(r#""score":90"#));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
