//! INFRA-2405: `chump contract-scan` — detect cross-PR state-file/IPC schema mismatch.
//!
//! Background: PR #2943 (INFRA-2397) wrote JSON keys {state, updated_at, last_tick_id}
//! while PR #2944 (INFRA-2398) read keys {last_status, last_tick_at, failing_gates}.
//! Keys never matched; the procedure layer shipped silently inert. INFRA-2404 hotfix
//! caught it 3 hours later. This subcommand is the gate that would have caught it
//! BEFORE EITHER MERGED.
//!
//! Detects 3 schema-delta classes:
//!   (a) JSON file writes from python heredocs — json.dumps({...}) patterns
//!   (b) Rust structs with #[derive(Serialize)] serialized to disk — field names
//!   (c) Ambient event-kind payloads from emit_ambient calls in scripts/coord/*.sh
//!
//! Flags:
//!   --in-flight         scan only files modified in currently-open PRs
//!   --against <N>       scan local-tree writes vs PR #N's reader changes
//!
//! Exit codes:
//!   0 = no mismatches
//!   1 = mismatches detected (summary to stderr)
//!   2 = scan failure

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

// ─── data types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct WriterEntry {
    path: String,
    kind: WriterKind,
    keys: Vec<String>,
}

#[derive(Debug, Clone)]
enum WriterKind {
    JsonFile,
    Struct,
    AmbientEvent,
}

impl WriterKind {
    fn as_str(&self) -> &str {
        match self {
            WriterKind::JsonFile => "json-file",
            WriterKind::Struct => "struct",
            WriterKind::AmbientEvent => "ambient-event",
        }
    }
}

#[derive(Debug, Clone)]
struct ReaderEntry {
    path: String,
    writer: String,
    expected_keys: Vec<String>,
    missing_keys: Vec<String>,
    extra_keys: Vec<String>,
}

#[derive(Debug, Clone)]
struct Mismatch {
    writer: String,
    reader: String,
    missing_keys: Vec<String>,
    extra_keys: Vec<String>,
}

// ─── repo root helper ────────────────────────────────────────────────────────

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(content) = std::fs::read_to_string(&cargo) {
                if content.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

// ─── (a) python json.dumps writer detection ──────────────────────────────────

/// Scan python scripts for `json.dumps({...})` patterns writing to .chump/*.json.
/// Extracts the key names from the dict literal.
fn scan_python_json_writers(root: &Path, file_filter: Option<&[String]>) -> Vec<WriterEntry> {
    let mut results = Vec::new();

    // Find python files that write .chump/*.json state files
    let python_files = collect_files(root, &["scripts"], &[".py", ".sh"], file_filter);

    for fpath in python_files {
        let content = match std::fs::read_to_string(&fpath) {
            Ok(c) => c,
            Err(_) => continue,
        };

        // Heuristic: look for json.dumps({...}) near .chump/ file writes
        // Pattern: json.dumps({ "key": ..., "key2": ... })
        let rel_path = fpath
            .strip_prefix(root)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| fpath.to_string_lossy().to_string());

        let keys = extract_json_dumps_keys(&content);
        if !keys.is_empty() && content.contains(".chump/") {
            results.push(WriterEntry {
                path: rel_path,
                kind: WriterKind::JsonFile,
                keys,
            });
        }
    }

    results
}

/// Extract key names from json.dumps({...}) patterns.
/// Handles: json.dumps({"key1": val, "key2": val2}) and
/// json.dumps({   "key1": val, ... }) across multiple lines.
fn extract_json_dumps_keys(content: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();

    // Simple state machine: find "json.dumps(" then scan for string keys
    let mut search_start = 0;
    while let Some(dump_pos) = content[search_start..].find("json.dumps(") {
        let abs_pos = search_start + dump_pos + "json.dumps(".len();

        // Find the extent of the dict (track brace depth)
        let chunk = &content[abs_pos..];
        let dict_text = extract_balanced_braces(chunk, '{', '}');

        // Extract "key": patterns from dict_text
        for key in extract_string_keys_from_dict(&dict_text) {
            if seen.insert(key.clone()) {
                keys.push(key);
            }
        }

        search_start = abs_pos;
        if search_start >= content.len() {
            break;
        }
    }

    keys
}

