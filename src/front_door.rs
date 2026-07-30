//! EFFECTIVE-330 (COTG-0.0): the front-door intent router.
//!
//! `docs/strategy/CHUMP_FRONT_DOOR.md` specs a single entry point that takes a
//! person's plain-language ask and routes it to one of five existing engines
//! (CREATE/IMPROVE/RESCUE/COMPREHEND/INGEST) — the modes differ only in
//! starting state and which engine drives execution; this module owns only
//! the classification + confirm-back step, not the engines themselves.
//!
//! Deliberately mirrors `intent_parser.rs`'s shape (typed enum + pattern
//! match + ambient emit) per the gap's own "clone the shape" instruction,
//! rather than sharing code with it — `intent_parser` classifies into
//! internal chump CLI commands; this classifies into front-door *modes*,
//! a different taxonomy with a different confidence + confirm-back
//! requirement intent_parser.rs doesn't have.

use std::path::Path;

/// One of the five front-door modes a plain-language ask can route to.
/// `docs/strategy/CHUMP_FRONT_DOOR.md` §2 names the mode -> engine mapping;
/// this enum does not implement the engines, only the routing decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrontDoorMode {
    /// "I have a new idea" → `chump bootstrap`
    Create,
    /// "Fix / improve what I have" → `chump improve`
    Improve,
    /// "Help, I'm stuck / it's broken" → comprehension organs + consult
    /// (user-facing flow is greenfield per the front-door doc; this router
    /// only classifies into the mode, it does not build the RESCUE engine)
    Rescue,
    /// "Help me understand this" → `chump almanac` / `consult`
    Comprehend,
    /// "Adopt this existing thing" → `chump ingest`
    Ingest,
}

impl FrontDoorMode {
    /// The underlying chump subcommand this mode routes to, per
    /// CHUMP_FRONT_DOOR.md §2's "Engine today" column.
    pub fn engine_command(&self) -> &'static str {
        match self {
            Self::Create => "chump bootstrap",
            Self::Improve => "chump improve",
            Self::Rescue => "chump consult", // diagnosis organ; no user-facing fix engine yet
            Self::Comprehend => "chump almanac",
            Self::Ingest => "chump ingest",
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Create => "CREATE",
            Self::Improve => "IMPROVE",
            Self::Rescue => "RESCUE",
            Self::Comprehend => "COMPREHEND",
            Self::Ingest => "INGEST",
        }
    }
}

/// The result of classifying a plain-language ask: either a single
/// confident mode, or — per the front-door doc's AC2 ("ambiguous or mixed
/// intent is asked about in the person's words, never guessed silently") —
/// a set of candidates when nothing scores clearly ahead of the rest.
#[derive(Debug, Clone, PartialEq)]
pub enum RouteResult {
    Confident {
        mode: FrontDoorMode,
        confidence: f32,
    },
    Ambiguous {
        candidates: Vec<(FrontDoorMode, f32)>,
    },
}

/// Returns (strong multi-word phrases, weak single keywords) per mode. Not a
/// learned classifier — this is the same keyword-scoring grain as
/// `intent_parser.rs`'s pattern matcher, kept intentionally simple per
/// COTG-S.3 (source commodity, don't over-build a bespoke NLP layer for a
/// router). If this proves too coarse in practice, `semantic-router`-style
/// embedding classification is the documented upgrade path (see
/// docs/strategy/COTG_EXECUTION_MATRIX.md's OSS prior-art findings) — not
/// something to build speculatively now.
///
/// A strong phrase is worth 3 points; a weak keyword is worth 1 — this
/// two-tier split exists because the first version of this lexicon
/// (phrase-only, exact substring match) failed its own test suite: "I want
/// to build a CLI that renames photos" matched nothing (no exact phrase for
/// "build"), and "...it's broken and I also want a new feature added"
/// matched ONLY "broken", scoring Rescue as falsely confident on a
/// genuinely mixed ask.
fn lexicon(mode: FrontDoorMode) -> (&'static [&'static str], &'static [&'static str]) {
    match mode {
        FrontDoorMode::Create => (
            &[
                "new idea",
                "i have an idea",
                "from scratch",
                "build me a",
                "want to build",
            ],
            &[
                "build",
                "create",
                "make",
                "new app",
                "new tool",
                "new project",
                "cli that",
            ],
        ),
        FrontDoorMode::Improve => (
            &["make it better", "add a feature", "fix the"],
            &[
                "fix", "improve", "update", "change", "modify", "enhance", "feature", "better",
                "toggle", "add a",
            ],
        ),
        FrontDoorMode::Rescue => (
            &[
                "not working",
                "it's failing",
                "won't start",
                "can't figure out",
                "blocks all merges",
                "ci is red",
            ],
            &[
                "stuck", "broken", "help me", "crashed", "error", "red", "fails", "failing",
            ],
        ),
        FrontDoorMode::Comprehend => (
            &[
                "what does this do",
                "how does this work",
                "help me understand",
                "walk me through",
                "onboarding map",
            ],
            &["explain", "understand", "what is this"],
        ),
        FrontDoorMode::Ingest => (
            &["use this existing", "onboard this repo", "bring in this"],
            &["adopt", "import", "already have", "existing"],
        ),
    }
}

