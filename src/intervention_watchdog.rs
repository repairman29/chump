//! Operator-intervention watchdog — COTG-2.1 / INFRA-3489.
//!
//! Meta-principle: in an autonomous fleet, **every human touch is a defect in autonomy**. This
//! module is the INVERSE of [`crate::operator_presence`] (which detects operator *absence*): it
//! detects operator *presence* — the moments a human, or a human-authorized bypass, had to step
//! into a run — records each as a typed `autonomy_defect` event with enough context to reproduce
//! what happened (AC1), triages it into a class (AC2), and for known-healable classes files a
//! deduped self-healing gap tagged to COTG (AC2). The intervention count is queryable as a
//! metric via `--json` (AC3).
//!
//! Detection sources (reuse, do NOT reinvent):
//!   - the ambient stream's existing intervention vocabulary — bypasses, forced unlocks, admin
//!     merges (see `docs/observability/EVENT_REGISTRY.yaml`);
//!   - [`crate::rescue_tally::scan_rescues`] — human-authored rescue commits on main.
//!
//! It deliberately EXCLUDES the OS's *automatic* self-heals (reaper / dedupe / cache-skip
//! events): those are autonomy *working*, not a human stepping in. Mistaking the OS healing
//! itself for a human touch would drown the real signal.

use anyhow::Result;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The triage bucket an intervention falls into (COTG-2.1 AC2). Every class here is
/// known-healable today, so each maps to a self-heal shape via [`DefectClass::heal_hint`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DefectClass {
    /// A deterministic gate (fmt/clippy/test/off-rails/preflight/verify) had to be bypassed.
    DeterministicGateFailure,
    /// Claim/lease/bot-merge/consensus contention forced a human or a forced-unlock in.
    Coordination,
    /// The ship/merge ceremony needed a manual step (admin merge, hand-authored rescue).
    CeremonyGap,
}

impl DefectClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            DefectClass::DeterministicGateFailure => "deterministic-gate-failure",
            DefectClass::Coordination => "coordination",
            DefectClass::CeremonyGap => "ceremony-gap",
        }
    }

    /// The self-heal shape the filed gap proposes — the remedy hint for this class.
    pub fn heal_hint(&self) -> &'static str {
        match self {
            DefectClass::DeterministicGateFailure => {
                "make the gate auto-fix its own deterministic failure so no bypass is needed"
            }
            DefectClass::Coordination => {
                "resolve the claim/lease/bot-merge contention so no forced unlock is needed"
            }
            DefectClass::CeremonyGap => {
                "make the ship/merge ceremony deterministic so no manual step is needed"
            }
        }
    }
}

/// Map a raw ambient event `kind` to its defect class, or `None` if the kind is **not** a human
/// intervention. Routine automatic self-heals (reaper/dedupe/cache-skip) return `None` on
/// purpose — the OS healing itself is not a defect in autonomy.
pub fn classify_intervention(kind: &str) -> Option<DefectClass> {
    use DefectClass::*;
    Some(match kind {
        // A human chose to bypass a DETERMINISTIC gate.
        "off_rails_bypassed"
        | "verify_bypassed"
        | "preflight_bypassed"
        | "test_gate_bypassed"
        | "token_discipline_bypass_used"
        | "rust_first_bypass_used"
        | "redundancy_bypass_used" => DeterministicGateFailure,
        // COORDINATION contention forced a human / bypass / forced-unlock in.
        "bot_merge_bypassed"
        | "consensus_bypass_used"
        | "chump_claim_force_recover"
        | "force_recover_wip_loss"
        | "force_recover_wip_discarded" => Coordination,
        // The ship/merge CEREMONY needed a manual hand. (Human rescue COMMITS come from
        // rescue_tally in `scan`, not from here, so `session_rescue` is intentionally absent
        // to avoid double-counting the same rescue.)
        "admin_merge_forced"
        | "auto_merge_policy_bypassed"
        | "admin_bypass_used"
        | "manual_rescue" => CeremonyGap,
        _ => return None,
    })
}