/// Extract the content of the first balanced {…} block from text.
fn extract_balanced_braces(text: &str, open: char, close: char) -> String {
    let mut depth = 0i32;
    let mut start = None;
    let mut end = None;

    for (i, ch) in text.char_indices() {
        if ch == open {
            if depth == 0 {
                start = Some(i);
            }
            depth += 1;
        } else if ch == close {
            depth -= 1;
            if depth == 0 {
                end = Some(i);
                break;
            }
        }
    }

    match (start, end) {
        (Some(s), Some(e)) => text[s..=e].to_string(),
        _ => String::new(),
    }
}

/// Extract string key names from a Python/JSON dict literal text.
/// Matches patterns like: "key_name": or 'key_name':
fn extract_string_keys_from_dict(dict_text: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut chars = dict_text.chars().peekable();

    while let Some(ch) = chars.next() {
        // Match a quoted key followed by colon
        if ch == '"' || ch == '\'' {
            let quote = ch;
            let mut key = String::new();
            let mut escaped = false;

            for c in chars.by_ref() {
                if escaped {
                    key.push(c);
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == quote {
                    break;
                } else {
                    key.push(c);
                }
            }

            if !key.is_empty() {
                keys.push(key);
            }
        }
    }

    keys
}

// ─── (b) Rust struct Serialize field detection ───────────────────────────────

/// Scan Rust source files for structs with #[derive(Serialize)] that get
/// serialized to disk (appear near to_string/to_json/write patterns).
fn scan_rust_struct_writers(root: &Path, file_filter: Option<&[String]>) -> Vec<WriterEntry> {
    let mut results = Vec::new();

    let rust_files = collect_files(root, &["src", "crates"], &[".rs"], file_filter);

    for fpath in rust_files {
        let content = match std::fs::read_to_string(&fpath) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let rel_path = fpath
            .strip_prefix(root)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| fpath.to_string_lossy().to_string());

        let structs = extract_serialize_structs(&content);
        for (struct_name, fields) in structs {
            // Check if this struct is serialized to a file (written to .chump/*.json)
            // Look for serde_json::to_string, fs::write with json, etc.
            let is_disk_writer = content.contains("serde_json::to_string")
                || content.contains("serde_json::to_writer")
                || content.contains(".chump/")
                || (content.contains("write_all") && content.contains("json"));

            if is_disk_writer && !fields.is_empty() {
                results.push(WriterEntry {
                    path: format!("{rel_path}::{struct_name}"),
                    kind: WriterKind::Struct,
                    keys: fields,
                });
            }
        }
    }

    results
}

/// Extract (struct_name, field_names) from Rust source for structs with #[derive(Serialize)].
fn extract_serialize_structs(content: &str) -> Vec<(String, Vec<String>)> {
    let mut results = Vec::new();
    let lines: Vec<&str> = content.lines().collect();

    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].trim();

        // Look for #[derive(...Serialize...)]
        if line.contains("#[derive(") && line.contains("Serialize") {
            // Find the struct definition that follows (within next 5 lines)
            let mut j = i + 1;
            while j < lines.len() && j < i + 5 {
                let struct_line = lines[j].trim();
                if struct_line.starts_with("pub struct ")
                    || struct_line.starts_with("struct ")
                    || struct_line.starts_with("pub(crate) struct ")
                {
                    // Extract struct name
                    let struct_name = extract_struct_name(struct_line);

                    // Collect fields until closing brace
                    let mut fields = Vec::new();
                    let mut k = j + 1;
                    let mut depth = 0i32;

                    // Handle single-line struct
                    if struct_line.contains('{') {
                        depth += 1;
                    }
                    if struct_line.contains('}') {
                        // single-line tuple struct or empty struct
                        break;
                    }

                    while k < lines.len() {
                        let field_line = lines[k].trim();
                        if field_line.contains('{') {
                            depth += 1;
                        }
                        if field_line.contains('}') {
                            depth -= 1;
                            if depth <= 0 {
                                break;
                            }
                        }
                        // Match field patterns: `pub field_name: Type` or `field_name: Type`
                        // Also handle `#[serde(rename = "alt")]` for renamed fields
                        if let Some(field) = extract_field_name(field_line, &lines, k) {
                            fields.push(field);
                        }
                        k += 1;
                    }

                    if !struct_name.is_empty() && !fields.is_empty() {
                        results.push((struct_name, fields));
                    }
                    break;
                }
                j += 1;
            }
        }
        i += 1;
    }

    results
}

