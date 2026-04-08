//! Task notes contract: deterministic template + section extraction.
//!
//! Autonomy needs tasks to carry "done looks like" and verification steps in a
//! machine-readable way (without an LLM). This module defines:
//! - a standard notes template
//! - helpers to ensure the template exists
//! - helpers to extract key sections (Acceptance / Verify) from notes

use std::collections::HashMap;

pub const SECTION_CONTEXT: &str = "Context";
pub const SECTION_PLAN: &str = "Plan";
pub const SECTION_ACCEPTANCE: &str = "Acceptance";
pub const SECTION_VERIFY: &str = "Verify";
pub const SECTION_RISKS: &str = "Risks/Approvals";
pub const SECTION_PROGRESS: &str = "Progress";

pub fn template_for(title: &str, repo: Option<&str>) -> String {
    let repo_line = repo
        .map(|r| r.trim())
        .filter(|r| !r.is_empty())
        .map(|r| format!("- Repo: `{}`\n", r))
        .unwrap_or_default();
    format!(
        "## {SECTION_CONTEXT}\n\
         - Task: {title}\n\
         {repo_line}\
         - Why: \n\
         \n\
         ## {SECTION_PLAN}\n\
         - [ ] \n\
         \n\
         ## {SECTION_ACCEPTANCE}\n\
         - [ ] \n\
         \n\
         ## {SECTION_VERIFY}\n\
         - [ ] Command(s): \n\
         - [ ] Expected: \n\
         \n\
         ## {SECTION_RISKS}\n\
         - Tools likely needing approval: \n\
         - Risks: \n\
         \n\
         ## {SECTION_PROGRESS}\n\
         - (empty)\n"
    )
}

/// If notes are empty or missing key sections, append the template (preserving any existing text).
pub fn ensure_contract(notes: Option<&str>, title: &str, repo: Option<&str>) -> String {
    let existing = notes.unwrap_or("").trim();
    if existing.is_empty() {
        return template_for(title, repo);
    }
    let sections = extract_sections(existing);
    let has_acceptance = sections
        .get(&SECTION_ACCEPTANCE.to_lowercase())
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    let has_verify = sections
        .get(&SECTION_VERIFY.to_lowercase())
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    if has_acceptance && has_verify {
        return existing.to_string();
    }
    format!("{}\n\n{}", existing, template_for(title, repo))
}

/// Extract sections from markdown-like notes where sections are headed by `## Name`.
/// Keys are lowercased section names.
pub fn extract_sections(notes: &str) -> HashMap<String, String> {
    let mut out: HashMap<String, String> = HashMap::new();
    let mut cur_name: Option<String> = None;
    let mut cur_buf: Vec<String> = Vec::new();

    let flush = |out: &mut HashMap<String, String>,
                 cur_name: &mut Option<String>,
                 cur_buf: &mut Vec<String>| {
        if let Some(name) = cur_name.take() {
            let content = cur_buf.join("\n").trim().to_string();
            out.insert(name, content);
        }
        cur_buf.clear();
    };

    for line in notes.lines() {
        let t = line.trim_end();
        if let Some(h) = t.strip_prefix("## ") {
            flush(&mut out, &mut cur_name, &mut cur_buf);
            let name = h.trim().to_lowercase();
            cur_name = Some(name);
            continue;
        }
        if cur_name.is_some() {
            cur_buf.push(t.to_string());
        }
    }
    flush(&mut out, &mut cur_name, &mut cur_buf);
    out
}

pub fn acceptance(notes: &str) -> Option<String> {
    extract_sections(notes)
        .get(&SECTION_ACCEPTANCE.to_lowercase())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn verify(notes: &str) -> Option<String> {
    extract_sections(notes)
        .get(&SECTION_VERIFY.to_lowercase())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[allow(dead_code)]
pub fn _note_contract_api_surface_marker() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_contains_acceptance_and_verify_headers() {
        let t = template_for("T", Some("owner/repo"));
        assert!(t.contains("## Acceptance"));
        assert!(t.contains("## Verify"));
    }

    #[test]
    fn ensure_contract_appends_when_missing_sections() {
        let notes = "hello world";
        let out = ensure_contract(Some(notes), "T", None);
        assert!(out.starts_with("hello world"));
        assert!(out.contains("## Acceptance"));
        assert!(out.contains("## Verify"));
    }

    #[test]
    fn extract_sections_roundtrip() {
        let notes = "## Context\nx\n\n## Acceptance\nok\n\n## Verify\npass\n";
        let sections = extract_sections(notes);
        assert_eq!(sections.get("context").unwrap().trim(), "x");
        assert_eq!(sections.get("acceptance").unwrap().trim(), "ok");
        assert_eq!(sections.get("verify").unwrap().trim(), "pass");
    }
}