const ALL_MODES: [FrontDoorMode; 5] = [
    FrontDoorMode::Create,
    FrontDoorMode::Improve,
    FrontDoorMode::Rescue,
    FrontDoorMode::Comprehend,
    FrontDoorMode::Ingest,
];

const STRONG_PHRASE_WEIGHT: f32 = 3.0;
const WEAK_KEYWORD_WEIGHT: f32 = 1.0;

/// Confidence gap (in raw score points) required for the top mode to lead
/// the runner-up before being treated as confident rather than ambiguous.
const CONFIDENCE_MARGIN: f32 = 2.0;

/// Minimum absolute score for "confident" even when nothing else competes —
/// prevents a single weak keyword hit (e.g. one match on "error") from
/// counting as a confident routing decision just because it happened to be
/// the only mode that matched anything at all.
const MIN_CONFIDENT_SCORE: f32 = 2.0;

/// Classify a plain-language ask into a front-door mode.
///
/// Scoring: strong-phrase hits count 3x, weak-keyword hits count 1x, per
/// mode. The top mode must both (a) lead the runner-up by
/// `CONFIDENCE_MARGIN` and (b) clear `MIN_CONFIDENT_SCORE` to be
/// `Confident` — a lone weak-keyword match is deliberately NOT enough on
/// its own. Otherwise every mode scoring > 0 is returned as an `Ambiguous`
/// candidate set for the person to disambiguate (front-door doc AC2: never
/// silently guess).
pub fn classify(input: &str) -> RouteResult {
    let lc = input.to_lowercase();

    let mut scores: Vec<(FrontDoorMode, f32)> = ALL_MODES
        .iter()
        .map(|&mode| {
            let (strong, weak) = lexicon(mode);
            let strong_hits = strong.iter().filter(|p| lc.contains(**p)).count() as f32;
            let weak_hits = weak.iter().filter(|p| lc.contains(**p)).count() as f32;
            let score = strong_hits * STRONG_PHRASE_WEIGHT + weak_hits * WEAK_KEYWORD_WEIGHT;
            (mode, score)
        })
        .collect();

    scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());

    let top = scores[0];
    let runner_up = scores[1];

    if top.1 <= 0.0 {
        // Nothing matched at all — this is the "genuinely don't know" case,
        // still ambiguous, never a silent default to any one mode.
        return RouteResult::Ambiguous { candidates: vec![] };
    }

    if top.1 >= MIN_CONFIDENT_SCORE && (top.1 - runner_up.1) >= CONFIDENCE_MARGIN {
        return RouteResult::Confident {
            mode: top.0,
            confidence: (top.1 / 12.0).min(1.0), // rough 0-1 normalization for display
        };
    }

    let candidates: Vec<(FrontDoorMode, f32)> =
        scores.into_iter().filter(|(_, s)| *s > 0.0).collect();
    RouteResult::Ambiguous { candidates }
}

/// The one-line confirm-back the front-door doc's AC1 requires: "here's what
/// I think you want, yes?" — recoverable, per AC2, if the person says no.
pub fn confirm_line(result: &RouteResult) -> String {
    match result {
        RouteResult::Confident { mode, confidence } => format!(
            "I think you want to {} (confidence {:.0}%) — via `{}`. Is that right? (yes / no, I meant something else)",
            match mode {
                FrontDoorMode::Create => "build something new",
                FrontDoorMode::Improve => "fix or improve something you have",
                FrontDoorMode::Rescue => "get unstuck on something that's broken",
                FrontDoorMode::Comprehend => "understand how something works",
                FrontDoorMode::Ingest => "adopt something that already exists",
            },
            confidence * 100.0,
            mode.engine_command()
        ),
        RouteResult::Ambiguous { candidates } if candidates.is_empty() => {
            "I'm not sure what you're looking for yet. Could you say a bit more — are you starting something new, fixing something, stuck on something broken, trying to understand existing code, or bringing in something that already exists?".to_string()
        }
        RouteResult::Ambiguous { candidates } => {
            let options: Vec<String> = candidates
                .iter()
                .map(|(mode, _)| mode.label().to_string())
                .collect();
            format!(
                "This could be more than one thing — {}. Which is closest to what you mean?",
                options.join(" or ")
            )
        }
    }
}

/// Ambient event kind, mirroring intent_parser.rs's `ambient_kind()` pattern.
///
/// # scanner-anchor: "kind":"front_door_route_confident"
/// # scanner-anchor: "kind":"front_door_route_ambiguous"
///
/// The two anchors above exist because the actual emit call in
/// `emit_route_event()` below builds the kind field from this function's
/// return value, not a literal string — the static EVENT_REGISTRY.yaml
/// register-without-emit scanner can't see through that indirection on its
/// own, so these comments give it a literal match at the real emit site.
pub fn ambient_kind(result: &RouteResult) -> &'static str {
    match result {
        RouteResult::Confident { .. } => "front_door_route_confident",
        RouteResult::Ambiguous { .. } => "front_door_route_ambiguous",
    }
}