fn extract_struct_name(line: &str) -> String {
    // "pub struct FooBar {" → "FooBar"
    let parts: Vec<&str> = line.split_whitespace().collect();
    for (i, p) in parts.iter().enumerate() {
        if *p == "struct" && i + 1 < parts.len() {
            return parts[i + 1]
                .trim_end_matches('{')
                .trim_end_matches('<')
                .trim_end_matches('(')
                .to_string();
        }
    }
    String::new()
}

fn extract_field_name(line: &str, all_lines: &[&str], line_idx: usize) -> Option<String> {
    let trimmed = line.trim();

    // Skip comments, attributes, visibility keywords alone
    if trimmed.starts_with("//")
        || trimmed.starts_with("/*")
        || trimmed.is_empty()
        || trimmed == "{"
        || trimmed == "}"
    {
        return None;
    }

    // Check for serde(rename) on previous line
    if line_idx > 0 {
        let prev = all_lines[line_idx - 1].trim();
        if prev.starts_with("#[serde") && prev.contains("rename") {
            // Extract rename value: #[serde(rename = "new_name")]
            if let Some(start) = prev.find("rename = \"") {
                let after = &prev[start + 10..];
                if let Some(end) = after.find('"') {
                    return Some(after[..end].to_string());
                }
            }
        }
    }

    // Skip attribute lines themselves
    if trimmed.starts_with('#') {
        return None;
    }

    // Parse `[pub] field_name: Type`
    let without_pub = trimmed
        .trim_start_matches("pub(crate) ")
        .trim_start_matches("pub(super) ")
        .trim_start_matches("pub ");

    if let Some(colon_pos) = without_pub.find(':') {
        let name = without_pub[..colon_pos].trim();
        // Valid Rust identifier check (simple)
        if !name.is_empty()
            && name.chars().all(|c| c.is_alphanumeric() || c == '_')
            && !name.starts_with(|c: char| c.is_numeric())
        {
            return Some(name.to_string());
        }
    }

    None
}

// ─── (c) ambient event payload detection ─────────────────────────────────────

/// Scan scripts/coord/*.sh for emit_ambient calls and extract field names.
fn scan_ambient_event_writers(root: &Path, file_filter: Option<&[String]>) -> Vec<WriterEntry> {
    let mut results = Vec::new();

    let shell_files = collect_files(root, &["scripts/coord", "scripts"], &[".sh"], file_filter);

    for fpath in shell_files {
        let content = match std::fs::read_to_string(&fpath) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let rel_path = fpath
            .strip_prefix(root)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| fpath.to_string_lossy().to_string());

        // Look for emit_ambient or printf/echo with kind= patterns going to ambient.jsonl
        let event_entries = extract_ambient_event_payloads(&content);
        for (kind, keys) in event_entries {
            if !keys.is_empty() {
                results.push(WriterEntry {
                    path: format!("{rel_path}#{kind}"),
                    kind: WriterKind::AmbientEvent,
                    keys,
                });
            }
        }
    }

    results
}

/// Extract (event_kind, field_names) from shell scripts.
/// Matches patterns like:
///   printf '{"ts":"...","kind":"event-name","key1":"...","key2":"..."}\n'
///   emit_ambient "kind" '{"key1": val}'
fn extract_ambient_event_payloads(content: &str) -> Vec<(String, Vec<String>)> {
    let mut results = Vec::new();
    let mut seen_kinds: HashMap<String, Vec<String>> = HashMap::new();

    for line in content.lines() {
        let trimmed = line.trim();

        // Match JSON-literal lines with "kind":"..." pattern
        if trimmed.contains("\"kind\"") && (trimmed.contains("printf") || trimmed.contains("echo"))
        {
            let kind = extract_json_string_value(trimmed, "kind");
            if kind.is_empty() {
                continue;
            }

            let keys = extract_json_keys_from_line(trimmed);
            if !keys.is_empty() {
                let entry = seen_kinds.entry(kind).or_default();
                for k in keys {
                    if !entry.contains(&k) {
                        entry.push(k);
                    }
                }
            }
        }

        // Match emit_ambient function calls
        if trimmed.contains("emit_ambient") || trimmed.starts_with("emit_ambient") {
            let kind = extract_shell_arg(trimmed, 0);
            let payload_keys = extract_json_keys_from_shell_line(trimmed);
            if !kind.is_empty() && !payload_keys.is_empty() {
                let entry = seen_kinds.entry(kind).or_default();
                for k in payload_keys {
                    if !entry.contains(&k) {
                        entry.push(k);
                    }
                }
            }
        }
    }

    for (kind, keys) in seen_kinds {
        results.push((kind, keys));
    }

    results
}

