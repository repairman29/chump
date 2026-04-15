//! Context firewall: enforces isolation between the orchestrator and delegate workers.
//!
//! Delegates receive only the text they need to process — never blackboard state,
//! neuromodulation levels, conversation history, memory, or other cognitive context.
//! This module makes that isolation **explicit, auditable, and enforced** by:
//!
//! 1. **Redacting secrets** — strips API keys, tokens, passwords, and other sensitive
//!    patterns from text before it leaves the orchestrator.
//! 2. **Size limiting** — prevents accidentally forwarding massive context blobs to workers.
//! 3. **Audit logging** — traces what was delegated (truncated) for post-hoc review.
//!
//! Wired into [`crate::delegate_tool`] as the single gate before any worker call.

/// Maximum characters allowed in a single delegate text payload.
/// Texts exceeding this are truncated with a marker.
const MAX_DELEGATE_TEXT_CHARS: usize = 32_000;

/// Result of running text through the firewall.
#[derive(Debug)]
pub struct FirewallResult {
    /// The sanitized text, safe to send to a worker.
    pub text: String,
    /// Number of secret patterns redacted.
    pub redactions: usize,
    /// Whether the text was truncated due to size.
    pub truncated: bool,
    /// Original length before any processing.
    pub original_len: usize,
}

/// Run text through the context firewall before delegating to a worker.
///
/// 1. Redacts patterns that look like secrets.
/// 2. Truncates to [`MAX_DELEGATE_TEXT_CHARS`] if needed.
/// 3. Logs an audit trace via `tracing`.
pub fn sanitize(text: &str, task_label: &str) -> FirewallResult {
    let original_len = text.len();
    let mut sanitized = text.to_string();
    let mut redactions = 0;

    // Redact secrets using pattern scanners
    redactions += redact_prefixed_tokens(&mut sanitized);
    redactions += redact_config_secrets(&mut sanitized);
    redactions += redact_bearer_tokens(&mut sanitized);
    redactions += redact_jwts(&mut sanitized);
    redactions += redact_private_keys(&mut sanitized);

    // Size limit
    let truncated = sanitized.len() > MAX_DELEGATE_TEXT_CHARS;
    if truncated {
        sanitized.truncate(MAX_DELEGATE_TEXT_CHARS);
        sanitized.push_str("\n[…truncated by context firewall]");
    }

    // Audit trace
    let preview_len = sanitized.len().min(120);
    let preview: String = sanitized.chars().take(preview_len).collect();
    if redactions > 0 || truncated {
        tracing::warn!(
            task = task_label,
            original_len,
            final_len = sanitized.len(),
            redactions,
            truncated,
            "context_firewall: sanitized delegate payload — preview: {:?}…",
            preview,
        );
    } else {
        tracing::debug!(
            task = task_label,
            len = sanitized.len(),
            "context_firewall: delegate payload clean — preview: {:?}…",
            preview,
        );
    }

    FirewallResult {
        text: sanitized,
        redactions,
        truncated,
        original_len,
    }
}

/// Convenience: sanitize and return just the text (most callers only need this).
pub fn sanitize_text(text: &str, task_label: &str) -> String {
    sanitize(text, task_label).text
}

/// Returns the configured max delegate text size.
pub fn max_text_chars() -> usize {
    MAX_DELEGATE_TEXT_CHARS
}

// --- Redaction scanners ---

/// Redact prefixed API tokens: sk-..., pk_live_..., ghp_..., gho_..., AKIA..., etc.
fn redact_prefixed_tokens(text: &mut String) -> usize {
    let mut count = 0;
    let prefixes: &[(&str, usize, &str)] = &[
        // (prefix, min_total_len, label)
        ("sk-", 20, "api_key"),
        ("sk_live_", 20, "api_key"),
        ("sk_test_", 20, "api_key"),
        ("pk_live_", 20, "api_key"),
        ("pk_test_", 20, "api_key"),
        ("rk_live_", 20, "api_key"),
        ("rk_test_", 20, "api_key"),
        ("ghp_", 40, "github_token"),
        ("gho_", 40, "github_token"),
        ("ghu_", 40, "github_token"),
        ("ghs_", 40, "github_token"),
        ("ghr_", 40, "github_token"),
        ("xoxb-", 20, "slack_token"),
        ("xoxp-", 20, "slack_token"),
        ("AKIA", 20, "aws_key"),
        ("ASIA", 20, "aws_key"),
    ];

    for &(prefix, min_len, label) in prefixes {
        loop {
            let Some(start) = text.find(prefix) else {
                break;
            };
            // Find end of token (alphanumeric + - + _)
            let end = text[start..]
                .char_indices()
                .skip(prefix.len())
                .find(|(_, c)| !c.is_ascii_alphanumeric() && *c != '-' && *c != '_')
                .map(|(i, _)| start + i)
                .unwrap_or(text.len());
            let token_len = end - start;
            if token_len >= min_len {
                let replacement = format!("[REDACTED:{}]", label);
                text.replace_range(start..end, &replacement);
                count += 1;
            } else {
                // Too short to be a real token — skip by replacing prefix temporarily
                // to avoid infinite loop, then restore
                break;
            }
        }
    }
    count
}

