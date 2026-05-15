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
    #[serde(default)]
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