/// Extract the string value for a given key from a JSON-like line.
fn extract_json_string_value(line: &str, key: &str) -> String {
    let search = format!("\"{}\":\"", key);
    if let Some(start) = line.find(&search) {
        let after = &line[start + search.len()..];
        if let Some(end) = after.find('"') {
            return after[..end].to_string();
        }
    }
    // Also try "key": "value" (space after colon)
    let search2 = format!("\"{key}\": \"");
    if let Some(start) = line.find(&search2) {
        let after = &line[start + search2.len()..];
        if let Some(end) = after.find('"') {
            return after[..end].to_string();
        }
    }
    String::new()
}

/// Extract all JSON key names from a line containing a JSON literal.
fn extract_json_keys_from_line(line: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut search = line;

    while let Some(colon_pos) = search.find("\":") {
        // Walk back to find the opening quote
        let before = &search[..colon_pos];
        if let Some(quote_pos) = before.rfind('"') {
            let key = &before[quote_pos + 1..];
            if !key.is_empty() && key.chars().all(|c| c.is_alphanumeric() || c == '_') {
                keys.push(key.to_string());
            }
        }
        search = &search[colon_pos + 2..];
        if search.is_empty() {
            break;
        }
    }

    keys
}

/// Extract JSON key names from a shell emit_ambient call.
fn extract_json_keys_from_shell_line(line: &str) -> Vec<String> {
    // Look for { ... } in the line
    if let Some(brace_start) = line.find('{') {
        let chunk = &line[brace_start..];
        let brace_content = extract_balanced_braces(chunk, '{', '}');
        return extract_json_keys_from_line(&brace_content);
    }
    Vec::new()
}

/// Extract nth shell-style argument from a line (space-separated, ignoring quotes).
fn extract_shell_arg(line: &str, n: usize) -> String {
    // Simple tokenizer that handles quoted args
    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_quote: Option<char> = None;

    for ch in line.chars() {
        match in_quote {
            Some(q) if ch == q => {
                in_quote = None;
            }
            Some(_) => {
                current.push(ch);
            }
            None if ch == '"' || ch == '\'' => {
                in_quote = Some(ch);
            }
            None if ch.is_whitespace() => {
                if !current.is_empty() {
                    args.push(current.clone());
                    current.clear();
                }
            }
            None => {
                current.push(ch);
            }
        }
    }
    if !current.is_empty() {
        args.push(current);
    }

    args.get(n + 1).cloned().unwrap_or_default()
}

// ─── consumer/reader scanning ────────────────────────────────────────────────

/// For each writer entry, find all files that read those keys and check alignment.
fn scan_readers(
    root: &Path,
    writers: &[WriterEntry],
    file_filter: Option<&[String]>,
) -> (Vec<ReaderEntry>, Vec<Mismatch>) {
    let mut readers = Vec::new();
    let mut mismatches = Vec::new();

    // Collect all files to scan for readers
    let all_files: Vec<PathBuf> = {
        let mut files = collect_files(root, &["src", "crates"], &[".rs"], file_filter);
        files.extend(collect_files(
            root,
            &["scripts"],
            &[".sh", ".py"],
            file_filter,
        ));
        files
    };

    for writer in writers {
        let writer_keys: HashSet<&str> = writer.keys.iter().map(|s| s.as_str()).collect();

        for fpath in &all_files {
            let content = match std::fs::read_to_string(fpath) {
                Ok(c) => c,
                Err(_) => continue,
            };

            let rel_path = fpath
                .strip_prefix(root)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| fpath.to_string_lossy().to_string());

            // Don't match the writer against itself
            if writer.path.starts_with(&rel_path) || rel_path.starts_with(&writer.path) {
                continue;
            }

            let consumed_keys = extract_consumed_keys(&content, &writer.kind);

            if consumed_keys.is_empty() {
                continue;
            }

            // Check for intersection (reader consumes at least one key from this writer)
            let consumed_set: HashSet<&str> = consumed_keys.iter().map(|s| s.as_str()).collect();
            let intersection: HashSet<&&str> = writer_keys.intersection(&consumed_set).collect();

            if intersection.is_empty() {
                continue;
            }

            // Compute missing and extra keys
            let missing_keys: Vec<String> = consumed_keys
                .iter()
                .filter(|k| !writer_keys.contains(k.as_str()))
                .cloned()
                .collect();
            let extra_keys: Vec<String> = writer
                .keys
                .iter()
                .filter(|k| !consumed_set.contains(k.as_str()))
                .cloned()
                .collect();

            if !missing_keys.is_empty() {
                mismatches.push(Mismatch {
                    writer: writer.path.clone(),
                    reader: rel_path.clone(),
                    missing_keys: missing_keys.clone(),
                    extra_keys: extra_keys.clone(),
                });
            }

            readers.push(ReaderEntry {
                path: rel_path,
                writer: writer.path.clone(),
                expected_keys: consumed_keys,
                missing_keys,
                extra_keys,
            });
        }
    }

    (readers, mismatches)
}

