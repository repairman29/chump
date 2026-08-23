//! INFRA-3663: Promotion-decider — recurrence-counted capability-promotion
//! loop (advisory v0).
//!
//! `docs/process/VOICE_OF_AGENT.md` names an "auto-promote rule": when >= 3
//! VOA (Voice-of-Agent friction report) gaps with the same `wedge_class` land
//! within 30 days, that recurring wedge is a signal the underlying capability
//! gap deserves priority attention. That rule was documented but never
//! implemented — no code ever counted recurrence or emitted the promised
//! `kind=voice_of_agent_promoted` event. This module is v0 of that loop:
//! **advisory only** — it recommends promotion candidates and emits the
//! ambient event, but does not itself mutate gap priority (that's a follow-up
//! once the advisory signal has been observed in the wild).
//!
//! Core logic (`decide_promotions`) is pure and unit-tested independent of
//! the filesystem; `parse_voa_yaml_dir` + `run` wire it to
//! `docs/gaps/VOA-*.yaml` and `.chump-locks/ambient.jsonl`.

use chrono::{DateTime, Utc};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// One filed Voice-of-Agent report, reduced to the fields the
/// recurrence-count decision needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoaRecord {
    pub gap_id: String,
    pub wedge_class: String,
    pub filed_at: DateTime<Utc>,
}

/// A wedge_class that has recurred often enough, within the window, to be
/// advisory-flagged for promotion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromotionCandidate {
    pub wedge_class: String,
    pub count: usize,
    pub gap_ids: Vec<String>,
}

/// Recurrence-count decision: group `records` by `wedge_class`, keep only
/// records filed within `window_days` of `now`, and flag any wedge_class
/// that recurred `>= threshold` times as a promotion candidate.
///
/// Pure function — no I/O, fully deterministic given its inputs, so it is
/// unit-testable without touching the filesystem or the clock.
pub fn decide_promotions(
    records: &[VoaRecord],
    now: DateTime<Utc>,
    window_days: i64,
    threshold: usize,
) -> Vec<PromotionCandidate> {
    let cutoff = now - chrono::Duration::days(window_days);

    let mut by_class: BTreeMap<&str, Vec<&VoaRecord>> = BTreeMap::new();
    for rec in records {
        if rec.filed_at >= cutoff && rec.filed_at <= now {
            by_class
                .entry(rec.wedge_class.as_str())
                .or_default()
                .push(rec);
        }
    }

    let mut candidates: Vec<PromotionCandidate> = by_class
        .into_iter()
        .filter(|(_, recs)| recs.len() >= threshold)
        .map(|(wedge_class, recs)| {
            let mut gap_ids: Vec<String> = recs.iter().map(|r| r.gap_id.clone()).collect();
            gap_ids.sort();
            PromotionCandidate {
                wedge_class: wedge_class.to_string(),
                count: recs.len(),
                gap_ids,
            }
        })
        .collect();

    // Deterministic ordering for CLI/test output: highest recurrence first,
    // wedge_class alphabetical as a tiebreak.
    candidates.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.wedge_class.cmp(&b.wedge_class))
    });
    candidates
}

/// Parse `docs/gaps/VOA-*.yaml` into `VoaRecord`s.
///
/// Each file is a one-element YAML sequence (matching the rest of the gap
/// registry's on-disk format). The wedge_class and filed timestamp are read
/// out of the freeform `notes` field written by `chump voice`
/// (`src/commands/voice.rs::write_gap_entry`), since that is the only place
/// those two facts are recorded per-file: `notes` starts with
/// `[<rfc3339 ts>] Auto-filed ...` and contains a `Wedge class: <class>` line.
/// Files without both markers are skipped (not every VOA-*.yaml necessarily
/// came from the automated filer — e.g. hand-edited entries).
pub fn parse_voa_yaml_dir(gaps_dir: &Path) -> Vec<VoaRecord> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(gaps_dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let is_voa = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("VOA-") && n.ends_with(".yaml"))
            .unwrap_or(false);
        if !is_voa {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(rec) = parse_voa_yaml_str(&text) {
            out.push(rec);
        }
    }
    out
}

fn parse_voa_yaml_str(text: &str) -> Option<VoaRecord> {
    let gap_id = text
        .lines()
        .find_map(|l| l.trim_start().strip_prefix("id:"))
        .map(|s| s.trim().trim_matches('"').to_string())?;

    let notes_idx = text.find("notes:")?;
    let notes = &text[notes_idx..];

    let wedge_class = notes
        .lines()
        .find_map(|l| l.trim().strip_prefix("Wedge class:"))
        .map(|s| s.trim().to_string())?;

    // `[2026-08-15T19:31:01Z] Auto-filed ...` — first bracketed token on the
    // first non-empty line of the notes block.
    let filed_at = notes
        .lines()
        .find_map(|l| {
            let l = l.trim();
            let inner = l.strip_prefix('[')?;
            let (ts, _rest) = inner.split_once(']')?;
            DateTime::parse_from_rfc3339(ts)
                .ok()
                .map(|dt| dt.with_timezone(&Utc))
        })
        .or_else(|| {
            notes.lines().find_map(|l| {
                let l = l.trim().trim_start_matches('|').trim();
                let inner = l.strip_prefix('[')?;
                let (ts, _rest) = inner.split_once(']')?;
                DateTime::parse_from_rfc3339(ts)
                    .ok()
                    .map(|dt| dt.with_timezone(&Utc))
            })
        })?;

    Some(VoaRecord {
        gap_id,
        wedge_class,
        filed_at,
    })
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out
}

