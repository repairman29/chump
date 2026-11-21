//! PRODUCT-141: `chump assess <repo>` — check-then-generate roadmap + a generalized
//! % to goal that is not tied to one tool's roadmap format.
//!
//! Flow: (1) discover existing plan docs (almanac search first, filesystem walk as
//! the authoritative fallback) BEFORE ever offering to generate one; (2) parse the
//! chosen doc into one done/in-progress/not-started model regardless of format;
//! (3) offer `roadmap-from-vision` only when no plan exists; (4) report a % only when
//! the plan yields items with a known status — never against an invented goal.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const STALE_DAYS: u64 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Done,
    InProgress,
    NotStarted,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    ChumpWeekly,
    StatusTable,
    Checklist,
    Phased,
    None,
}

impl Format {
    pub fn name(self) -> &'static str {
        match self {
            Format::ChumpWeekly => "chump-weekly-outcomes",
            Format::StatusTable => "status-tagged-table",
            Format::Checklist => "checkbox-checklist",
            Format::Phased => "phased-prose",
            Format::None => "none",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Item {
    pub label: String,
    pub status: Status,
}

fn tokens(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(String::from)
        .collect()
}

/// Classify free text (a table cell, heading, or prose lead) into a status.
/// Negations are checked first so "not started" / "not built" never read as done.
pub fn classify(text: &str) -> Status {
    let lower = text.to_lowercase();
    let toks = tokens(&lower);
    let has = |w: &str| toks.iter().any(|t| t == w);
    let phrase = |p: &str| lower.contains(p);

    if phrase("not started")
        || phrase("not built")
        || phrase("not done")
        || phrase("not yet")
        || has("todo")
        || has("planned")
        || has("backlog")
        || has("pending")
        || has("unstarted")
        || has("next")
        || has("incomplete")
        || lower.contains('⬜')
        || lower.contains('☐')
        || lower.contains('❌')
        || lower.contains("[ ]")
    {
        return Status::NotStarted;
    }
    if phrase("in progress")
        || phrase("in-progress")
        || phrase("building now")
        || has("wip")
        || has("partial")
        || has("started")
        || has("building")
        || lower.contains('🔄')
        || lower.contains('🚧')
        || lower.contains('🟡')
        || lower.contains("[~]")
        || lower.contains("[-]")
    {
        return Status::InProgress;
    }
    if has("done")
        || has("shipped")
        || has("complete")
        || has("completed")
        || has("merged")
        || has("landed")
        || has("built")
        || has("live")
        || has("closed")
        || lower.contains('✅')
        || lower.contains('☑')
        || lower.contains('🟢')
        || lower.contains("[x]")
    {
        return Status::Done;
    }
    if has("open") {
        return Status::NotStarted;
    }
    Status::Unknown
}

fn checkbox(line: &str) -> Option<(Status, String)> {
    let t = line.trim_start();
    let rest = t.strip_prefix("- ").or_else(|| t.strip_prefix("* "))?;
    let (mark, body) = if let Some(b) = rest.strip_prefix("[x] ").or(rest.strip_prefix("[X] ")) {
        (Status::Done, b)
    } else if let Some(b) = rest.strip_prefix("[ ] ") {
        (Status::NotStarted, b)
    } else if let Some(b) = rest.strip_prefix("[~] ").or(rest.strip_prefix("[-] ")) {
        (Status::InProgress, b)
    } else {
        return None;
    };
    Some((mark, clip(body)))
}

fn clip(s: &str) -> String {
    let s = s.trim().replace("**", "");
    if s.chars().count() > 90 {
        let mut o: String = s.chars().take(87).collect();
        o.push_str("...");
        o
    } else {
        s
    }
}

fn split_row(line: &str) -> Vec<String> {
    line.trim()
        .trim_matches('|')
        .split('|')
        .map(|c| c.trim().to_string())
        .collect()
}

fn is_sep_row(line: &str) -> bool {
    let t = line.trim();
    t.starts_with('|') && t.chars().all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t'))
}

fn parse_tables(content: &str) -> Vec<Item> {
    let mut items = Vec::new();
    let mut status_col: Option<usize> = None;
    for line in content.lines() {
        let t = line.trim();
        if !t.starts_with('|') {
            status_col = None;
            continue;
        }
        if is_sep_row(t) {
            continue;
        }
        let cells = split_row(t);
        if status_col.is_none() {
            status_col = cells.iter().position(|c| {
                let l = c.to_lowercase();
                matches!(
                    l.as_str(),
                    "status" | "state" | "done" | "progress" | "done?"
                )
            });
            continue; // header row (or a table without a status column)
        }
        let col = status_col.unwrap();
        let Some(cell) = cells.get(col) else { continue };
        let status = classify(cell);
        let label = cells
            .iter()
            .enumerate()
            .filter(|(i, c)| *i != col && !c.is_empty())
            .map(|(_, c)| c.as_str())
            .take(2)
            .collect::<Vec<_>>()
            .join(" — ");
        items.push(Item {
            label: clip(&label),
            status,
        });
    }
    items
}

fn parse_checklist(content: &str) -> Vec<Item> {
    content
        .lines()
        .filter_map(|l| checkbox(l).map(|(s, label)| Item { label, status: s }))
        .collect()
}

fn phase_label(s: &str) -> bool {
    let toks = tokens(s);
    let Some(first) = toks.first() else {
        return false;
    };
    let numbered = first.len() <= 3
        && first.chars().next().is_some_and(|c| c.is_alphabetic())
        && first.chars().skip(1).all(|c| c.is_ascii_digit())
        && first.len() >= 2;
    matches!(
        first.as_str(),
        "phase" | "stage" | "milestone" | "mile" | "step" | "sprint" | "wave" | "track"
    ) || numbered
}

fn section_status(heading: &str, body: &[&str]) -> Status {
    let h = classify(heading);
    if h != Status::Unknown {
        return h;
    }
    for l in body {
        let t = l.trim().trim_start_matches(['*', '_', '>', ' ']);
        if t.to_lowercase().starts_with("status") {
            let s = classify(t);
            if s != Status::Unknown {
                return s;
            }
        }
    }
    let boxes: Vec<Status> = body
        .iter()
        .filter_map(|l| checkbox(l).map(|c| c.0))
        .collect();
    if !boxes.is_empty() {
        return if boxes.iter().all(|s| *s == Status::Done) {
            Status::Done
        } else if boxes.iter().all(|s| *s == Status::NotStarted) {
            Status::NotStarted
        } else {
            Status::InProgress
        };
    }
    Status::Unknown
}

fn parse_phased(content: &str) -> Vec<Item> {
    let lines: Vec<&str> = content.lines().collect();
    let mut items = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let heading = line.trim_start_matches('#').trim().to_string();
        let is_heading = line.starts_with("##") && phase_label(&heading.replace("**", ""));
        let bullet = line.strip_prefix("- **").map(|r| {
            let label_end = r.find("**").unwrap_or(r.len());
            (r[..label_end].to_string(), r[label_end..].to_string())
        });
        let is_bullet = bullet.as_ref().is_some_and(|(l, _)| phase_label(l));
        if is_heading || is_bullet {
            let mut j = i + 1;
            while j < lines.len() {
                let l = lines[j];
                if l.starts_with('#') || (l.starts_with("- **") && j > i) {
                    break;
                }
                j += 1;
            }
            let body = &lines[i + 1..j];
            let (label, status) = if is_bullet {
                let (l, rest) = bullet.unwrap();
                // Prose lead: the rest of the first line + up to 2 continuation lines.
                let lead: String = std::iter::once(rest.as_str())
                    .chain(body.iter().take(2).copied())
                    .collect::<Vec<_>>()
                    .join(" ");
                let lead = lead.chars().take(220).collect::<String>();
                let st = classify(&lead);
                (l, st)
            } else {
                (heading.clone(), section_status(&heading, body))
            };
            items.push(Item {
                label: clip(&label),
                status,
            });
            i = j;
        } else {
            i += 1;
        }
    }
    items
}

/// Parse any plan doc into the common model. Returns the detected format + items.
/// Chump weekly docs return their gap ids with `Unknown` status here; the caller
/// resolves them against the gap registry.
pub fn parse_plan(content: &str) -> (Format, Vec<Item>) {
    if content.contains("## Week ") && content.contains("**Implementing gaps") {
        let weeks = crate::roadmap_status::parse_roadmap(content);
        let items: Vec<Item> = weeks
            .iter()
            .flat_map(|w| {
                w.gaps.iter().map(move |g| Item {
                    label: format!("W{}: {}", w.week, g.id),
                    status: if g.is_placeholder {
                        Status::NotStarted
                    } else {
                        Status::Unknown
                    },
                })
            })
            .collect();
        if !items.is_empty() {
            return (Format::ChumpWeekly, items);
        }
    }
    let table = parse_tables(content);
    let known = |v: &[Item]| v.iter().filter(|i| i.status != Status::Unknown).count();
    if known(&table) >= 2 {
        return (Format::StatusTable, table);
    }
    let boxes = parse_checklist(content);
    if boxes.len() >= 2 {
        return (Format::Checklist, boxes);
    }
    let phased = parse_phased(content);
    if !phased.is_empty() {
        return (Format::Phased, phased);
    }
    (Format::None, Vec::new())
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Tally {
    pub done: usize,
    pub in_progress: usize,
    pub not_started: usize,
    pub unknown: usize,
}

pub fn tally(items: &[Item]) -> Tally {
    let mut t = Tally::default();
    for i in items {
        match i.status {
            Status::Done => t.done += 1,
            Status::InProgress => t.in_progress += 1,
            Status::NotStarted => t.not_started += 1,
            Status::Unknown => t.unknown += 1,
        }
    }
    t
}

/// % of known-status items that are done. `None` when there is no real goal to
/// measure against (no items with a known status) — never a substitute score.
pub fn percent(t: &Tally) -> Option<f64> {
    let known = t.done + t.in_progress + t.not_started;
    if known == 0 {
        None
    } else {
        Some(100.0 * t.done as f64 / known as f64)
    }
}

#[derive(Debug, Clone)]
pub struct Candidate {
    pub rel: String,
    pub age_days: u64,
    pub canonical: bool,
}

impl Candidate {
    pub fn stale(&self) -> bool {
        self.age_days > STALE_DAYS
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selection {
    NoneFound,
    Pick(usize),
    AbandonedPile,
    Competing,
}

fn canonical_rank(rel: &str) -> Option<usize> {
    match rel.to_lowercase().as_str() {
        "roadmap.md" => Some(0),
        "docs/roadmap.md" => Some(1),
        "plan.md" => Some(2),
        "docs/plan.md" => Some(3),
        _ => None,
    }
}

/// Choose the canonical plan doc, or refuse (abandoned pile / competing docs)
/// rather than pick one arbitrarily.
pub fn select(cands: &[Candidate]) -> Selection {
    if cands.is_empty() {
        return Selection::NoneFound;
    }
    let canon = cands
        .iter()
        .enumerate()
        .filter(|(_, c)| c.canonical && !c.stale())
        .min_by_key(|(_, c)| canonical_rank(&c.rel).unwrap_or(99));
    if let Some((i, _)) = canon {
        return Selection::Pick(i);
    }
    let stale = cands.iter().filter(|c| c.stale()).count();
    if cands.len() >= 3 && stale * 4 >= cands.len() * 3 {
        return Selection::AbandonedPile;
    }
    let fresh: Vec<usize> = cands
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.stale())
        .map(|(i, _)| i)
        .collect();
    match fresh.len() {
        0 | 1 => {
            let i = cands
                .iter()
                .enumerate()
                .min_by_key(|(_, c)| c.age_days)
                .map(|(i, _)| i)
                .unwrap();
            Selection::Pick(i)
        }
        _ => Selection::Competing,
    }
}

fn is_plan_name(stem: &str) -> bool {
    tokens(stem).iter().any(|t| {
        matches!(
            t.as_str(),
            "roadmap" | "plan" | "plans" | "milestones" | "todo" | "mvp" | "phases" | "backlog"
        )
    })
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > 4 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if p.is_dir() {
            if matches!(
                name.as_str(),
                ".git" | "node_modules" | "target" | "vendor" | "dist" | ".claude" | ".next"
            ) || name.starts_with('.')
            {
                continue;
            }
            walk(&p, depth + 1, out);
        } else if name.to_lowercase().ends_with(".md") {
            let stem = name.trim_end_matches(".md").trim_end_matches(".MD");
            if is_plan_name(stem) {
                out.push(p);
            }
        }
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn age_days(repo: &Path, rel: &str) -> u64 {
    let git_ts = Command::new("git")
        .args(["-C"])
        .arg(repo)
        .args(["log", "-1", "--format=%ct", "--", rel])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<u64>().ok());
    let ts = git_ts.or_else(|| {
        std::fs::metadata(repo.join(rel))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
    });
    ts.map(|t| now_secs().saturating_sub(t) / 86400)
        .unwrap_or(u64::MAX / 86400)
}

fn collect_strings(v: &serde_json::Value, keys: &[&str], out: &mut Vec<String>) {
    match v {
        serde_json::Value::Object(m) => {
            for (k, val) in m {
                if keys.contains(&k.as_str()) {
                    if let Some(s) = val.as_str() {
                        out.push(s.to_string());
                    }
                }
                collect_strings(val, keys, out);
            }
        }
        serde_json::Value::Array(a) => a.iter().for_each(|x| collect_strings(x, keys, out)),
        _ => {}
    }
}

/// Best-effort almanac lookup: (slug for repo root, markdown paths almanac sees).
/// Returns the note describing which discovery path was used.
fn almanac_paths(repo: &Path) -> (Vec<String>, String) {
    let repos = Command::new("almanac").arg("repos").output();
    let Ok(repos) = repos else {
        return (vec![], "almanac not installed".into());
    };
    let text = String::from_utf8_lossy(&repos.stdout).to_string();
    let canon = repo.canonicalize().unwrap_or_else(|_| repo.to_path_buf());
    let slug = text.lines().find_map(|l| {
        let l = l.trim();
        let slug = l.split_whitespace().next()?;
        let path = l.rsplit_once('[')?.1.trim_end_matches(']');
        (Path::new(path) == canon).then(|| slug.to_string())
    });
    let Some(slug) = slug else {
        return (vec![], "repo not registered in almanac".into());
    };
    let mut found = Vec::new();
    for q in ["roadmap", "plan milestones phases"] {
        let o = Command::new("timeout")
            .args([
                "20", "almanac", "search", q, &slug, "--json", "--limit", "30",
            ])
            .output();
        let Ok(o) = o else { continue };
        if !o.status.success() {
            return (
                found,
                format!(
                    "almanac search failed ({}); used filesystem discovery",
                    String::from_utf8_lossy(&o.stderr)
                        .lines()
                        .next()
                        .unwrap_or("error")
                ),
            );
        }
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&o.stdout) {
            collect_strings(&v, &["path", "file", "file_path"], &mut found);
        }
    }
    (found, format!("almanac slug '{slug}'"))
}

pub fn discover(repo: &Path) -> (Vec<Candidate>, String) {
    let mut paths = Vec::new();
    walk(repo, 0, &mut paths);
    let (alm, note) = almanac_paths(repo);
    for a in alm {
        let a = a.trim_start_matches("./").to_string();
        let p = repo.join(&a);
        if a.to_lowercase().ends_with(".md")
            && p.is_file()
            && is_plan_name(
                Path::new(&a)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(""),
            )
            && !paths.contains(&p)
        {
            paths.push(p);
        }
    }
    paths.sort();
    let cands = paths
        .iter()
        .filter_map(|p| p.strip_prefix(repo).ok())
        .map(|r| {
            let rel = r.to_string_lossy().to_string();
            Candidate {
                age_days: age_days(repo, &rel),
                canonical: canonical_rank(&rel).is_some(),
                rel,
            }
        })
        .collect();
    (cands, note)
}

fn resolve_repo(arg: &str) -> Option<PathBuf> {
    let p = PathBuf::from(arg);
    if p.is_dir() {
        return p.canonicalize().ok();
    }
    let out = Command::new("almanac").arg("repos").output().ok()?;
    String::from_utf8_lossy(&out.stdout).lines().find_map(|l| {
        let l = l.trim();
        (l.split_whitespace().next()? == arg).then(|| {
            PathBuf::from(
                l.rsplit_once('[')
                    .map(|x| x.1)
                    .unwrap_or("")
                    .trim_end_matches(']'),
            )
        })
    })
}

fn status_word(s: Status) -> &'static str {
    match s {
        Status::Done => "done",
        Status::InProgress => "in-progress",
        Status::NotStarted => "not-started",
        Status::Unknown => "unknown",
    }
}

fn json_escape(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

fn print_usage() {
    eprintln!("Usage: chump assess <repo-path-or-almanac-slug> [--file <rel-path>] [--json]");
    eprintln!("                    [--generate --vision <STR> --domain <DOMAIN>]");
    eprintln!("  Checks for an existing plan doc first (almanac + filesystem), parses it into a");
    eprintln!(
        "  done/in-progress/not-started model, and reports a % only when a real goal exists."
    );
    eprintln!("  --generate only acts when NO plan doc exists (delegates to roadmap-from-vision).");
}

pub async fn run(args: &[String]) -> i32 {
    let want_json = args.iter().any(|a| a == "--json");
    let flag = |n: &str| args.windows(2).find(|w| w[0] == n).map(|w| w[1].clone());
    let Some(target) = args[1..]
        .iter()
        .enumerate()
        .find(|(i, a)| {
            !a.starts_with("--")
                && !matches!(
                    args.get(*i).map(String::as_str),
                    Some("--file" | "--vision" | "--domain")
                )
        })
        .map(|(_, a)| a.clone())
    else {
        print_usage();
        return 2;
    };
    let Some(repo) = resolve_repo(&target) else {
        eprintln!("assess: '{target}' is neither a directory nor a registered almanac repo");
        return 2;
    };

    let (cands, discovery) = discover(&repo);
    let selection = if let Some(f) = flag("--file") {
        match cands.iter().position(|c| c.rel == f) {
            Some(i) => Selection::Pick(i),
            None if repo.join(&f).is_file() => {
                // Explicit operator choice of a non-plan-named doc.
                return report_file(&repo, &f, &cands, &discovery, want_json);
            }
            None => {
                eprintln!("assess: --file {f} not found in {}", repo.display());
                return 2;
            }
        }
    } else {
        select(&cands)
    };

    match selection {
        Selection::Pick(i) => report_file(&repo, &cands[i].rel, &cands, &discovery, want_json),
        Selection::NoneFound => {
            let msg = "no existing plan/roadmap doc found (checked almanac + filesystem)";
            if args.iter().any(|a| a == "--generate") {
                let (Some(v), Some(d)) = (flag("--vision"), flag("--domain")) else {
                    eprintln!("assess: --generate needs --vision <STR> --domain <DOMAIN>");
                    return 2;
                };
                eprintln!("assess: {msg}; generating via roadmap-from-vision");
                let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("chump"));
                let st = Command::new(exe)
                    .args(["roadmap-from-vision", "--vision", &v, "--domain", &d])
                    .status();
                return st.ok().and_then(|s| s.code()).unwrap_or(1);
            }
            if want_json {
                println!(
                    "{{\"repo\":{},\"plan\":null,\"percent\":null,\"verdict\":\"no_plan\",\"discovery\":{}}}",
                    json_escape(&repo.display().to_string()),
                    json_escape(&discovery)
                );
            } else {
                println!("{}: {msg}", repo.display());
                println!("No % reported: there is no stated goal to measure against.");
                println!(
                    "To generate one: chump assess {} --generate --vision \"<vision>\" --domain <DOMAIN>",
                    target
                );
            }
            1
        }
        Selection::AbandonedPile | Selection::Competing => {
            let kind = if selection == Selection::AbandonedPile {
                "abandoned_plan_pile"
            } else {
                "competing_plans"
            };
            if want_json {
                let list: Vec<String> = cands
                    .iter()
                    .map(|c| {
                        format!(
                            "{{\"path\":{},\"age_days\":{}}}",
                            json_escape(&c.rel),
                            c.age_days
                        )
                    })
                    .collect();
                println!(
                    "{{\"repo\":{},\"plan\":null,\"percent\":null,\"verdict\":\"{kind}\",\"candidates\":[{}]}}",
                    json_escape(&repo.display().to_string()),
                    list.join(",")
                );
            } else {
                let stale = cands.iter().filter(|c| c.stale()).count();
                println!(
                    "{}: {} plan docs found, {} untouched >{STALE_DAYS}d, none canonical.",
                    repo.display(),
                    cands.len(),
                    stale
                );
                println!(
                    "Verdict: {} — refusing to pick one arbitrarily or report a %.",
                    kind.replace('_', " ")
                );
                println!("Pick the live one with: chump assess {target} --file <path>");
                for c in cands.iter().take(10) {
                    println!("  {:>5}d  {}", c.age_days, c.rel);
                }
                if cands.len() > 10 {
                    println!("  ... and {} more", cands.len() - 10);
                }
            }
            1
        }
    }
}

fn report_file(
    repo: &Path,
    rel: &str,
    cands: &[Candidate],
    discovery: &str,
    want_json: bool,
) -> i32 {
    let content = std::fs::read_to_string(repo.join(rel)).unwrap_or_default();
    let (format, mut items) = parse_plan(&content);

    if format == Format::ChumpWeekly
        && rel.eq_ignore_ascii_case("docs/ROADMAP.md")
        && crate::gap_store::GapStore::open(repo).is_ok()
    {
        let report = crate::roadmap_status::build_report(repo);
        items = report
            .weeks
            .iter()
            .flat_map(|w| {
                w.gaps.iter().map(move |g| Item {
                    label: format!("W{}: {}", w.week, g.id),
                    status: match g.status.as_str() {
                        "shipped" => Status::Done,
                        "in_flight" => Status::InProgress,
                        _ => Status::NotStarted,
                    },
                })
            })
            .collect();
    }

    let t = tally(&items);
    let pct = percent(&t);
    let other: Vec<&Candidate> = cands.iter().filter(|c| c.rel != rel).collect();
    let age = cands.iter().find(|c| c.rel == rel).map(|c| c.age_days);

    if want_json {
        let it: Vec<String> = items
            .iter()
            .map(|i| {
                format!(
                    "{{\"label\":{},\"status\":\"{}\"}}",
                    json_escape(&i.label),
                    status_word(i.status)
                )
            })
            .collect();
        println!(
            "{{\"repo\":{},\"plan\":{},\"format\":\"{}\",\"percent\":{},\"done\":{},\"in_progress\":{},\"not_started\":{},\"unknown\":{},\"other_plan_docs\":{},\"discovery\":{},\"items\":[{}]}}",
            json_escape(&repo.display().to_string()),
            json_escape(rel),
            format.name(),
            pct.map(|p| format!("{p:.1}")).unwrap_or_else(|| "null".into()),
            t.done,
            t.in_progress,
            t.not_started,
            t.unknown,
            other.len(),
            json_escape(discovery),
            it.join(",")
        );
    } else {
        println!("repo:      {}", repo.display());
        println!(
            "plan doc:  {rel}{}",
            age.map(|a| format!("  (last touched {a}d ago)"))
                .unwrap_or_default()
        );
        println!("format:    {}", format.name());
        println!("discovery: {discovery}");
        if !other.is_empty() {
            println!("other plan-like docs: {}", other.len());
        }
        println!(
            "items:     {} done / {} in-progress / {} not-started / {} unknown",
            t.done, t.in_progress, t.not_started, t.unknown
        );
        match pct {
            Some(p) => {
                println!("% to goal: {p:.0}%  (done / items with a known status; in-progress counts 0)");
                if t.unknown > 0 {
                    println!("           {} item(s) had no status signal and are excluded", t.unknown);
                }
            }
            None => println!(
                "% to goal: not reported — this doc yields no items with a known status, so there is no measurable goal (not substituting a health score)."
            ),
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_respects_negation_and_word_boundaries() {
        assert_eq!(classify("Not started"), Status::NotStarted);
        assert_eq!(classify("✅ done"), Status::Done);
        assert_eq!(classify("in progress"), Status::InProgress);
        assert_eq!(classify("abandoned"), Status::Unknown);
        assert_eq!(classify("built 2026-08-05"), Status::Done);
        assert_eq!(classify("NOT built"), Status::NotStarted);
    }

    #[test]
    fn status_table_olive_style() {
        let doc = "# Roadmap\n\n| ID | Ticket | Status |\n|---|---|---|\n| EX-1 | Login | ✅ Done |\n| EX-2 | Billing | 🔄 In progress |\n| LI-1 | Export | ☐ Todo |\n| BR-1 | Branding | ☐ Todo |\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::StatusTable);
        let t = tally(&items);
        assert_eq!((t.done, t.in_progress, t.not_started), (1, 1, 2));
        assert_eq!(percent(&t), Some(25.0));
    }

    #[test]
    fn checklist_format() {
        let doc = "- [x] one\n- [~] two\n  - [ ] nested\n- [ ] four\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::Checklist);
        assert_eq!(tally(&items).done, 1);
        assert_eq!(items.len(), 4);
    }

    #[test]
    fn phased_prose_headings_with_done_when() {
        let doc = "# Build\n\n## Phase 1 — Core ✅\nDone when: it boots.\n\n## Phase 2 — API (in progress)\nDone when: endpoints exist.\n\n## Phase 3 — Polish\nStatus: not started\nDone when: shipped.\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::Phased);
        assert_eq!(items.len(), 3);
        let t = tally(&items);
        assert_eq!((t.done, t.in_progress, t.not_started), (1, 1, 1));
    }

    #[test]
    fn phased_bold_bullets() {
        let doc = "- **Phase A — Core.** *(built 2026-08-06)* it works.\n- **Phase B — Daemon.** *(building now)*\n- **Phase C — Scale.** Not started yet.\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::Phased);
        let t = tally(&items);
        assert_eq!((t.done, t.in_progress, t.not_started), (1, 1, 1));
    }

    #[test]
    fn chump_weekly_detected() {
        let doc = "## Week 1 — Foo\n**Outcome.** x\n**Implementing gaps (in order):**\n- **INFRA-1** — a\n- **INFRA-NEW** — b\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::ChumpWeekly);
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn no_goal_no_percent() {
        let doc = "# Vision\n\nWe want to build something great.\n\n## Why\n\nBecause.\n";
        let (f, items) = parse_plan(doc);
        assert_eq!(f, Format::None);
        assert_eq!(percent(&tally(&items)), None);
        // items present but all unknown -> still no %
        let t = Tally {
            unknown: 3,
            ..Default::default()
        };
        assert_eq!(percent(&t), None);
    }

    fn cand(rel: &str, age: u64) -> Candidate {
        Candidate {
            rel: rel.into(),
            age_days: age,
            canonical: canonical_rank(rel).is_some(),
        }
    }

    #[test]
    fn selection_flags_abandoned_pile() {
        let cands: Vec<Candidate> = (0..6)
            .map(|i| cand(&format!("docs/plan-{i}.md"), 90 + i))
            .collect();
        assert_eq!(select(&cands), Selection::AbandonedPile);
    }

    #[test]
    fn selection_prefers_fresh_canonical_and_flags_competing() {
        let c = vec![cand("ROADMAP.md", 2), cand("docs/old-plan.md", 200)];
        assert_eq!(select(&c), Selection::Pick(0));
        let c = vec![cand("docs/a-plan.md", 3), cand("docs/b-plan.md", 5)];
        assert_eq!(select(&c), Selection::Competing);
        assert_eq!(select(&[]), Selection::NoneFound);
    }
}
