//! INFRA-3508 (COTG-S.1): the sourcing resolver — "repo → arsenal → world"
//! prior-art check that runs BEFORE the Flow builds anything.
//!
//! Productizes the manual discovery scan (2026-07-29, §5.5 of
//! `docs/strategy/COTG_READINESS_BACKLOG.md`) that caught 14 already-built
//! capabilities filed as "build." Given a capability keyword, resolves it in
//! three tiers, in order, and stops at the first hit:
//!
//! 1. **This repo** — a lightweight structural-completeness scan of `src/**/*.rs`:
//!    a keyword with a definition site AND a reference elsewhere is
//!    [`SourcingVerdict::DoneHere`]; a definition with no other reference is
//!    [`SourcingVerdict::HalfDoneHere`] (built but not wired — the exact class
//!    the discovery scan was built to catch). This is deliberately NOT mere
//!    keyword-grep-anywhere (that false-positives on comments/docs); it requires
//!    a Rust definition site. Full structural wiring via the comprehension
//!    organs (`src/comprehend_tool.rs`) is tracked separately — this is the
//!    cheap first cut the AC calls for.
//! 2. **Our arsenal** — `docs/arsenal/GLOBAL_ARSENAL.json` (the 76-repo harvester
//!    catalog): [`SourcingVerdict::ExistsInArsenal`] with the owning repo(s) as
//!    receipt.
//! 3. **The open-source world** — a small curated table of well-known
//!    commodity crates/packages (the "own-vs-rent" precedent from COTG-S.3):
//!    [`SourcingVerdict::ExistsInWorld`] with package + scale as receipt.
//!
//! No hit in any tier → [`SourcingVerdict::NotFound`] (genuinely novel — build it).

use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourcingVerdict {
    DoneHere,
    HalfDoneHere,
    ExistsInArsenal,
    ExistsInWorld,
    NotFound,
}

impl SourcingVerdict {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::DoneHere => "DONE-HERE",
            Self::HalfDoneHere => "HALF-DONE-HERE",
            Self::ExistsInArsenal => "EXISTS-IN-ARSENAL",
            Self::ExistsInWorld => "EXISTS-IN-WORLD",
            Self::NotFound => "NOT-FOUND",
        }
    }
}

/// A pointer to WHY a verdict was reached — file:line / repo / package+stars,
/// per AC1.
#[derive(Debug, Clone)]
pub struct Receipt {
    pub tier: &'static str,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct SourcingResolution {
    pub verdict: SourcingVerdict,
    pub receipts: Vec<Receipt>,
}

/// Curated commodity capabilities that are always SOURCE, never BUILD (the
/// resilience-library precedent from COTG-S.3: "don't build, cockatiel/LiteLLM
/// own it"). Keyword match is substring, case-insensitive, either direction.
const WELL_KNOWN_WORLD: &[(&str, &str, &str)] = &[
    ("resilience", "cockatiel", "npm, ~1.5k stars"),
    ("circuit breaker", "cockatiel", "npm, ~1.5k stars"),
    ("retry", "backoff", "crates.io, ~500k downloads/mo"),
    ("http client", "reqwest", "crates.io, ~200M downloads"),
    ("logging", "tracing", "crates.io, ~100M downloads"),
    ("serialization", "serde", "crates.io, ~500M downloads"),
    ("json parsing", "serde_json", "crates.io, ~400M downloads"),
    ("date parsing", "chrono", "crates.io, ~300M downloads"),
    ("regex matching", "regex", "crates.io, ~250M downloads"),
];

/// Resolve `keyword` (a capability description, e.g. a gap title's noun
/// phrase) against the three tiers. `repo_root` is the repo to scan for tier 1
/// (pass the chump checkout root in production); `arsenal_json` is the path to
/// the harvester catalog (`docs/arsenal/GLOBAL_ARSENAL.json` in production).
/// Both are parameters (not hardcoded) so this is unit-testable against fixtures.
pub fn resolve_sourcing(
    keyword: &str,
    repo_root: &Path,
    arsenal_json: &Path,
) -> SourcingResolution {
    let kw = keyword.trim().to_lowercase();
    if kw.is_empty() {
        return SourcingResolution {
            verdict: SourcingVerdict::NotFound,
            receipts: vec![],
        };
    }

    if let Some(r) = resolve_repo_tier(&kw, repo_root) {
        return r;
    }
    if let Some(r) = resolve_arsenal_tier(&kw, arsenal_json) {
        return r;
    }
    if let Some(r) = resolve_world_tier(&kw) {
        return r;
    }

    SourcingResolution {
        verdict: SourcingVerdict::NotFound,
        receipts: vec![],
    }
}

