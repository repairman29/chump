//! Gap data model + YAML parsing.
//!
//! Real chump gap files are stored one-gap-per-file as a single-element YAML
//! sequence: `- id: INFRA-1021\n  domain: INFRA\n  ...`. Both inline
//! (`depends_on: [X, Y]`) and block-list forms are accepted.

use anyhow::{Context, Result};
use serde::{Deserialize, Deserializer, Serialize};
use std::fmt;
use std::path::Path;
use std::str::FromStr;

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize)]
pub struct GapId(pub String);

impl fmt::Display for GapId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // f.pad — not f.write_str — so `{:<14}` width specs are honored.
        f.pad(&self.0)
    }
}

impl From<&str> for GapId {
    fn from(s: &str) -> Self {
        GapId(s.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub enum Domain {
    Cog,
    Credible,
    Doc,
    Effective,
    Eval,
    Fleet,
    Infra,
    Meta,
    Product,
    Resilient,
    Smoke,
    Other,
}

impl Domain {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Cog => "COG",
            Self::Credible => "CREDIBLE",
            Self::Doc => "DOC",
            Self::Effective => "EFFECTIVE",
            Self::Eval => "EVAL",
            Self::Fleet => "FLEET",
            Self::Infra => "INFRA",
            Self::Meta => "META",
            Self::Product => "PRODUCT",
            Self::Resilient => "RESILIENT",
            Self::Smoke => "SMOKE",
            Self::Other => "OTHER",
        }
    }
}

impl FromStr for Domain {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self> {
        Ok(match s.to_ascii_uppercase().as_str() {
            "COG" => Self::Cog,
            "CREDIBLE" => Self::Credible,
            "DOC" => Self::Doc,
            "EFFECTIVE" => Self::Effective,
            "EVAL" => Self::Eval,
            "FLEET" => Self::Fleet,
            "INFRA" => Self::Infra,
            "META" => Self::Meta,
            "PRODUCT" => Self::Product,
            "RESILIENT" => Self::Resilient,
            "SMOKE" => Self::Smoke,
            // Tolerate unknown domains rather than refuse to parse the gap —
            // a missed score signal beats a missed gap.
            _ => Self::Other,
        })
    }
}

impl<'de> Deserialize<'de> for Domain {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::from_str(&s).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
pub enum Priority {
    P0,
    P1,
    P2,
    P3,
}

impl Priority {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::P0 => "P0",
            Self::P1 => "P1",
            Self::P2 => "P2",
            Self::P3 => "P3",
        }
    }
}

impl FromStr for Priority {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self> {
        Ok(match s.trim().to_ascii_uppercase().as_str() {
            "P0" => Self::P0,
            "P1" => Self::P1,
            "P2" => Self::P2,
            "P3" => Self::P3,
            other => anyhow::bail!("unknown priority {other}"),
        })
    }
}

impl<'de> Deserialize<'de> for Priority {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::from_str(&s).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
pub enum Effort {
    Xs,
    S,
    M,
    L,
    Xl,
}

impl Effort {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Xs => "xs",
            Self::S => "s",
            Self::M => "m",
            Self::L => "l",
            Self::Xl => "xl",
        }
    }

    /// INFRA-1281: rough cycle-time estimate in days, used by
    /// `DependencyGraph::critical_path_days` to weight longest-path
    /// computation. T-shirt sizing — operators can tune by editing this
    /// match arm; the picker (INFRA-1258) re-derives via this same source.
    pub fn days(&self) -> f32 {
        match self {
            Self::Xs => 0.5,
            Self::S => 1.0,
            Self::M => 3.0,
            Self::L => 8.0,
            Self::Xl => 21.0,
        }
    }
}

impl FromStr for Effort {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self> {
        Ok(match s.trim().to_ascii_lowercase().as_str() {
            "xs" => Self::Xs,
            "s" => Self::S,
            "m" => Self::M,
            "l" => Self::L,
            "xl" => Self::Xl,
            other => anyhow::bail!("unknown effort {other}"),
        })
    }
}