/// One detected human intervention, with enough context to reproduce what happened (AC1).
#[derive(Debug, Clone)]
pub struct Intervention {
    pub ts: String,
    pub kind: String,
    pub class: DefectClass,
    /// Compact reproduction context pulled from the event's own descriptive fields.
    pub context: String,
}

/// Descriptive fields we lift into an intervention's reproduction context, if present.
const CONTEXT_FIELDS: &[&str] = &[
    "reason",
    "pr",
    "gap",
    "claimed_gap",
    "operator",
    "commit",
    "subject",
    "workaround",
    "branch",
];

/// Parse ambient JSONL `lines` into interventions. Pure over an iterator of raw lines so it is
/// hermetically testable; the binary feeds it the real ambient stream. `since` is an optional
/// inclusive lower-bound RFC3339 timestamp — lines strictly older are dropped (RFC3339 UTC
/// timestamps are fixed-width, so lexical `<` is chronological `<`). A line with no/empty `ts`
/// is always kept (we would rather over-report than silently drop an intervention).
pub fn interventions_from_lines<I: IntoIterator<Item = String>>(
    lines: I,
    since: Option<&str>,
) -> Vec<Intervention> {
    let mut out = Vec::new();
    for line in lines {
        let v: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        let class = match classify_intervention(kind) {
            Some(c) => c,
            None => continue,
        };
        let ts = v
            .get("ts")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();
        if let Some(lo) = since {
            if !ts.is_empty() && ts.as_str() < lo {
                continue;
            }
        }
        let mut ctx: Vec<String> = Vec::new();
        for f in CONTEXT_FIELDS {
            if let Some(val) = v.get(*f).and_then(|x| x.as_str()) {
                if !val.is_empty() {
                    ctx.push(format!("{f}={val}"));
                }
            }
        }
        out.push(Intervention {
            ts,
            kind: kind.to_string(),
            class,
            context: ctx.join(" "),
        });
    }
    out
}

/// A scan result: the interventions found + per-class counts (the queryable metric, AC3).
#[derive(Debug, Default)]
pub struct WatchdogReport {
    pub interventions: Vec<Intervention>,
    pub counts_by_class: BTreeMap<String, u64>,
}

impl WatchdogReport {
    pub fn total(&self) -> u64 {
        self.interventions.len() as u64
    }

    /// Build a report from a flat list of interventions: tally per-class and sort by time.
    pub fn tally(mut interventions: Vec<Intervention>) -> Self {
        let mut counts_by_class: BTreeMap<String, u64> = BTreeMap::new();
        for iv in &interventions {
            *counts_by_class
                .entry(iv.class.as_str().to_string())
                .or_default() += 1;
        }
        interventions.sort_by(|a, b| a.ts.cmp(&b.ts));
        WatchdogReport {
            interventions,
            counts_by_class,
        }
    }
}

// ── CREDIBLE-171 / COTG-3.1: the honest zero-touch streak metric ───────────────
// The readiness number. Provenance is trailer-based (COTG-3.2): a commit on the
// default branch that carries the `Chump-Agent:` trailer is the OS's; one that
// lacks it (and isn't a known automation bot) is a HUMAN touch. This replaces the
// operator-email heuristic (which conflated agent-identity commits with human ones,
// over-counting ~127-vs-1 on 2026-07-29). It is reliable only for commits made after
// the CREDIBLE-172 stamp went live — older commits under-report zero-touch.

/// One commit on the default branch, classified by provenance.
#[derive(Debug, Clone)]
pub struct ProvenanceCommit {
    pub hash: String,
    pub ts_unix: u64,
    /// carries the `Chump-Agent:` trailer — the OS made it (zero-touch).
    pub zero_touch: bool,
    /// authored by a known automation bot (dependabot / github-actions) — not human, not ours.
    pub is_bot: bool,
}

impl ProvenanceCommit {
    /// A HUMAN touch = no zero-touch trailer AND not an automation bot.
    fn is_human_touch(&self) -> bool {
        !self.zero_touch && !self.is_bot
    }
}

