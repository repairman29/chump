//! `POST /api/drop` — cheap idea-drop endpoint (EFFECTIVE-679, EFFECTIVE-392
//! slice).
//!
//! Deliberately the cheapest possible intake: no auth, no gap reservation,
//! no LLM call — just append a `{sentence, citation}` pair to a durable
//! local queue and hand back an id. `POST /api/mission` and `POST /api/gap`
//! are the "do work now" surfaces; this one is the "don't lose the thought"
//! surface, for the R&D-pillar admission-form pattern described in
//! `docs/rfcs/RFC-rnd-pillar.md` — cheap intake so ideas don't strand in an
//! agent's transient memory. A curator drains `status:new` rows later.
//!
//! Idempotency: the id is a deterministic hash of the trimmed
//! `(sentence, citation)` pair, so re-POSTing the same content always
//! returns the same id instead of creating a duplicate row.

use std::collections::hash_map::DefaultHasher;
use std::fs::{self, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Inbound payload for `POST /api/drop`.
#[derive(Debug, Deserialize)]
pub struct DropRequest {
    pub sentence: String,
    #[serde(default)]
    pub citation: String,
}

/// A single durable idea-drop row.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Drop {
    pub id: String,
    pub sentence: String,
    pub citation: String,
    pub status: String,
    pub timestamp_ms: i64,
}

/// Relative path (from `repo_root`) of the durable drop queue.
fn drops_file(repo_root: &Path) -> PathBuf {
    repo_root.join(".chump").join("idea_drops.jsonl")
}

/// Deterministic content-hash id — same `(sentence, citation)` always
/// produces the same id, which is what makes duplicate submissions
/// idempotent (`std::collections::hash_map::DefaultHasher::new()` uses
/// fixed keys, so this is stable across process restarts).
fn compute_id(sentence: &str, citation: &str) -> String {
    let mut hasher = DefaultHasher::new();
    sentence.hash(&mut hasher);
    citation.hash(&mut hasher);
    format!("drop-{:016x}", hasher.finish())
}

fn find_existing(path: &Path, id: &str) -> anyhow::Result<Option<Drop>> {
    if !path.exists() {
        return Ok(None);
    }
    let reader = BufReader::new(fs::File::open(path)?);
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(d) = serde_json::from_str::<Drop>(&line) {
            if d.id == id {
                return Ok(Some(d));
            }
        }
    }
    Ok(None)
}

/// Record a new idea drop, or return the existing one if this exact
/// `(sentence, citation)` was already submitted. Second element of the
/// tuple is `true` when a new row was appended, `false` on idempotent
/// replay.
pub fn record_drop(repo_root: &Path, req: DropRequest) -> anyhow::Result<(Drop, bool)> {
    let sentence = req.sentence.trim();
    if sentence.is_empty() {
        anyhow::bail!("sentence is required");
    }
    let citation = req.citation.trim();
    let id = compute_id(sentence, citation);
    let path = drops_file(repo_root);

    if let Some(existing) = find_existing(&path, &id)? {
        return Ok((existing, false));
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let drop = Drop {
        id: id.clone(),
        sentence: sentence.to_string(),
        citation: citation.to_string(),
        status: "new".to_string(),
        timestamp_ms: crate::db::now_ms(),
    };

    let mut f = OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(f, "{}", serde_json::to_string(&drop)?)?;

    Ok((drop, true))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-test-drop-{tag}-{}-{}",
            std::process::id(),
            compute_id(tag, "salt")
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn record_drop_creates_new_row() {
        let dir = tmp_dir("create");
        let (d, created) = record_drop(
            &dir,
            DropRequest {
                sentence: "try X".into(),
                citation: "source A".into(),
            },
        )
        .unwrap();
        assert!(created);
        assert_eq!(d.status, "new");
        assert!(drops_file(&dir).exists());
    }

    #[test]
    fn record_drop_is_idempotent() {
        let dir = tmp_dir("idempotent");
        let req = || DropRequest {
            sentence: "  try Y  ".into(),
            citation: "source B".into(),
        };
        let (first, created1) = record_drop(&dir, req()).unwrap();
        let (second, created2) = record_drop(&dir, req()).unwrap();
        assert!(created1);
        assert!(!created2);
        assert_eq!(first.id, second.id);

        let contents = fs::read_to_string(drops_file(&dir)).unwrap();
        assert_eq!(contents.lines().count(), 1);
    }

    #[test]
    fn record_drop_rejects_empty_sentence() {
        let dir = tmp_dir("empty");
        let err = record_drop(
            &dir,
            DropRequest {
                sentence: "   ".into(),
                citation: "".into(),
            },
        )
        .unwrap_err();
        assert!(err.to_string().contains("sentence is required"));
    }
}