impl<'de> Deserialize<'de> for Effort {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::from_str(&s).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub enum Status {
    Open,
    Closed,
    Done,
}

impl Status {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Closed => "closed",
            Self::Done => "done",
        }
    }

    pub fn is_open(self) -> bool {
        matches!(self, Self::Open)
    }
}

impl FromStr for Status {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self> {
        Ok(match s.trim().to_ascii_lowercase().as_str() {
            "open" => Self::Open,
            "closed" => Self::Closed,
            "done" => Self::Done,
            other => anyhow::bail!("unknown status {other}"),
        })
    }
}

impl<'de> Deserialize<'de> for Status {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::from_str(&s).map_err(serde::de::Error::custom)
    }
}

/// Accept `acceptance_criteria` as a list of strings OR as a single scalar
/// string that we then split on numbered-list markers.
///
/// **INFRA-1265:** YAML treats this snippet as a *single multi-line scalar*,
/// not a block sequence, because the items lack `- ` prefixes:
/// ```yaml
/// acceptance_criteria:
///   1. First
///   2. Second
/// ```
/// serde_yaml gives us `"1. First 2. Second"`. The historic deserializer
/// rejected the type mismatch (`expected sequence, got string`) and the
/// whole gap was silently dropped from planner output. We now split the
/// scalar on the `\d+\.\s+` boundary and reconstruct the bullet list.
fn deserialize_acceptance_criteria<'de, D>(
    d: D,
) -> std::result::Result<Option<Vec<String>>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::Error;
    let v = serde_yaml::Value::deserialize(d)?;
    match v {
        serde_yaml::Value::Null => Ok(None),
        serde_yaml::Value::Sequence(seq) => {
            // Canonical bullet form — `- text`.
            let items: std::result::Result<Vec<String>, _> = seq
                .into_iter()
                .map(|item| match item {
                    serde_yaml::Value::String(s) => Ok(s),
                    // Numbers / booleans / nulls inside an AC list are
                    // unexpected but we render them rather than drop the gap.
                    other => serde_yaml::to_string(&other)
                        .map(|s| s.trim().to_string())
                        .map_err(|e| D::Error::custom(format!("ac stringify: {e}"))),
                })
                .collect();
            Ok(Some(items?))
        }
        serde_yaml::Value::String(s) => {
            // INFRA-1265 recovery path. Split on `<digits>. ` markers.
            let bullets = split_numbered_scalar(&s);
            if bullets.is_empty() {
                // Whole field was something like "TODO" — keep as single AC.
                Ok(Some(vec![s.trim().to_string()]))
            } else {
                Ok(Some(bullets))
            }
        }
        other => Err(D::Error::custom(format!(
            "acceptance_criteria must be list or string, got {other:?}"
        ))),
    }
}

/// Split a YAML-collapsed numbered-AC scalar back into its bullets.
/// Returns an empty vec if the scalar contains no numbered markers — the
/// caller decides whether to keep the original scalar as a single bullet.
fn split_numbered_scalar(s: &str) -> Vec<String> {
    use once_cell::sync::Lazy;
    use regex::Regex;
    // Marker: start-of-string OR whitespace, then digits, then `. ` and the
    // bullet text. We split, not match, so the first segment becomes the
    // pre-marker remainder (usually empty).
    static MARKER: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?:^|\s)(\d+)\.\s+").unwrap());
    if !MARKER.is_match(s) {
        return Vec::new();
    }
    let mut bullets: Vec<String> = Vec::new();
    let mut last_end = 0usize;
    let mut last_was_marker = false;
    for m in MARKER.find_iter(s) {
        if last_was_marker {
            let chunk = s[last_end..m.start()].trim();
            if !chunk.is_empty() {
                bullets.push(chunk.to_string());
            }
        }
        last_end = m.end();
        last_was_marker = true;
    }
    if last_was_marker {
        let chunk = s[last_end..].trim();
        if !chunk.is_empty() {
            bullets.push(chunk.to_string());
        }
    }
    bullets
}