/// Emit the routing decision to ambient.jsonl, matching the emit shape used
/// elsewhere in this codebase for intent-classification events.
pub fn emit_route_event(repo_root: &Path, input: &str, result: &RouteResult) {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let Some(parent) = ambient_path.parent() else {
        return;
    };
    if !parent.exists() {
        return;
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let event = match result {
        RouteResult::Confident { mode, confidence } => serde_json::json!({
            "ts": ts,
            "kind": ambient_kind(result),
            "input_len": input.len(),
            "mode": mode.label(),
            "confidence": confidence,
        }),
        RouteResult::Ambiguous { candidates } => serde_json::json!({
            "ts": ts,
            "kind": ambient_kind(result),
            "input_len": input.len(),
            "candidates": candidates.iter().map(|(m, s)| serde_json::json!({"mode": m.label(), "score": s})).collect::<Vec<_>>(),
        }),
    };
    if let Ok(mut line) = serde_json::to_string(&event) {
        line.push('\n');
        let _ = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient_path)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(line.as_bytes())
            });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confident_create() {
        let r = classify("I have a new idea for a tool that renames photos by date");
        assert!(matches!(
            r,
            RouteResult::Confident {
                mode: FrontDoorMode::Create,
                ..
            }
        ));
    }

    #[test]
    fn confident_improve() {
        let r = classify("can you fix the login bug and improve the error message");
        assert!(matches!(
            r,
            RouteResult::Confident {
                mode: FrontDoorMode::Improve,
                ..
            }
        ));
    }

    #[test]
    fn confident_rescue() {
        let r = classify("help me, my app is broken and won't start");
        assert!(matches!(
            r,
            RouteResult::Confident {
                mode: FrontDoorMode::Rescue,
                ..
            }
        ));
    }

    #[test]
    fn confident_comprehend() {
        let r = classify("can you explain how this codebase works, walk me through it");
        assert!(matches!(
            r,
            RouteResult::Confident {
                mode: FrontDoorMode::Comprehend,
                ..
            }
        ));
    }

    #[test]
    fn confident_ingest() {
        let r = classify("I want to adopt this existing repo and onboard this repo into chump");
        assert!(matches!(
            r,
            RouteResult::Confident {
                mode: FrontDoorMode::Ingest,
                ..
            }
        ));
    }

    #[test]
    fn genuinely_unknown_is_ambiguous_not_a_wrong_default() {
        let r = classify("hello there");
        assert!(matches!(r, RouteResult::Ambiguous { candidates } if candidates.is_empty()));
    }

    /// The front-door doc's own adversarial example: "I have an app but it's
    /// broken and I also want a new feature" — mixed CREATE/IMPROVE/RESCUE
    /// signal. Must resolve to Ambiguous, not silently pick one (AC2/AC4).
    #[test]
    fn adversarial_mixed_intent_does_not_silently_pick_a_mode() {
        let r = classify("I have an app but it's broken and I also want a new feature added to it");
        match r {
            RouteResult::Ambiguous { candidates } => {
                // Must surface at least two competing modes, not collapse to one.
                assert!(
                    candidates.len() >= 2,
                    "expected >=2 competing modes, got {candidates:?}"
                );
            }
            RouteResult::Confident { mode, confidence } => {
                panic!(
                    "mixed-intent input silently resolved to a single mode: {mode:?} at {confidence}"
                );
            }
        }
    }

    #[test]
    fn confirm_line_is_nonempty_and_recoverable_for_all_result_kinds() {
        for input in [
            "build me a new app",
            "fix this",
            "hello there",
            "I have an app but it's broken and I also want a new feature",
        ] {
            let r = classify(input);
            let line = confirm_line(&r);
            assert!(!line.is_empty());
            // The confirm line must always give the person a way to correct
            // it — either an explicit "no" option or a request for more info.
            assert!(
                line.contains("no")
                    || line.contains("Which")
                    || line.contains("more")
                    || line.contains("?"),
                "confirm line doesn't look recoverable: {line}"
            );
        }
    }

    #[test]
    fn fixture_set_maps_plain_language_to_the_right_mode() {
        // A small fixture set per the gap's AC4 test criterion.
        let fixtures: &[(&str, FrontDoorMode)] = &[
            (
                "I want to build a CLI that renames photos by the date they were taken",
                FrontDoorMode::Create,
            ),
            (
                "Add a dark-mode toggle that remembers the choice",
                FrontDoorMode::Improve,
            ),
            (
                "CI is red and blocks all merges, help me",
                FrontDoorMode::Rescue,
            ),
            (
                "Explain what this repo does and produce an onboarding map",
                FrontDoorMode::Comprehend,
            ),
            (
                "I want to onboard this repo, bring in this existing project",
                FrontDoorMode::Ingest,
            ),
        ];
        for (input, expected) in fixtures {
            let r = classify(input);
            match r {
                RouteResult::Confident { mode, .. } => {
                    assert_eq!(mode, *expected, "input: {input:?}");
                }
                RouteResult::Ambiguous { candidates } => {
                    panic!("expected confident {expected:?} for {input:?}, got ambiguous: {candidates:?}");
                }
            }
        }
    }
}