/// The zero-touch streak metric — the queryable readiness number (COTG-3.1 AC3).
#[derive(Debug, Clone, serde::Serialize)]
pub struct StreakMetric {
    pub branch: String,
    pub commits_scanned: u64,
    pub zero_touch_commits: u64,
    pub human_touches: u64,
    pub bot_touches: u64,
    /// longest consecutive run of commits with NO human touch (bot/OS commits don't break it).
    pub longest_zero_touch_streak: u64,
    /// consecutive commits since the most recent human touch (from the newest commit backwards).
    pub current_zero_touch_streak: u64,
    /// hours since the most recent human touch, or None if the window is fully hands-off.
    pub hours_since_last_human_touch: Option<f64>,
    pub zero_touch_ratio: f64,
}

/// Compute the streak from provenance commits. **Assumes `commits` is newest-first** (git log's
/// default order). Pure over its inputs so it is hermetically testable — `now_unix` is injected.
pub fn compute_streak(commits: &[ProvenanceCommit], branch: &str, now_unix: u64) -> StreakMetric {
    let scanned = commits.len() as u64;
    let mut zt = 0u64;
    let mut human = 0u64;
    let mut bot = 0u64;
    for c in commits {
        if c.zero_touch {
            zt += 1;
        } else if c.is_bot {
            bot += 1;
        } else {
            human += 1;
        }
    }
    // longest run with no human touch
    let mut longest = 0u64;
    let mut run = 0u64;
    for c in commits {
        if c.is_human_touch() {
            run = 0;
        } else {
            run += 1;
            if run > longest {
                longest = run;
            }
        }
    }
    // current streak: newest-first, count until the first human touch
    let mut current = 0u64;
    for c in commits {
        if c.is_human_touch() {
            break;
        }
        current += 1;
    }
    // hours since the most recent (newest) human touch
    let hours = commits
        .iter()
        .find(|c| c.is_human_touch())
        .map(|c| (now_unix.saturating_sub(c.ts_unix)) as f64 / 3600.0);
    let ratio = if scanned > 0 {
        zt as f64 / scanned as f64
    } else {
        0.0
    };
    StreakMetric {
        branch: branch.to_string(),
        commits_scanned: scanned,
        zero_touch_commits: zt,
        human_touches: human,
        bot_touches: bot,
        longest_zero_touch_streak: longest,
        current_zero_touch_streak: current,
        hours_since_last_human_touch: hours,
        zero_touch_ratio: ratio,
    }
}

/// Read the last `max_commits` on `branch` and classify each by the `Chump-Agent:` trailer.
pub fn scan_provenance(repo_root: &Path, branch: &str, max_commits: u64) -> Vec<ProvenanceCommit> {
    // \x1f field sep, \x1e record sep — so a commit body's newlines don't corrupt parsing.
    let fmt = "--format=%H%x1f%ct%x1f%an%x1f%ae%x1f%b%x1e";
    let out = std::process::Command::new("git")
        .args([
            "-C",
            &repo_root.to_string_lossy(),
            "log",
            branch,
            &format!("-n{max_commits}"),
            fmt,
        ])
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return Vec::new(),
    };
    let text = String::from_utf8_lossy(&stdout);
    let mut commits = Vec::new();
    for rec in text.split('\u{1e}') {
        let rec = rec.trim_matches(|c| c == '\n' || c == '\r');
        if rec.is_empty() {
            continue;
        }
        let f: Vec<&str> = rec.split('\u{1f}').collect();
        if f.len() < 5 {
            continue;
        }
        let ts_unix = f[1].trim().parse::<u64>().unwrap_or(0);
        let zero_touch = f[4].to_lowercase().contains("chump-agent:");
        let idl = format!("{} {}", f[2], f[3]).to_lowercase();
        let is_bot = idl.contains("bot") || idl.contains("github-actions");
        commits.push(ProvenanceCommit {
            hash: f[0].trim().to_string(),
            ts_unix,
            zero_touch,
            is_bot,
        });
    }
    commits
}