/// Emit one `kind=voice_of_agent_promoted` ambient event per candidate
/// (advisory v0: recommend only, never mutates gap priority/state.db).
pub fn emit_promotion_events(
    ambient_path: &Path,
    candidates: &[PromotionCandidate],
) -> std::io::Result<()> {
    if candidates.is_empty() {
        return Ok(());
    }
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(ambient_path)?;
    let ts = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    for c in candidates {
        let gap_ids_json = c
            .gap_ids
            .iter()
            .map(|g| format!("\"{}\"", json_escape(g)))
            .collect::<Vec<_>>()
            .join(",");
        writeln!(
            f,
            r#"{{"ts":"{ts}","kind":"voice_of_agent_promoted","wedge_class":"{}","count":{},"gap_ids":[{gap_ids_json}]}}"#,
            json_escape(&c.wedge_class),
            c.count,
        )?;
    }
    Ok(())
}

/// `chump promotion-decider [--gaps-dir <path>] [--ambient <path>]
/// [--window-days N] [--threshold N] [--json] [--no-emit]`
///
/// Advisory v0: reads filed VOA reports, applies the recurrence-count
/// decision, prints candidates, and (unless `--no-emit`) appends one
/// `kind=voice_of_agent_promoted` event per candidate to ambient.jsonl.
/// Never touches the gap registry or state.db.
pub fn run(args: &[String]) -> i32 {
    let mut gaps_dir = PathBuf::from("docs/gaps");
    let mut ambient_path = PathBuf::from(".chump-locks/ambient.jsonl");
    let mut window_days: i64 = 30;
    let mut threshold: usize = 3;
    let mut json_out = false;
    let mut no_emit = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gaps-dir" => {
                i += 1;
                if i < args.len() {
                    gaps_dir = PathBuf::from(&args[i]);
                }
            }
            "--ambient" => {
                i += 1;
                if i < args.len() {
                    ambient_path = PathBuf::from(&args[i]);
                }
            }
            "--window-days" => {
                i += 1;
                if i < args.len() {
                    window_days = args[i].parse().unwrap_or(30);
                }
            }
            "--threshold" => {
                i += 1;
                if i < args.len() {
                    threshold = args[i].parse().unwrap_or(3);
                }
            }
            "--json" => json_out = true,
            "--no-emit" => no_emit = true,
            _ => {}
        }
        i += 1;
    }

    let records = parse_voa_yaml_dir(&gaps_dir);
    let candidates = decide_promotions(&records, Utc::now(), window_days, threshold);

    if json_out {
        let items = candidates
            .iter()
            .map(|c| {
                let gap_ids_json = c
                    .gap_ids
                    .iter()
                    .map(|g| format!("\"{}\"", json_escape(g)))
                    .collect::<Vec<_>>()
                    .join(",");
                format!(
                    r#"{{"wedge_class":"{}","count":{},"gap_ids":[{gap_ids_json}]}}"#,
                    json_escape(&c.wedge_class),
                    c.count,
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        println!("[{items}]");
    } else if candidates.is_empty() {
        println!(
            "[promotion-decider] no wedge_class recurred >= {threshold} times in the last {window_days}d ({} VOA record(s) scanned)",
            records.len()
        );
    } else {
        for c in &candidates {
            println!(
                "[promotion-decider] PROMOTE-CANDIDATE wedge_class={} count={} gap_ids={}",
                c.wedge_class,
                c.count,
                c.gap_ids.join(",")
            );
        }
    }

    if !no_emit {
        if let Err(e) = emit_promotion_events(&ambient_path, &candidates) {
            eprintln!("[promotion-decider] warning: failed to emit ambient event: {e}");
        }
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn rec(gap_id: &str, wedge_class: &str, filed_at: &str) -> VoaRecord {
        VoaRecord {
            gap_id: gap_id.to_string(),
            wedge_class: wedge_class.to_string(),
            filed_at: ts(filed_at),
        }
    }

    #[test]
    fn below_threshold_is_not_promoted() {
        let records = vec![
            rec("VOA-001", "broken-daemon-exit", "2026-08-01T00:00:00Z"),
            rec("VOA-002", "broken-daemon-exit", "2026-08-05T00:00:00Z"),
        ];
        let now = ts("2026-08-15T00:00:00Z");
        let out = decide_promotions(&records, now, 30, 3);
        assert!(
            out.is_empty(),
            "2 recurrences must not clear a threshold of 3"
        );
    }

    #[test]
    fn at_threshold_is_promoted() {
        let records = vec![
            rec("VOA-001", "broken-daemon-exit", "2026-08-01T00:00:00Z"),
            rec("VOA-002", "broken-daemon-exit", "2026-08-05T00:00:00Z"),
            rec("VOA-003", "broken-daemon-exit", "2026-08-10T00:00:00Z"),
        ];
        let now = ts("2026-08-15T00:00:00Z");
        let out = decide_promotions(&records, now, 30, 3);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].wedge_class, "broken-daemon-exit");
        assert_eq!(out[0].count, 3);
        assert_eq!(out[0].gap_ids, vec!["VOA-001", "VOA-002", "VOA-003"]);
    }

    #[test]
    fn records_outside_window_do_not_count() {
        let records = vec![
            rec(
                "VOA-001",
                "oauth_refresh_daemon_broken",
                "2026-06-01T00:00:00Z",
            ), // > 30d before now
            rec(
                "VOA-002",
                "oauth_refresh_daemon_broken",
                "2026-08-05T00:00:00Z",
            ),
            rec(
                "VOA-003",
                "oauth_refresh_daemon_broken",
                "2026-08-10T00:00:00Z",
            ),
        ];
        let now = ts("2026-08-15T00:00:00Z");
        let out = decide_promotions(&records, now, 30, 3);
        assert!(
            out.is_empty(),
            "an out-of-window record must not count toward recurrence"
        );
    }

    #[test]
    fn different_wedge_classes_do_not_merge() {
        let records = vec![
            rec("VOA-001", "class-a", "2026-08-01T00:00:00Z"),
            rec("VOA-002", "class-b", "2026-08-02T00:00:00Z"),
            rec("VOA-003", "class-a", "2026-08-03T00:00:00Z"),
        ];
        let now = ts("2026-08-15T00:00:00Z");
        let out = decide_promotions(&records, now, 30, 2);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].wedge_class, "class-a");
        assert_eq!(out[0].count, 2);
    }

    #[test]
    fn candidates_sorted_by_count_desc_then_alpha() {
        let records = vec![
            rec("VOA-001", "z-class", "2026-08-01T00:00:00Z"),
            rec("VOA-002", "z-class", "2026-08-02T00:00:00Z"),
            rec("VOA-003", "a-class", "2026-08-01T00:00:00Z"),
            rec("VOA-004", "a-class", "2026-08-02T00:00:00Z"),
            rec("VOA-005", "a-class", "2026-08-03T00:00:00Z"),
        ];
        let now = ts("2026-08-15T00:00:00Z");
        let out = decide_promotions(&records, now, 30, 2);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].wedge_class, "a-class");
        assert_eq!(out[0].count, 3);
        assert_eq!(out[1].wedge_class, "z-class");
        assert_eq!(out[1].count, 2);
    }

    #[test]
    fn parses_voa_yaml_notes_block() {
        let yaml = r#"- id: VOA-009
  domain: VOA
  title: "VOICE-OF-AGENT VOA-009: broken-daemon-exit — 10 min lost; fix-shape: gate"
  status: open
  priority: P3
  effort: xs
  acceptance_criteria:
    - Full friction report at docs/voice/VOA-009-FULL.yaml with wedge_class=broken-daemon-exit, minutes_lost=10
  notes: |
    [2026-08-15T19:31:01Z] Auto-filed by `chump voice` (INFRA-2258).
    Wedge class: broken-daemon-exit
    Minutes lost: 10
    Evidence:
    - "fleet-doctor-strict.sh"
    See docs/voice/VOA-009-FULL.yaml for full report.
"#;
        let rec = parse_voa_yaml_str(yaml).expect("should parse");
        assert_eq!(rec.gap_id, "VOA-009");
        assert_eq!(rec.wedge_class, "broken-daemon-exit");
        assert_eq!(rec.filed_at, ts("2026-08-15T19:31:01Z"));
    }

    #[test]
    fn skips_files_missing_wedge_class_marker() {
        let yaml = r#"- id: VOA-999
  domain: VOA
  title: "hand-edited entry"
  status: open
  notes: |
    no wedge class marker here.
"#;
        assert!(parse_voa_yaml_str(yaml).is_none());
    }

    #[test]
    fn emit_promotion_events_writes_one_line_per_candidate() {
        let dir =
            std::env::temp_dir().join(format!("promotion-decider-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ambient_path = dir.join("ambient.jsonl");
        let _ = std::fs::remove_file(&ambient_path);

        let candidates = vec![PromotionCandidate {
            wedge_class: "broken-daemon-exit".to_string(),
            count: 3,
            gap_ids: vec![
                "VOA-001".to_string(),
                "VOA-002".to_string(),
                "VOA-003".to_string(),
            ],
        }];
        emit_promotion_events(&ambient_path, &candidates).unwrap();

        let contents = std::fs::read_to_string(&ambient_path).unwrap();
        assert_eq!(contents.lines().count(), 1);
        assert!(contents.contains("\"kind\":\"voice_of_agent_promoted\""));
        assert!(contents.contains("\"wedge_class\":\"broken-daemon-exit\""));
        assert!(contents.contains("\"count\":3"));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