/// Normalize a capability keyword phrase into the identifier fragments a Rust
/// definition would plausibly contain: lowercase words, and the same words
/// joined with `_` (the snake_case form a fn/struct name would use).
fn keyword_fragments(kw: &str) -> Vec<String> {
    let words: Vec<&str> = kw.split_whitespace().collect();
    if words.is_empty() {
        return vec![];
    }
    let mut out = vec![words.join("_")];
    if words.len() == 1 {
        out.push(words[0].to_string());
    }
    out
}

/// Tier 1: this repo, structural completeness. A definition site (`fn `,
/// `struct `, `enum `, `trait `) containing a keyword fragment counts as
/// "built here"; if that fragment ALSO appears elsewhere (a call/use site),
/// it's wired (`DoneHere`); if the definition is the only occurrence, it's
/// built-but-not-wired (`HalfDoneHere`) — the exact discovery-scan failure
/// class this resolver exists to catch.
fn resolve_repo_tier(kw: &str, repo_root: &Path) -> Option<SourcingResolution> {
    let fragments = keyword_fragments(kw);
    if fragments.is_empty() {
        return None;
    }

    let src_dir = repo_root.join("src");
    if !src_dir.is_dir() {
        return None;
    }

    let mut files = Vec::new();
    collect_rs_files(&src_dir, &mut files);

    let mut def_site: Option<(String, usize)> = None;
    let mut total_occurrences: usize = 0;

    for path in &files {
        let Ok(contents) = std::fs::read_to_string(path) else {
            continue;
        };
        for (idx, line) in contents.lines().enumerate() {
            let lower = line.to_lowercase();
            let hits = fragments.iter().any(|f| lower.contains(f.as_str()));
            if !hits {
                continue;
            }
            total_occurrences += 1;
            // A def site is a definition KEYWORD directly followed by the
            // fragment (allowing `pub `/`pub(crate) ` prefixes) — not merely a
            // line that mentions both "fn" and the fragment (e.g. a call site
            // inside some unrelated `fn use_it() { ... fragment ... }`).
            let is_def = def_site.is_none()
                && fragments.iter().any(|f| {
                    ["fn ", "struct ", "enum ", "trait "].iter().any(|kw| {
                        let needle = format!("{kw}{f}");
                        lower.contains(&needle)
                    })
                });
            if is_def {
                def_site = Some((path.display().to_string(), idx + 1));
            }
        }
    }

    let (file, line) = def_site?;
    let verdict = if total_occurrences > 1 {
        SourcingVerdict::DoneHere
    } else {
        SourcingVerdict::HalfDoneHere
    };
    Some(SourcingResolution {
        verdict,
        receipts: vec![Receipt {
            tier: "repo",
            detail: format!("{file}:{line}"),
        }],
    })
}

fn collect_rs_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if name == "target" || name == ".git" || name == "node_modules" {
                continue;
            }
            collect_rs_files(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}

/// Tier 2: our arsenal — `docs/arsenal/GLOBAL_ARSENAL.json`. Matches the
/// keyword (or any single word from it) against `primitives_index` keys and
/// against each repo's name/description/topics in `repos_by_name`.
fn resolve_arsenal_tier(kw: &str, arsenal_json: &Path) -> Option<SourcingResolution> {
    let contents = std::fs::read_to_string(arsenal_json).ok()?;
    let json: serde_json::Value = serde_json::from_str(&contents).ok()?;

    let words: Vec<&str> = kw.split_whitespace().collect();
    let matches_kw = |hay: &str| -> bool {
        let hay = hay.to_lowercase();
        hay.contains(kw) || words.iter().any(|w| w.len() > 3 && hay.contains(w))
    };

    if let Some(primitives) = json.get("primitives_index").and_then(|v| v.as_object()) {
        for (key, repos) in primitives {
            if matches_kw(key) {
                let repo_names: Vec<String> = repos
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default();
                return Some(SourcingResolution {
                    verdict: SourcingVerdict::ExistsInArsenal,
                    receipts: vec![Receipt {
                        tier: "arsenal",
                        detail: format!("primitive={key} repos={}", repo_names.join(",")),
                    }],
                });
            }
        }
    }

    if let Some(repos) = json.get("repos_by_name").and_then(|v| v.as_object()) {
        for (name, meta) in repos {
            let desc = meta
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let topics: Vec<&str> = meta
                .get("topics")
                .and_then(|v| v.as_array())
                .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
                .unwrap_or_default();
            let haystack = format!("{name} {desc} {}", topics.join(" "));
            if matches_kw(&haystack) {
                return Some(SourcingResolution {
                    verdict: SourcingVerdict::ExistsInArsenal,
                    receipts: vec![Receipt {
                        tier: "arsenal",
                        detail: format!("repo={name}"),
                    }],
                });
            }
        }
    }

    None
}