/// Redact config-style secrets: password=..., token=..., secret=..., api_key=...
fn redact_config_secrets(text: &mut String) -> usize {
    let mut count = 0;
    let keywords = [
        "password",
        "passwd",
        "secret_key",
        "secret",
        "api_token",
        "api_key",
        "apikey",
        "api_secret",
    ];

    for keyword in &keywords {
        let lower = text.to_lowercase();
        let mut search_from = 0;
        loop {
            let Some(kw_pos) = lower[search_from..].find(keyword) else {
                break;
            };
            let kw_pos = search_from + kw_pos;
            let after_kw = kw_pos + keyword.len();

            // Look for = or : after the keyword (with optional whitespace)
            let rest = &text[after_kw..];
            let trimmed = rest.trim_start();
            let skip = rest.len() - trimmed.len();

            if trimmed.starts_with('=') || trimmed.starts_with(':') {
                let val_start = after_kw + skip + 1; // skip the = or :
                let val_rest = text[val_start..].trim_start();
                let val_offset = val_start + (text[val_start..].len() - val_rest.len());

                // Find end of value (stop at whitespace, newline, or quote boundary)
                let (val_end, _in_quotes) =
                    if val_rest.starts_with('"') || val_rest.starts_with('\'') {
                        let quote = val_rest.chars().next().unwrap();
                        let inner = &val_rest[1..];
                        if let Some(close) = inner.find(quote) {
                            (val_offset + 1 + close + 1, true) // include quotes
                        } else {
                            (val_offset + val_rest.len().min(60), false)
                        }
                    } else {
                        let end = val_rest
                            .char_indices()
                            .find(|(_, c)| c.is_whitespace() || *c == '\n')
                            .map(|(i, _)| val_offset + i)
                            .unwrap_or(val_offset + val_rest.len());
                        (end, false)
                    };

                let val_len = val_end - val_offset;
                if val_len >= 8 {
                    let replacement =
                        format!("{}[REDACTED:config_secret]", &text[kw_pos..val_offset]);
                    text.replace_range(kw_pos..val_end, &replacement);
                    count += 1;
                    search_from = kw_pos + replacement.len();
                } else {
                    search_from = val_end;
                }
            } else {
                search_from = after_kw;
            }
        }
    }
    count
}

/// Redact Bearer tokens: "Bearer eyJ..." or "bearer abc123..."
fn redact_bearer_tokens(text: &mut String) -> usize {
    let mut count = 0;
    let lower = text.to_lowercase();
    let mut search_from = 0;
    loop {
        let Some(pos) = lower[search_from..].find("bearer ") else {
            break;
        };
        let pos = search_from + pos;
        let token_start = pos + 7; // "bearer ".len()
        let rest = &text[token_start..];

        // Find end of bearer token
        let token_end = rest
            .char_indices()
            .find(|(_, c)| c.is_whitespace() || *c == '"' || *c == '\'')
            .map(|(i, _)| token_start + i)
            .unwrap_or(token_start + rest.len());

        let token_len = token_end - token_start;
        if token_len >= 20 {
            let replacement = format!("{}[REDACTED:bearer]", &text[pos..token_start]);
            text.replace_range(pos..token_end, &replacement);
            count += 1;
            search_from = pos + replacement.len();
        } else {
            search_from = token_end;
        }
    }
    count
}