/// The public metric: classify the last `max_commits` on `branch` and compute the streak.
pub fn zero_touch_streak(repo_root: &Path, branch: &str, max_commits: u64) -> StreakMetric {
    let commits = scan_provenance(repo_root, branch, max_commits);
    let now = chrono::Utc::now().timestamp().max(0) as u64;
    compute_streak(&commits, branch, now)
}

fn ambient_paths(repo_root: &Path) -> Vec<PathBuf> {
    let dir = repo_root.join(".chump-locks");
    // Current stream + the one rotated file, so a window that spans a rotation still sees both.
    vec![dir.join("ambient.jsonl"), dir.join("ambient.jsonl.1")]
}

/// Scan the live ambient stream + human rescue commits over the last `window_hours`.
pub fn scan(repo_root: &Path, window_hours: u64) -> WatchdogReport {
    let since = chrono::Utc::now()
        .checked_sub_signed(chrono::Duration::hours(window_hours as i64))
        .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));

    let mut lines: Vec<String> = Vec::new();
    for p in ambient_paths(repo_root) {
        if let Ok(content) = std::fs::read_to_string(&p) {
            lines.extend(content.lines().map(|s| s.to_string()));
        }
    }
    let mut interventions = interventions_from_lines(lines, since.as_deref());

    // Reuse rescue_tally for human-authored rescue commits on main — the authoritative
    // provenance detector — so we neither reinvent it nor double-count `session_rescue`
    // (which is excluded from `classify_intervention` for exactly this reason).
    for r in crate::rescue_tally::scan_rescues(repo_root, window_hours) {
        let short: String = r.hash.chars().take(8).collect();
        interventions.push(Intervention {
            ts: String::new(),
            kind: "session_rescue".to_string(),
            class: DefectClass::CeremonyGap,
            context: format!("commit={short} subject={}", r.subject),
        });
    }

    WatchdogReport::tally(interventions)
}

/// Emit one `autonomy_defect` ambient event per intervention (AC1: typed, with context).
fn emit_autonomy_defects(repo_root: &Path, report: &WatchdogReport) {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write;
    let mut file = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        Ok(f) => f,
        Err(_) => return,
    };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    for iv in &report.interventions {
        let entry = serde_json::json!({
            "ts": now,
            "kind": "autonomy_defect",
            "intervention_kind": iv.kind,
            "defect_class": iv.class.as_str(),
            "context": iv.context,
        });
        let _ = writeln!(file, "{entry}");
    }
    // A single rollup so observers can read the metric without re-tallying the stream.
    let counts = serde_json::to_string(&report.counts_by_class).unwrap_or_else(|_| "{}".into());
    let summary = serde_json::json!({
        "ts": now,
        "kind": "intervention_watchdog_summary",
        "total": report.total(),
        "counts_by_class": counts,
    });
    let _ = writeln!(file, "{summary}");
}

/// The stable title marker that makes a filed self-heal gap dedup-detectable across runs.
fn heal_marker(class: &str) -> String {
    format!("[self-heal COTG-2.1] {class}")
}

/// For each class with interventions, file ONE deduped self-heal gap (AC2). Returns
/// `(class, gap_id | "candidate" | "skip:already-open" | "error:…")` per class. In dry-run
/// (`apply == false`) nothing is written — the candidates are reported so a human/CI can see
/// what *would* be filed. Dedup is by the stable [`heal_marker`] against open gaps, so repeated
/// scans never spam the queue with the same self-heal.
pub fn file_self_heal_gaps(
    repo_root: &Path,
    report: &WatchdogReport,
    window_hours: u64,
    apply: bool,
) -> Result<Vec<(String, String)>> {
    let store = crate::gap_store::GapStore::open(repo_root)?;
    let open = store.list(Some("open")).unwrap_or_default();
    let mut results = Vec::new();

    for (class, count) in &report.counts_by_class {
        let marker = heal_marker(class);
        if open.iter().any(|g| g.title.contains(&marker)) {
            results.push((class.clone(), "skip:already-open".to_string()));
            continue;
        }
        // A class present in counts always has a representative intervention.
        let hint = report
            .interventions
            .iter()
            .find(|iv| iv.class.as_str() == class)
            .map(|iv| iv.class.heal_hint())
            .unwrap_or("");
        let title = format!(
            "RESILIENT: {marker} — {count} human intervention(s) in last {window_hours}h; {hint}"
        );
        if !apply {
            results.push((class.clone(), "candidate".to_string()));
            continue;
        }
        match store.reserve("RESILIENT", &title, "P2", "s") {
            Ok(id) => results.push((class.clone(), id)),
            Err(e) => results.push((class.clone(), format!("error:{e}"))),
        }
    }
    Ok(results)
}