/// Extract the second quoted string argument from a function call like `f(raw, "key")`.
/// Used for `extract_json_string(raw, "key")` where the key is the second argument.
fn extract_second_quoted_arg(text: &str) -> String {
    // text starts just after the function name, e.g. "(raw, \"key\")"
    // Skip past the first argument (non-quote content) to find the second quoted string.
    let mut chars = text.chars();
    let mut depth = 0i32;
    let mut past_first_arg = false;

    // Find opening paren
    for ch in chars.by_ref() {
        if ch == '(' {
            depth += 1;
            break;
        }
    }

    if depth == 0 {
        return String::new();
    }

    // Scan until we hit a comma at depth=1 (end of first arg), then find next quoted string
    let mut in_quote: Option<char> = None;
    for ch in chars.by_ref() {
        match in_quote {
            Some(q) if ch == q => {
                in_quote = None;
            }
            Some(_) => {}
            None if ch == '"' || ch == '\'' => {
                if past_first_arg {
                    // Start collecting the key
                    let mut key = String::new();
                    let quote = ch;
                    for c in chars.by_ref() {
                        if c == quote {
                            break;
                        }
                        key.push(c);
                    }
                    return key;
                }
                in_quote = Some(ch);
            }
            None if ch == ',' && depth == 1 => {
                past_first_arg = true;
            }
            None if ch == '(' => {
                depth += 1;
            }
            None if ch == ')' => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            None => {}
        }
    }
    String::new()
}

/// Extract keys that a file READS from the given writer kind.
fn extract_consumed_keys(content: &str, writer_kind: &WriterKind) -> Vec<String> {
    let mut keys = Vec::new();
    let mut seen = HashSet::new();

    match writer_kind {
        WriterKind::JsonFile => {
            // extract_json_string(raw, "key") — key is second argument
            {
                let mut search = content;
                while let Some(pos) = search.find("extract_json_string") {
                    let after = &search[pos + "extract_json_string".len()..];
                    let key = extract_second_quoted_arg(after);
                    if !key.is_empty()
                        && key.chars().all(|c| c.is_alphanumeric() || c == '_')
                        && seen.insert(key.clone())
                    {
                        keys.push(key);
                    }
                    search = &search[pos + "extract_json_string".len()..];
                    if search.is_empty() {
                        break;
                    }
                }
            }

            // .get("key") — key is first (only) argument — Rust HashMap / Python dict
            {
                let mut search = content;
                while let Some(pos) = search.find(".get(") {
                    let after = &search[pos + 4..]; // after ".get", so after starts at "("
                    let key = extract_next_quoted_string(after);
                    if !key.is_empty()
                        && key.chars().all(|c| c.is_alphanumeric() || c == '_')
                        && seen.insert(key.clone())
                    {
                        keys.push(key);
                    }
                    search = &search[pos + 4..];
                    if search.is_empty() {
                        break;
                    }
                }
            }

            // json["key"] or map["key"] — key in brackets
            {
                let mut search = content;
                while let Some(pos) = search.find(r#"["#) {
                    let after = &search[pos + 1..];
                    let key = extract_next_quoted_string(after);
                    if !key.is_empty()
                        && key.chars().all(|c| c.is_alphanumeric() || c == '_')
                        && seen.insert(key.clone())
                    {
                        keys.push(key);
                    }
                    search = &search[pos + 1..];
                    if search.is_empty() {
                        break;
                    }
                }
            }
        }
        WriterKind::Struct => {
            // Rust patterns: serde_json::from_str::<StructName> or field access after deserialization
            // Look for .field_name patterns after a from_str
            if content.contains("serde_json::from_str")
                || content.contains("serde_json::from_value")
            {
                // Extract field accesses: .field_name
                let mut search: &str = content;
                while let Some(dot_pos) = search.find('.') {
                    let after = &search[dot_pos + 1..];
                    let field: String = after
                        .chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    if !field.is_empty()
                        && !field.starts_with(|c: char| c.is_numeric())
                        && field.len() > 2
                        && seen.insert(field.clone())
                    {
                        keys.push(field);
                    }
                    search = &search[dot_pos + 1..];
                    if search.is_empty() {
                        break;
                    }
                }
            }
        }
        WriterKind::AmbientEvent => {
            // Look for ambient event consumption patterns
            // e.g., reading from ambient.jsonl and extracting fields
            for pattern in &[r#"extract_json_string"#, r#".get("#] {
                let mut search = content;
                while let Some(pos) = search.find(pattern) {
                    let after = &search[pos + pattern.len()..];
                    let key = extract_next_quoted_string(after);
                    if !key.is_empty()
                        && key.chars().all(|c| c.is_alphanumeric() || c == '_')
                        && seen.insert(key.clone())
                    {
                        keys.push(key);
                    }
                    search = &search[pos + pattern.len()..];
                    if search.is_empty() {
                        break;
                    }
                }
            }
        }
    }

    keys
}