/// Redact JWTs: three dot-separated base64url segments starting with eyJ
fn redact_jwts(text: &mut String) -> usize {
    let mut count = 0;
    let mut search_from = 0;
    loop {
        let Some(pos) = text[search_from..].find("eyJ") else {
            break;
        };
        let pos = search_from + pos;

        // Check it's a word boundary (start of string or preceded by non-alphanumeric)
        if pos > 0 {
            let prev = text.as_bytes()[pos - 1];
            if prev.is_ascii_alphanumeric() || prev == b'_' {
                search_from = pos + 3;
                continue;
            }
        }

        // Find the full JWT (three segments separated by dots)
        let rest = &text[pos..];
        let mut dots = 0;
        let end = rest
            .char_indices()
            .find(|(i, c)| {
                if *c == '.' {
                    dots += 1;
                    if dots > 2 {
                        return true;
                    }
                    return false;
                }
                if *i > 0 && !c.is_ascii_alphanumeric() && *c != '-' && *c != '_' && *c != '.' {
                    return true;
                }
                false
            })
            .map(|(i, _)| pos + i)
            .unwrap_or(pos + rest.len());

        let candidate = &text[pos..end];
        // Must have exactly 2 dots and each segment must be non-empty
        let segments: Vec<&str> = candidate.split('.').collect();
        if segments.len() >= 3
            && segments[0].len() >= 10
            && segments[1].len() >= 10
            && segments[2].len() >= 10
        {
            let replacement = "[REDACTED:jwt]";
            text.replace_range(pos..end, replacement);
            count += 1;
            search_from = pos + replacement.len();
        } else {
            search_from = pos + 3;
        }
    }
    count
}