/// Accept `depends_on` as a list, a single string, or a JSON-string-of-list
/// (the historic double-encoded import bug — CLAUDE.md flags it).
fn deserialize_depends_on<'de, D>(d: D) -> std::result::Result<Vec<GapId>, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::Error;
    let v = serde_yaml::Value::deserialize(d)?;
    match v {
        serde_yaml::Value::Null => Ok(Vec::new()),
        serde_yaml::Value::Sequence(seq) => seq
            .into_iter()
            .map(|item| match item {
                serde_yaml::Value::String(s) => Ok(GapId(s)),
                other => Err(D::Error::custom(format!(
                    "depends_on entry not a string: {other:?}"
                ))),
            })
            .collect(),
        serde_yaml::Value::String(s) => {
            // Maybe double-encoded JSON: "[\"A\",\"B\"]"
            let trimmed = s.trim();
            if trimmed.starts_with('[') {
                // YAML is a JSON superset; reuse serde_yaml so we avoid a
                // serde_json dependency just for this fallback.
                let parsed: Vec<String> = serde_yaml::from_str(trimmed)
                    .map_err(|e| D::Error::custom(format!("depends_on json-string parse: {e}")))?;
                Ok(parsed.into_iter().map(GapId).collect())
            } else {
                // Single bare id — tolerate
                Ok(vec![GapId(s)])
            }
        }
        other => Err(D::Error::custom(format!(
            "depends_on must be list or string, got {other:?}"
        ))),
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Gap {
    pub id: GapId,
    pub domain: Domain,
    pub title: String,
    pub status: Status,
    pub priority: Priority,
    pub effort: Effort,

    #[serde(default)]
    pub opened_date: Option<chrono::NaiveDate>,
    #[serde(default)]
    pub closed_date: Option<String>,
    #[serde(default)]
    pub closed_pr: Option<u64>,

    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, deserialize_with = "deserialize_acceptance_criteria")]
    pub acceptance_criteria: Option<Vec<String>>,

    #[serde(default, deserialize_with = "deserialize_depends_on")]
    pub depends_on: Vec<GapId>,
}

impl Gap {
    /// Concatenate every narrative field — notes + description + AC items —
    /// for free-text scanning (advisory SeeAlso extraction only).
    pub fn narrative(&self) -> String {
        let mut buf = String::new();
        if let Some(s) = &self.notes {
            buf.push_str(s);
            buf.push('\n');
        }
        if let Some(s) = &self.description {
            buf.push_str(s);
            buf.push('\n');
        }
        if let Some(ac) = &self.acceptance_criteria {
            for item in ac {
                buf.push_str(item);
                buf.push('\n');
            }
        }
        buf
    }

    /// Days since `opened_date`. Returns 0 when no opened_date is recorded —
    /// score should treat "unknown age" as fresh rather than ancient.
    pub fn days_open(&self, today: chrono::NaiveDate) -> i64 {
        match self.opened_date {
            Some(d) => (today - d).num_days().max(0),
            None => 0,
        }
    }
}

/// Load one gap yaml. Files are single-element sequences (`- id: …`).
pub fn load_file(path: &Path) -> Result<Gap> {
    let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    load_str(&text).with_context(|| format!("parse {}", path.display()))
}