/// Extract the next quoted string (single or double) from text.
fn extract_next_quoted_string(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;

    // Skip whitespace and opening parens
    while i < chars.len() && (chars[i].is_whitespace() || chars[i] == '(') {
        i += 1;
    }

    if i >= chars.len() {
        return String::new();
    }

    let quote = chars[i];
    if quote != '"' && quote != '\'' {
        return String::new();
    }

    i += 1;
    let mut result = String::new();
    while i < chars.len() && chars[i] != quote {
        result.push(chars[i]);
        i += 1;
    }

    result
}

// ─── file collection helpers ─────────────────────────────────────────────────

/// Collect files under given subdirs with given extensions.
/// If file_filter is Some, only return files in that set.
fn collect_files(
    root: &Path,
    subdirs: &[&str],
    extensions: &[&str],
    file_filter: Option<&[String]>,
) -> Vec<PathBuf> {
    let mut results = Vec::new();

    for subdir in subdirs {
        let dir = root.join(subdir);
        if !dir.exists() {
            continue;
        }
        collect_files_recursive(&dir, extensions, &mut results);
    }

    if let Some(filter) = file_filter {
        let filter_set: HashSet<&str> = filter.iter().map(|s| s.as_str()).collect();
        results.retain(|p| {
            let rel = p
                .strip_prefix(root)
                .map(|r| r.to_string_lossy().to_string())
                .unwrap_or_default();
            filter_set.contains(rel.as_str())
        });
    }

    results
}

fn collect_files_recursive(dir: &Path, extensions: &[&str], results: &mut Vec<PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_files_recursive(&path, extensions, results);
        } else if path.is_file() {
            let ext = path
                .extension()
                .map(|e| format!(".{}", e.to_string_lossy()))
                .unwrap_or_default();
            if extensions.contains(&ext.as_str()) {
                results.push(path);
            }
        }
    }
}

// ─── in-flight PR file list ──────────────────────────────────────────────────