/// Redact PEM private key blocks
fn redact_private_keys(text: &mut String) -> usize {
    let mut count = 0;
    let marker = "-----BEGIN ";
    let end_marker = "-----END ";
    let mut search_from = 0;

    loop {
        let Some(start) = text[search_from..].find(marker) else {
            break;
        };
        let start = search_from + start;

        // Check if it contains "PRIVATE KEY"
        let header_end = text[start..]
            .find("-----\n")
            .or_else(|| text[start..].find("-----\r\n"))
            .map(|i| start + i + 6)
            .unwrap_or(start + 40);

        let header = &text[start..header_end.min(text.len())];
        if !header.contains("PRIVATE KEY") {
            search_from = header_end;
            continue;
        }

        // Find matching END marker
        let block_end = text[header_end..]
            .find(end_marker)
            .and_then(|i| {
                let e = header_end + i;
                text[e..].find("-----").map(|j| e + j + 5)
            })
            .unwrap_or(header_end + 100.min(text.len() - header_end));

        text.replace_range(start..block_end.min(text.len()), "[REDACTED:private_key]");
        count += 1;
        search_from = start + "[REDACTED:private_key]".len();
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_text_passes_through() {
        let input = "This is a normal code review of a Rust function.";
        let result = sanitize(input, "test");
        assert_eq!(result.text, input);
        assert_eq!(result.redactions, 0);
        assert!(!result.truncated);
    }

    #[test]
    fn redacts_sk_api_key() {
        let input = "Use key sk-proj-abc123def456ghi789jkl012 to authenticate.";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:api_key]"),
            "got: {}",
            result.text
        );
        assert!(!result.text.contains("sk-proj-abc123"));
        assert!(result.redactions >= 1);
    }

    #[test]
    fn redacts_github_token() {
        let input = "export GITHUB_TOKEN=ghp_ABCDEFghijklmnopqrstuvwxyz1234567890ab";
        let result = sanitize(input, "test");
        assert!(result.text.contains("[REDACTED:"), "got: {}", result.text);
        assert!(!result.text.contains("ghp_ABCDEF"));
    }

    #[test]
    fn redacts_bearer_token() {
        let input = "Authorization: Bearer abcdefghij1234567890abcdefghij1234567890";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:bearer]"),
            "got: {}",
            result.text
        );
        assert!(!result.text.contains("abcdefghij1234567890"));
    }

    #[test]
    fn redacts_aws_key() {
        let input = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE1";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:aws_key]"),
            "got: {}",
            result.text
        );
        assert!(!result.text.contains("AKIAIOSFODNN7EXAMPLE1"));
    }

    #[test]
    fn redacts_config_password() {
        let input = "database_password = \"super_secret_p@ssw0rd_123\"";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:config_secret]"),
            "got: {}",
            result.text
        );
        assert!(!result.text.contains("super_secret"));
    }

    #[test]
    fn redacts_private_key_header() {
        let input =
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:private_key]"),
            "got: {}",
            result.text
        );
    }

    #[test]
    fn redacts_jwt() {
        let input = "token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWV9.TJVA95OrM7E2cBab30RMHrHDcEfxjoYZgeFONFh7HgQ";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:jwt]"),
            "got: {}",
            result.text
        );
    }

    #[test]
    fn multiple_secrets_all_redacted() {
        let input = "key: sk-live-abcdefghijklmnop1234 and token: ghp_ABCDEFghijklmnopqrstuvwxyz1234567890ab";
        let result = sanitize(input, "test");
        assert!(
            result.redactions >= 2,
            "expected >=2 redactions, got {}: {}",
            result.redactions,
            result.text
        );
        assert!(!result.text.contains("sk-live-abcdefg"));
        assert!(!result.text.contains("ghp_ABCDEF"));
    }

    #[test]
    fn truncates_oversized_text() {
        let input = "x".repeat(MAX_DELEGATE_TEXT_CHARS + 1000);
        let result = sanitize(&input, "test");
        assert!(result.truncated);
        assert!(result.text.len() <= MAX_DELEGATE_TEXT_CHARS + 50); // +marker
        assert!(result.text.contains("[…truncated by context firewall]"));
    }

    #[test]
    fn normal_sized_text_not_truncated() {
        let input = "a".repeat(1000);
        let result = sanitize(&input, "test");
        assert!(!result.truncated);
        assert_eq!(result.text.len(), 1000);
    }

    #[test]
    fn preserves_normal_code() {
        let input = r#"
fn main() {
    let x = 42;
    println!("Hello, world! {}", x);
    let api_url = "https://example.com/api/v1";
    let config = Config::new();
}
"#;
        let result = sanitize(input, "test");
        assert_eq!(
            result.redactions, 0,
            "false positive in normal code: {}",
            result.text
        );
        assert!(result.text.contains("fn main()"));
        assert!(result.text.contains("let x = 42"));
    }

    #[test]
    fn short_prefixes_not_false_positive() {
        // "sk-foo" is too short to be a real API key
        let input = "variable sk-foo is set";
        let result = sanitize(input, "test");
        assert_eq!(
            result.redactions, 0,
            "short prefix false positive: {}",
            result.text
        );
    }

    #[test]
    fn slack_token_redacted() {
        let input = "SLACK_TOKEN=xoxb-1234567890-abcdefghijklmnop";
        let result = sanitize(input, "test");
        assert!(result.text.contains("[REDACTED:"), "got: {}", result.text);
    }

    #[test]
    fn sanitize_text_convenience_wrapper() {
        let input = "key: sk-proj-abc123def456ghi789jkl012";
        let output = sanitize_text(input, "test");
        assert!(output.contains("[REDACTED:api_key]"));
        assert!(!output.contains("sk-proj-abc123"));
    }

    #[test]
    fn empty_string_passthrough() {
        let result = sanitize("", "test");
        assert_eq!(result.text, "");
        assert_eq!(result.redactions, 0);
        assert!(!result.truncated);
    }

    #[test]
    fn bearer_case_insensitive() {
        let input = "BEARER abcdefghij1234567890abcdefghij1234567890";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:bearer]"),
            "case-insensitive bearer failed: {}",
            result.text
        );
    }

    #[test]
    fn consecutive_secrets_all_redacted() {
        let input = "sk-live-abcdefghijklmnop1234\nsk-test-zyxwvutsrqponmlk5678\nghp_ABCDEFghijklmnopqrstuvwxyz1234567890ab";
        let result = sanitize(input, "test");
        assert!(
            result.redactions >= 3,
            "expected >=3, got {}: {}",
            result.redactions,
            result.text
        );
    }

    #[test]
    fn config_secret_various_keys() {
        for key in &["password=", "secret_key=", "api_token=", "api_key="] {
            let input = format!("{}mysupersecretvalue123456", key);
            let result = sanitize(&input, "test");
            assert!(
                result.redactions >= 1,
                "missed config key '{}': {}",
                key,
                result.text
            );
        }
    }

    #[test]
    fn pem_ec_private_key() {
        let input = "-----BEGIN EC PRIVATE KEY-----\nMHQCAQEEIODN...\n-----END EC PRIVATE KEY-----";
        let result = sanitize(input, "test");
        assert!(
            result.text.contains("[REDACTED:private_key]"),
            "EC key not redacted: {}",
            result.text
        );
    }

    #[test]
    fn public_key_not_redacted() {
        let input = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8...\n-----END PUBLIC KEY-----";
        let result = sanitize(input, "test");
        assert_eq!(
            result.redactions, 0,
            "public key should not be redacted: {}",
            result.text
        );
    }

    #[test]
    fn exact_truncation_boundary() {
        let input = "x".repeat(MAX_DELEGATE_TEXT_CHARS);
        let result = sanitize(&input, "test");
        assert!(!result.truncated, "exact boundary should not truncate");
        assert_eq!(result.text.len(), MAX_DELEGATE_TEXT_CHARS);
    }
}