pub fn load_str(text: &str) -> Result<Gap> {
    // Try single-element sequence first (the canonical chump format).
    if let Ok(mut seq) = serde_yaml::from_str::<Vec<Gap>>(text) {
        if let Some(gap) = seq.pop() {
            return Ok(gap);
        }
    }
    // Fall back to a top-level mapping for unit-test convenience.
    let gap: Gap = serde_yaml::from_str(text)?;
    Ok(gap)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_canonical_one_element_sequence() {
        let yaml = r#"
- id: INFRA-9999
  domain: INFRA
  title: test gap
  status: open
  priority: P1
  effort: s
  opened_date: '2026-05-13'
  depends_on:
    - INFRA-1
    - INFRA-2
"#;
        let g = load_str(yaml).unwrap();
        assert_eq!(g.id, GapId("INFRA-9999".into()));
        assert_eq!(g.priority, Priority::P1);
        assert_eq!(g.depends_on.len(), 2);
    }

    #[test]
    fn parses_inline_depends_on() {
        let yaml = r#"
- id: TEST-1
  domain: INFRA
  title: t
  status: open
  priority: P2
  effort: xs
  depends_on: [TEST-2, TEST-3]
"#;
        let g = load_str(yaml).unwrap();
        assert_eq!(g.depends_on.len(), 2);
    }

    #[test]
    fn tolerates_unknown_domain() {
        let yaml = r#"
- id: WAT-1
  domain: WHATEVER
  title: t
  status: open
  priority: P3
  effort: s
"#;
        let g = load_str(yaml).unwrap();
        assert_eq!(g.domain, Domain::Other);
    }

    #[test]
    fn parses_numbered_acceptance_criteria_no_description() {
        // INFRA-1265: when acceptance_criteria is written as a numbered list
        // (`1. text` / `2. text`) without a sibling description block, YAML
        // collapses the whole field into a single multi-line scalar string.
        // The planner used to silently drop the gap (deserialize failure) —
        // we now recover by splitting the scalar back into bullets.
        let yaml = r#"
- id: TEST-NUMBERED-1
  domain: INFRA
  title: test numbered AC
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    1. First AC item
    2. Second AC item
    3. Third AC item
"#;
        let g = load_str(yaml).expect("numbered-form AC must parse, not drop the gap");
        let ac = g
            .acceptance_criteria
            .expect("numbered-form AC must not collapse to None");
        assert_eq!(ac.len(), 3, "expected 3 AC bullets, got {ac:?}");
        assert_eq!(ac[0], "First AC item");
        assert_eq!(ac[1], "Second AC item");
        assert_eq!(ac[2], "Third AC item");
    }

    #[test]
    fn parses_numbered_acceptance_criteria_with_description() {
        // Coverage matrix (c): both description: and numbered AC present —
        // no regression in the bullet recovery path.
        let yaml = r#"
- id: TEST-NUMBERED-2
  domain: INFRA
  title: numbered AC plus description
  status: open
  priority: P1
  effort: s
  description: |
    Some prose context.
  acceptance_criteria:
    1. Alpha
    2. Beta
"#;
        let g = load_str(yaml).unwrap();
        let ac = g.acceptance_criteria.unwrap();
        assert_eq!(ac, vec!["Alpha".to_string(), "Beta".to_string()]);
        assert!(g.description.is_some());
    }

    #[test]
    fn parses_bullet_acceptance_criteria_baseline() {
        // Coverage matrix (a): canonical bullet form still works.
        let yaml = r#"
- id: TEST-BULLET-1
  domain: INFRA
  title: bullet AC
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - "First bullet"
    - "Second bullet"
"#;
        let g = load_str(yaml).unwrap();
        let ac = g.acceptance_criteria.unwrap();
        assert_eq!(
            ac,
            vec!["First bullet".to_string(), "Second bullet".to_string()]
        );
    }

    #[test]
    fn accepts_double_encoded_depends_on() {
        let yaml = r#"
- id: BUGGY-1
  domain: INFRA
  title: t
  status: open
  priority: P2
  effort: xs
  depends_on: "[\"X-1\", \"X-2\"]"
"#;
        let g = load_str(yaml).unwrap();
        assert_eq!(g.depends_on, vec![GapId("X-1".into()), GapId("X-2".into())]);
    }
}