/// Tier 3: the open-source world — the curated commodity-capability table.
fn resolve_world_tier(kw: &str) -> Option<SourcingResolution> {
    for (capability, package, scale) in WELL_KNOWN_WORLD {
        if kw.contains(capability) || capability.contains(kw) {
            return Some(SourcingResolution {
                verdict: SourcingVerdict::ExistsInWorld,
                receipts: vec![Receipt {
                    tier: "world",
                    detail: format!("{package} ({scale})"),
                }],
            });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp_repo(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-sourcing-resolver-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("src")).unwrap();
        dir
    }

    fn empty_arsenal(dir: &Path) -> std::path::PathBuf {
        let path = dir.join("arsenal.json");
        fs::write(&path, r#"{"primitives_index":{},"repos_by_name":{}}"#).unwrap();
        path
    }

    /// AC3: a capability that exists in THIS repo (defined + referenced
    /// elsewhere) resolves to DONE-HERE with a file:line receipt.
    #[test]
    fn repo_tier_done_here_when_defined_and_referenced() {
        let dir = tmp_repo("done-here");
        fs::write(
            dir.join("src/widget_frobnicator.rs"),
            "pub fn widget_frobnicator() -> bool { true }\n",
        )
        .unwrap();
        fs::write(
            dir.join("src/caller.rs"),
            "fn use_it() { let _ = crate::widget_frobnicator::widget_frobnicator(); }\n",
        )
        .unwrap();
        let arsenal = empty_arsenal(&dir);

        let res = resolve_sourcing("widget frobnicator", &dir, &arsenal);
        assert_eq!(res.verdict, SourcingVerdict::DoneHere);
        assert_eq!(res.receipts[0].tier, "repo");
        assert!(res.receipts[0].detail.contains("widget_frobnicator.rs"));

        let _ = fs::remove_dir_all(&dir);
    }

    /// AC1/AC3: a capability defined but never referenced elsewhere resolves
    /// to HALF-DONE-HERE — the built-but-not-wired discovery-scan failure class.
    #[test]
    fn repo_tier_half_done_here_when_defined_but_unreferenced() {
        let dir = tmp_repo("half-done");
        fs::write(
            dir.join("src/gizmo_polisher.rs"),
            "pub fn gizmo_polisher() -> bool { true }\n",
        )
        .unwrap();
        let arsenal = empty_arsenal(&dir);

        let res = resolve_sourcing("gizmo polisher", &dir, &arsenal);
        assert_eq!(res.verdict, SourcingVerdict::HalfDoneHere);

        let _ = fs::remove_dir_all(&dir);
    }

    /// AC1/AC3: a capability absent from this repo but present in the arsenal
    /// catalog resolves to EXISTS-IN-ARSENAL with a repo receipt.
    #[test]
    fn arsenal_tier_hit_when_repo_absent() {
        let dir = tmp_repo("arsenal-hit");
        let arsenal_path = dir.join("arsenal.json");
        fs::write(
            &arsenal_path,
            r#"{"primitives_index":{"marketplace":["BEAST-MODE","economy-system-service"]},"repos_by_name":{}}"#,
        )
        .unwrap();

        let res = resolve_sourcing("marketplace", &dir, &arsenal_path);
        assert_eq!(res.verdict, SourcingVerdict::ExistsInArsenal);
        assert!(res.receipts[0].detail.contains("BEAST-MODE"));

        let _ = fs::remove_dir_all(&dir);
    }

    /// AC1/AC3: a well-known commodity capability absent from repo+arsenal
    /// resolves to EXISTS-IN-WORLD with a package receipt.
    #[test]
    fn world_tier_hit_for_well_known_capability() {
        let dir = tmp_repo("world-hit");
        let arsenal = empty_arsenal(&dir);

        let res = resolve_sourcing("resilience", &dir, &arsenal);
        assert_eq!(res.verdict, SourcingVerdict::ExistsInWorld);
        assert!(res.receipts[0].detail.contains("cockatiel"));

        let _ = fs::remove_dir_all(&dir);
    }

    /// AC3: a genuinely novel capability (absent from all three tiers)
    /// resolves to NOT-FOUND.
    #[test]
    fn not_found_for_genuinely_novel_capability() {
        let dir = tmp_repo("novel");
        let arsenal = empty_arsenal(&dir);

        let res = resolve_sourcing("zzyzx quantum flibbertigibbet transponder", &dir, &arsenal);
        assert_eq!(res.verdict, SourcingVerdict::NotFound);
        assert!(res.receipts.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_keyword_is_not_found() {
        let dir = tmp_repo("empty-kw");
        let arsenal = empty_arsenal(&dir);
        let res = resolve_sourcing("   ", &dir, &arsenal);
        assert_eq!(res.verdict, SourcingVerdict::NotFound);
        let _ = fs::remove_dir_all(&dir);
    }
}