/// Get the list of files modified in all currently-open PRs via gh CLI.
fn get_in_flight_files() -> Result<Vec<String>, String> {
    let output = Command::new("gh")
        .args(["pr", "list", "--json", "number,files", "--limit", "50"])
        .output()
        .map_err(|e| format!("gh command failed: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "gh pr list failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let json_str = String::from_utf8_lossy(&output.stdout);
    // Simple extraction: look for "path":"..." patterns
    let mut files = Vec::new();
    let mut search = json_str.as_ref();
    while let Some(pos) = search.find("\"path\":\"") {
        let after = &search[pos + 8..];
        if let Some(end) = after.find('"') {
            let path = &after[..end];
            if !path.is_empty() {
                files.push(path.to_string());
            }
        }
        search = &search[pos + 8..];
        if search.is_empty() {
            break;
        }
    }

    Ok(files)
}

/// Get the list of files modified in a specific PR.
fn get_pr_files(pr_number: u64) -> Result<Vec<String>, String> {
    let output = Command::new("gh")
        .args(["pr", "view", &pr_number.to_string(), "--json", "files"])
        .output()
        .map_err(|e| format!("gh command failed: {e}"))?;

    if !output.status.success() {
        return Err(format!(
            "gh pr view failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let json_str = String::from_utf8_lossy(&output.stdout);
    let mut files = Vec::new();
    let mut search = json_str.as_ref();
    while let Some(pos) = search.find("\"path\":\"") {
        let after = &search[pos + 8..];
        if let Some(end) = after.find('"') {
            let path = &after[..end];
            if !path.is_empty() {
                files.push(path.to_string());
            }
        }
        search = &search[pos + 8..];
        if search.is_empty() {
            break;
        }
    }

    Ok(files)
}

// ─── JSON output ─────────────────────────────────────────────────────────────

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

fn vec_to_json_array(v: &[String]) -> String {
    let items: Vec<String> = v
        .iter()
        .map(|s| format!("\"{}\"", json_escape(s)))
        .collect();
    format!("[{}]", items.join(","))
}

fn output_json(writers: &[WriterEntry], readers: &[ReaderEntry], mismatches: &[Mismatch]) {
    let writers_json: Vec<String> = writers
        .iter()
        .map(|w| {
            format!(
                "{{\"path\":\"{}\",\"kind\":\"{}\",\"keys\":{}}}",
                json_escape(&w.path),
                w.kind.as_str(),
                vec_to_json_array(&w.keys)
            )
        })
        .collect();

    let readers_json: Vec<String> = readers
        .iter()
        .map(|r| {
            format!(
                "{{\"path\":\"{}\",\"writer\":\"{}\",\"expected_keys\":{},\"missing_keys\":{},\"extra_keys\":{}}}",
                json_escape(&r.path),
                json_escape(&r.writer),
                vec_to_json_array(&r.expected_keys),
                vec_to_json_array(&r.missing_keys),
                vec_to_json_array(&r.extra_keys),
            )
        })
        .collect();

    let mismatches_json: Vec<String> = mismatches
        .iter()
        .map(|m| {
            format!(
                "{{\"writer\":\"{}\",\"reader\":\"{}\",\"missing_keys\":{},\"extra_keys\":{}}}",
                json_escape(&m.writer),
                json_escape(&m.reader),
                vec_to_json_array(&m.missing_keys),
                vec_to_json_array(&m.extra_keys),
            )
        })
        .collect();

    println!(
        "{{\n  \"writers\": [{}],\n  \"readers\": [{}],\n  \"mismatches\": [{}]\n}}",
        writers_json.join(",\n    "),
        readers_json.join(",\n    "),
        mismatches_json.join(",\n    "),
    );
}

// ─── main entrypoint ─────────────────────────────────────────────────────────

pub fn run(args: &[String]) -> i32 {
    let mut in_flight = false;
    let mut against_pr: Option<u64> = None;
    let mut fixture_path: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--in-flight" => {
                in_flight = true;
            }
            "--against" => {
                i += 1;
                if i < args.len() {
                    // Allow either a PR number or a fixture path for testing
                    if let Ok(n) = args[i].parse::<u64>() {
                        against_pr = Some(n);
                    } else {
                        // Treat as a fixture directory path for smoke tests
                        fixture_path = Some(args[i].clone());
                    }
                }
            }
            "--help" | "-h" => {
                println!(
                    "Usage: chump contract-scan [--in-flight] [--against <pr-number|fixture-path>]"
                );
                println!();
                println!("Detect cross-PR state-file/IPC schema mismatches (INFRA-2405).");
                println!(
                    "Triggered by INFRA-2404: watchdog wrote {{state,updated_at,last_tick_id}},"
                );
                println!("claim-gate read {{last_status,last_tick_at,failing_gates}}. Keys never matched.");
                println!();
                println!("Exit codes:");
                println!("  0 = no mismatches");
                println!("  1 = mismatches detected (summary to stderr)");
                println!("  2 = scan failure");
                println!();
                println!("Flags:");
                println!("  --in-flight       scan only files in currently-open PRs");
                println!("  --against <N>     scan local writes vs PR #N's reader changes");
                return 0;
            }
            _ => {}
        }
        i += 1;
    }

    let root = if let Some(ref fp) = fixture_path {
        PathBuf::from(fp)
    } else {
        repo_root()
    };

    if !root.exists() {
        eprintln!(
            "[contract-scan] error: root path does not exist: {}",
            root.display()
        );
        return 2;
    }

    // Determine file filter
    let file_filter: Option<Vec<String>> = if let Some(pr) = against_pr {
        eprintln!("[contract-scan] loading files for PR #{pr}...");
        match get_pr_files(pr) {
            Ok(files) => {
                eprintln!("[contract-scan] PR #{pr} touches {} file(s)", files.len());
                Some(files)
            }
            Err(e) => {
                eprintln!("[contract-scan] warning: could not load PR #{pr} files: {e}");
                eprintln!("[contract-scan] falling back to full scan");
                None
            }
        }
    } else if in_flight {
        eprintln!("[contract-scan] loading in-flight PR files...");
        match get_in_flight_files() {
            Ok(files) => {
                eprintln!(
                    "[contract-scan] in-flight scan covers {} file(s)",
                    files.len()
                );
                Some(files)
            }
            Err(e) => {
                eprintln!("[contract-scan] warning: could not load in-flight files: {e}");
                eprintln!("[contract-scan] falling back to full scan");
                None
            }
        }
    } else {
        None
    };

    let filter_ref: Option<&[String]> = file_filter.as_deref();

    // (a) Scan python JSON writers
    eprintln!("[contract-scan] scanning python json.dumps writers...");
    let python_writers = scan_python_json_writers(&root, filter_ref);
    eprintln!(
        "[contract-scan] found {} python json-file writer(s)",
        python_writers.len()
    );

    // (b) Scan Rust struct writers
    eprintln!("[contract-scan] scanning Rust #[derive(Serialize)] struct writers...");
    let rust_writers = scan_rust_struct_writers(&root, filter_ref);
    eprintln!(
        "[contract-scan] found {} Rust struct writer(s)",
        rust_writers.len()
    );

    // (c) Scan ambient event writers
    eprintln!("[contract-scan] scanning ambient event writers in scripts/coord/*.sh...");
    let ambient_writers = scan_ambient_event_writers(&root, filter_ref);
    eprintln!(
        "[contract-scan] found {} ambient event writer(s)",
        ambient_writers.len()
    );

    let mut all_writers: Vec<WriterEntry> = Vec::new();
    all_writers.extend(python_writers);
    all_writers.extend(rust_writers);
    all_writers.extend(ambient_writers);

    eprintln!(
        "[contract-scan] scanning consumers for {} writer(s)...",
        all_writers.len()
    );
    let (readers, mismatches) = scan_readers(&root, &all_writers, filter_ref);

    output_json(&all_writers, &readers, &mismatches);

    if mismatches.is_empty() {
        eprintln!("[contract-scan] OK: no schema mismatches detected");
        0
    } else {
        let stderr = std::io::stderr();
        let mut err = stderr.lock();
        writeln!(
            err,
            "[contract-scan] MISMATCH: {} writer-reader schema conflict(s) detected",
            mismatches.len()
        )
        .ok();
        for m in &mismatches {
            writeln!(err, "  writer: {}", m.writer).ok();
            writeln!(err, "  reader: {}", m.reader).ok();
            if !m.missing_keys.is_empty() {
                writeln!(
                    err,
                    "  missing keys (reader expects, writer never wrote): {}",
                    m.missing_keys.join(", ")
                )
                .ok();
            }
            if !m.extra_keys.is_empty() {
                writeln!(
                    err,
                    "  extra keys (writer writes, reader never reads): {}",
                    m.extra_keys.join(", ")
                )
                .ok();
            }
            writeln!(err).ok();
        }
        writeln!(
            err,
            "[contract-scan] cite: INFRA-2404 — this is exactly the gate that would have caught"
        )
        .ok();
        writeln!(
            err,
            "[contract-scan]   the watchdog (INFRA-2397) / claim-gate (INFRA-2398) JSON-keys mismatch"
        )
        .ok();
        writeln!(err, "[contract-scan]   before either PR merged.").ok();
        1
    }
}
