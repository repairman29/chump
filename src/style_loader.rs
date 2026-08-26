//! EFFECTIVE-484 (EFFECTIVE-365 slice): loads Jeff's voice rules from
//! `content/STYLE.md` and applies them to draft text before it ships.
//! See `org/RUN/publication/roles/publisher.md` for the publication chair
//! this feeds ("draft in the captain's voice").
//!
//! STYLE.md sections (exact header text, parsed literally):
//!   `## Substitutions`                  - "find" => "replace" (pulls text into first person)
//!   `## Banned growth-hack phrases`     - phrases stripped entirely
//!   `## Banned unearned-claim phrases`  - phrases stripped entirely

use anyhow::{Context, Result};
use std::path::Path;

#[derive(Debug, Default, Clone)]
pub struct StyleGuide {
    pub substitutions: Vec<(String, String)>,
    pub banned_growth_hack: Vec<String>,
    pub banned_unearned_claims: Vec<String>,
}

enum Section {
    None,
    Substitutions,
    GrowthHack,
    UnearnedClaims,
}

impl StyleGuide {
    pub fn load(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("reading style guide at {}", path.display()))?;
        Ok(Self::parse(&content))
    }

    pub fn parse(content: &str) -> Self {
        let mut guide = StyleGuide::default();
        let mut section = Section::None;
        for line in content.lines() {
            let trimmed = line.trim();
            if let Some(header) = trimmed.strip_prefix("## ") {
                section = match header.trim() {
                    "Substitutions" => Section::Substitutions,
                    "Banned growth-hack phrases" => Section::GrowthHack,
                    "Banned unearned-claim phrases" => Section::UnearnedClaims,
                    _ => Section::None,
                };
                continue;
            }
            let Some(item) = trimmed.strip_prefix("- ") else {
                continue;
            };
            match section {
                Section::Substitutions => {
                    if let Some((find, replace)) = parse_substitution(item) {
                        guide.substitutions.push((find, replace));
                    }
                }
                Section::GrowthHack => guide.banned_growth_hack.push(item.trim().to_string()),
                Section::UnearnedClaims => {
                    guide.banned_unearned_claims.push(item.trim().to_string())
                }
                Section::None => {}
            }
        }
        guide
    }

    /// Applies first-person substitutions, then strips banned phrases.
    /// Matching is case-insensitive throughout; whitespace left behind by
    /// stripped phrases is collapsed in the output.
    pub fn apply(&self, draft: &str) -> String {
        let mut text = draft.to_string();
        for (find, replace) in &self.substitutions {
            text = replace_case_insensitive(&text, find, replace);
        }
        for phrase in self
            .banned_growth_hack
            .iter()
            .chain(&self.banned_unearned_claims)
        {
            text = replace_case_insensitive(&text, phrase, "");
        }
        collapse_whitespace(&text)
    }
}

fn parse_substitution(item: &str) -> Option<(String, String)> {
    let (find, replace) = item.split_once("=>")?;
    let find = find.trim().trim_matches('"').to_string();
    let replace = replace.trim().trim_matches('"').to_string();
    if find.is_empty() {
        return None;
    }
    Some((find, replace))
}

fn replace_case_insensitive(text: &str, find: &str, replace: &str) -> String {
    if find.is_empty() {
        return text.to_string();
    }
    let lower_text = text.to_lowercase();
    let lower_find = find.to_lowercase();
    let mut result = String::new();
    let mut last = 0;
    let mut idx = 0;
    while let Some(pos) = lower_text[idx..].find(&lower_find) {
        let start = idx + pos;
        let end = start + find.len();
        result.push_str(&text[last..start]);
        result.push_str(replace);
        last = end;
        idx = end;
    }
    result.push_str(&text[last..]);
    result
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace(" .", ".")
        .replace(" ,", ",")
}

// ─────────────────────────── assertions ───────────────────────────

/// AC2: output uses first person ("I"/"we") and no distancing third-person markers.
pub fn assert_first_person(text: &str) -> bool {
    let lower = text.to_lowercase();
    let has_first_person = lower.split_whitespace().any(|w| {
        let w = w.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'');
        matches!(w, "i" | "we" | "i'm" | "i've" | "we're" | "we've")
    });
    let has_distancing = lower.contains("the team") || lower.contains("one might");
    has_first_person && !has_distancing
}

/// AC2: no unearned-claim phrase survived in the text.
pub fn assert_honest_receipts(text: &str, guide: &StyleGuide) -> bool {
    let lower = text.to_lowercase();
    !guide
        .banned_unearned_claims
        .iter()
        .any(|p| lower.contains(&p.to_lowercase()))
}

/// AC2: no growth-hack phrase survived in the text.
pub fn assert_no_growth_hack(text: &str, guide: &StyleGuide) -> bool {
    let lower = text.to_lowercase();
    !guide
        .banned_growth_hack
        .iter()
        .any(|p| lower.contains(&p.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_STYLE: &str = r#"# Sample STYLE.md

## Substitutions

- "the team" => "I"
- "users will" => "you'll"

## Banned growth-hack phrases

- game-changing
- 10x

## Banned unearned-claim phrases

- guaranteed
- 100% proven
"#;

    #[test]
    fn parses_style_sections() {
        let guide = StyleGuide::parse(SAMPLE_STYLE);
        assert_eq!(guide.substitutions.len(), 2);
        assert_eq!(guide.banned_growth_hack, vec!["game-changing", "10x"]);
        assert_eq!(
            guide.banned_unearned_claims,
            vec!["guaranteed", "100% proven"]
        );
    }

    #[test]
    fn applies_rules_and_passes_assertions() {
        let guide = StyleGuide::parse(SAMPLE_STYLE);
        let draft = "The team shipped a game-changing, 10x, guaranteed and 100% proven release. Users will love it.";
        let out = guide.apply(draft);

        assert!(
            assert_first_person(&out),
            "expected first person, got: {out}"
        );
        assert!(
            assert_honest_receipts(&out, &guide),
            "unearned claim survived: {out}"
        );
        assert!(
            assert_no_growth_hack(&out, &guide),
            "growth-hack phrase survived: {out}"
        );
    }

    #[test]
    fn fails_assertions_on_unstyled_draft() {
        let guide = StyleGuide::parse(SAMPLE_STYLE);
        let draft = "The team shipped a game-changing, guaranteed release.";
        assert!(!assert_first_person(draft));
        assert!(!assert_honest_receipts(draft, &guide));
        assert!(!assert_no_growth_hack(draft, &guide));
    }

    #[test]
    fn load_reads_real_content_style_md() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("content/STYLE.md");
        let guide = StyleGuide::load(&path).expect("content/STYLE.md must exist and parse");
        assert!(!guide.banned_growth_hack.is_empty());
        assert!(!guide.substitutions.is_empty());
    }
}