fn find_repo_root() -> PathBuf {
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        if dir.join(".chump").join("state.db").exists() || dir.join(".git").exists() {
            return dir;
        }
        if !dir.pop() {
            return std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        }
    }
}

fn usage() -> i32 {
    eprintln!(
        "chump intervention-watchdog — COTG-2.1: log every human touch as an autonomy defect\n\n\
USAGE:\n  chump intervention-watchdog [--window <hours>] [--apply] [--json]\n\n\
FLAGS:\n  \
--window <hours>   Look-back window (default 24)\n  \
--apply            Emit `autonomy_defect` events AND file deduped self-heal gaps.\n  \
                   Default is dry-run: report candidates, write nothing.\n  \
--json             Machine-readable output (the queryable intervention metric)."
    );
    2
}

/// CLI entry — dispatched from `main.rs` on `chump intervention-watchdog`.
pub fn run(args: &[String]) -> i32 {
    let mut window: u64 = 24;
    let mut apply = false;
    let mut json = false;
    let mut streak_mode = false;
    let mut branch = "origin/main".to_string();
    let mut max_commits: u64 = 200;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--window" => {
                i += 1;
                match args.get(i).and_then(|s| s.parse::<u64>().ok()) {
                    Some(w) => window = w,
                    None => {
                        eprintln!("--window needs a number of hours");
                        return usage();
                    }
                }
            }
            "--streak" => streak_mode = true,
            "--branch" => {
                i += 1;
                match args.get(i) {
                    Some(b) => branch = b.clone(),
                    None => {
                        eprintln!("--branch needs a ref");
                        return usage();
                    }
                }
            }
            "--max" => {
                i += 1;
                match args.get(i).and_then(|s| s.parse::<u64>().ok()) {
                    Some(m) => max_commits = m,
                    None => {
                        eprintln!("--max needs a number of commits");
                        return usage();
                    }
                }
            }
            "--apply" => apply = true,
            "--json" => json = true,
            "-h" | "--help" => return usage(),
            other => {
                eprintln!("unknown flag: {other}");
                return usage();
            }
        }
        i += 1;
    }

    let repo_root = find_repo_root();

    // CREDIBLE-171: the readiness number — how long has it run without a human touch.
    if streak_mode {
        let m = zero_touch_streak(&repo_root, &branch, max_commits);
        if json {
            println!(
                "{}",
                serde_json::to_string(&m).unwrap_or_else(|_| "{}".into())
            );
            return 0;
        }
        println!(
            "zero-touch streak on {} (last {} commits):",
            m.branch, m.commits_scanned
        );
        println!(
            "  OS (zero-touch): {}   human touches: {}   bot: {}",
            m.zero_touch_commits, m.human_touches, m.bot_touches
        );
        println!(
            "  longest hands-off streak: {} commits",
            m.longest_zero_touch_streak
        );
        println!("  current streak: {} commits", m.current_zero_touch_streak);
        match m.hours_since_last_human_touch {
            Some(h) => println!("  hours since last human touch: {h:.1}"),
            None => println!("  no human touch in window — fully hands-off"),
        }
        println!("  zero-touch ratio: {:.0}%", m.zero_touch_ratio * 100.0);
        return 0;
    }

    let report = scan(&repo_root, window);

    if apply {
        emit_autonomy_defects(&repo_root, &report);
    }
    let gaps = match file_self_heal_gaps(&repo_root, &report, window, apply) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("could not open gap store: {e}");
            Vec::new()
        }
    };

    if json {
        let out = serde_json::json!({
            "window_hours": window,
            "applied": apply,
            "total_interventions": report.total(),
            "counts_by_class": report.counts_by_class,
            "self_heal_gaps": gaps
                .iter()
                .map(|(c, r)| serde_json::json!({ "class": c, "result": r }))
                .collect::<Vec<_>>(),
        });
        println!("{out}");
        return 0;
    }

    let mode = if apply { "APPLY" } else { "dry-run" };
    println!(
        "intervention-watchdog [{mode}] — {} human intervention(s) in last {window}h",
        report.total()
    );
    if report.total() == 0 {
        println!("  clean window: no human touches detected. (autonomy held)");
        return 0;
    }
    for (class, count) in &report.counts_by_class {
        println!("  {class}: {count}");
    }
    println!("self-heal gaps:");
    for (class, result) in &gaps {
        println!("  {class} -> {result}");
    }
    if !apply {
        println!("(dry-run — re-run with --apply to emit autonomy_defect events + file gaps)");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The classifier must INCLUDE human bypasses/forces/manual-rescues and EXCLUDE the OS's
    /// routine automatic self-heals — otherwise the OS healing itself drowns the real signal.
    #[test]
    fn classify_includes_human_touches_excludes_auto_heals() {
        // human interventions → classed
        assert_eq!(
            classify_intervention("off_rails_bypassed"),
            Some(DefectClass::DeterministicGateFailure)
        );
        assert_eq!(
            classify_intervention("preflight_bypassed"),
            Some(DefectClass::DeterministicGateFailure)
        );
        assert_eq!(
            classify_intervention("bot_merge_bypassed"),
            Some(DefectClass::Coordination)
        );
        assert_eq!(
            classify_intervention("chump_claim_force_recover"),
            Some(DefectClass::Coordination)
        );
        assert_eq!(
            classify_intervention("admin_merge_forced"),
            Some(DefectClass::CeremonyGap)
        );
        // routine automatic self-heals → NOT interventions
        for auto in [
            "blame_bot_dedupe_skip",
            "stale_process_reaped",
            "stale_gap_lock_reaped",
            "worktree_build_cache_skip",
            "binary_auto_deploy_skipped",
            "runner_binary_refresh_skipped",
            "bot_merge_watchdog_killed",
            "session_rescue", // handled by rescue_tally in scan(), not double-counted here
        ] {
            assert_eq!(classify_intervention(auto), None, "{auto} must not class");
        }
    }

    /// The line parser classes real interventions, skips non-interventions + junk lines, lifts
    /// reproduction context, and honors the `since` window bound.
    #[test]
    fn parse_classes_windows_and_lifts_context() {
        let lines = vec![
            r#"{"ts":"2026-07-29T10:00:00Z","kind":"off_rails_bypassed","claimed_gap":"INFRA-1","reason":"docs only"}"#.to_string(),
            r#"{"ts":"2026-07-29T11:00:00Z","kind":"blame_bot_dedupe_skip"}"#.to_string(), // auto-heal, skip
            r#"{"ts":"2026-07-20T09:00:00Z","kind":"bot_merge_bypassed","reason":"lock wedged"}"#.to_string(), // older than window
            r#"not json at all"#.to_string(),                                              // junk, skip
            r#"{"ts":"2026-07-29T12:00:00Z","kind":"admin_merge_forced","pr":"42","operator":"jeff"}"#.to_string(),
        ];
        let since = "2026-07-25T00:00:00Z";
        let found = interventions_from_lines(lines, Some(since));
        assert_eq!(found.len(), 2, "only the 2 in-window interventions");
        let kinds: Vec<&str> = found.iter().map(|i| i.kind.as_str()).collect();
        assert!(kinds.contains(&"off_rails_bypassed"));
        assert!(kinds.contains(&"admin_merge_forced"));
        assert!(!kinds.contains(&"bot_merge_bypassed"), "windowed out");
        let off = found
            .iter()
            .find(|i| i.kind == "off_rails_bypassed")
            .unwrap();
        assert!(off.context.contains("claimed_gap=INFRA-1"));
        assert!(off.context.contains("reason=docs only"));
    }

    /// AC3 end-to-end (hermetic): a simulated manual gate-fix emits a classed defect, the
    /// count is queryable, a candidate gap is produced in dry-run, `--apply` files a real gap
    /// into state.db, and a second apply DEDUPS instead of re-filing.
    #[test]
    fn simulated_gate_fix_produces_classed_defect_and_deduped_gap() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        std::fs::create_dir_all(root.join(".chump")).unwrap();
        // one simulated manual gate-fix intervention
        let lines = vec![
            r#"{"ts":"2026-07-29T10:00:00Z","kind":"off_rails_bypassed","reason":"simulated manual gate-fix"}"#.to_string(),
        ];
        let report = WatchdogReport::tally(interventions_from_lines(lines, None));

        // classed + count queryable (AC3 metric)
        assert_eq!(report.total(), 1);
        assert_eq!(
            report.counts_by_class.get("deterministic-gate-failure"),
            Some(&1)
        );

        // dry-run → a candidate, nothing written
        let dry = file_self_heal_gaps(root, &report, 24, false).unwrap();
        assert_eq!(dry.len(), 1);
        assert_eq!(dry[0].0, "deterministic-gate-failure");
        assert_eq!(dry[0].1, "candidate");

        // apply → a real gap id reserved in state.db
        let applied = file_self_heal_gaps(root, &report, 24, true).unwrap();
        assert!(
            applied[0].1.contains('-'),
            "expected a reserved gap id, got {:?}",
            applied[0].1
        );

        // second apply → deduped, not re-filed
        let again = file_self_heal_gaps(root, &report, 24, true).unwrap();
        assert_eq!(again[0].1, "skip:already-open", "must dedup, not spam");
    }

    fn pc(zero_touch: bool, is_bot: bool, ts: u64) -> ProvenanceCommit {
        ProvenanceCommit {
            hash: format!("h{ts}"),
            ts_unix: ts,
            zero_touch,
            is_bot,
        }
    }

    /// CREDIBLE-171: the streak metric counts a HUMAN touch as a commit lacking the
    /// zero-touch trailer AND not a bot; it measures the longest/current hands-off run and
    /// hours since the last human touch. Newest-first order (git log default).
    #[test]
    fn streak_counts_human_touches_and_hands_off_runs() {
        let now = 1_000_000u64;
        // newest-first: OS, OS, bot, OS, HUMAN, OS, OS
        //  current streak = 4 (OS,OS,bot,OS before the human), longest = 4,
        //  human_touches = 1, hours_since = (now - ts_of_human)/3600.
        let human_ts = now - 7200; // 2h ago
        let commits = vec![
            pc(true, false, now - 60),
            pc(true, false, now - 120),
            pc(false, true, now - 180), // bot — not a human touch
            pc(true, false, now - 240),
            pc(false, false, human_ts), // the human touch
            pc(true, false, now - 8000),
            pc(true, false, now - 9000),
        ];
        let m = compute_streak(&commits, "origin/main", now);
        assert_eq!(m.commits_scanned, 7);
        assert_eq!(m.zero_touch_commits, 5);
        assert_eq!(m.human_touches, 1);
        assert_eq!(m.bot_touches, 1);
        assert_eq!(
            m.current_zero_touch_streak, 4,
            "4 non-human commits before the human"
        );
        assert_eq!(m.longest_zero_touch_streak, 4);
        assert_eq!(m.hours_since_last_human_touch, Some(2.0));

        // fully hands-off window → no human touch, streak == scanned, hours None
        let clean = vec![pc(true, false, now - 10), pc(false, true, now - 20)];
        let mc = compute_streak(&clean, "origin/main", now);
        assert_eq!(mc.human_touches, 0);
        assert_eq!(mc.current_zero_touch_streak, 2);
        assert_eq!(mc.hours_since_last_human_touch, None);
        assert!(
            (mc.zero_touch_ratio - 0.5).abs() < 1e-9,
            "1 of 2 carry the trailer"
        );
    }
}
