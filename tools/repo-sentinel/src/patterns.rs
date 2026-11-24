use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Severity {
    Low,
    Medium,
    High,
    Critical,
}

impl Severity {
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "low" => Some(Severity::Low),
            "medium" => Some(Severity::Medium),
            "high" => Some(Severity::High),
            "critical" => Some(Severity::Critical),
            _ => None,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Severity::Low => "low",
            Severity::Medium => "medium",
            Severity::High => "high",
            Severity::Critical => "critical",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecretHit {
    pub service: String,
    pub rule_id: String,
    pub severity: Severity,
    pub redacted: String,
}

pub fn redact_token(token: &str) -> String {
    if token.chars().count() >= 14 {
        let first_six: String = token.chars().take(6).collect();
        let last_four: String = token.chars().rev().take(4).collect();
        format!(
            "{}{}{}",
            first_six,
            "****...",
            last_four.chars().rev().collect::<String>()
        )
    } else {
        "****REDACTED****".to_string()
    }
}

pub fn shannon_entropy(data: &str) -> f64 {
    if data.is_empty() {
        return 0.0;
    }

    let mut freq = std::collections::HashMap::new();
    for c in data.chars() {
        *freq.entry(c).or_insert(0) += 1;
    }

    let len = data.chars().count() as f64;
    let mut entropy = 0.0;

    for count in freq.values() {
        let p = *count as f64 / len;
        entropy -= p * p.log2();
    }

    entropy
}

pub fn is_placeholder(token: &str, line: &str) -> bool {
    let token_lower = token.to_lowercase();
    let line_lower = line.to_lowercase();

    token_lower.contains("example")
        || token_lower.contains("your_")
        || token_lower.contains("replace_me")
        || token_lower.contains("placeholder")
        || token_lower.contains("dummy")
        || token_lower.contains("redacted")
        || token_lower.contains("xxxx")
        || token_lower.contains("000000")
        || token_lower.contains("<token>")
        || token_lower.contains("akiaiosfodnn7example")
        || line_lower.contains("sentinel:ignore")
}

pub fn classify_leak_filename(rel_path: &str) -> Option<(&'static str, &'static str)> {
    let basename = std::path::Path::new(rel_path)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_lowercase());

    if let Some(basename) = basename {
        if basename.ends_with(".bak") || basename.ends_with(".backup") {
            Some(("leak-backup-file", "Backup file leak vector (.bak/.backup)"))
        } else if basename == ".env" || basename.starts_with(".env.") {
            if basename == ".env.example"
                || basename == ".env.sample"
                || basename == ".env.template"
                || basename == ".env.dist"
                || basename == ".env.schema"
            {
                None
            } else {
                Some(("leak-env-file", "Environment file exposed"))
            }
        } else if basename.ends_with(".json")
            && ((basename.contains("service") && basename.contains("account"))
                || basename.contains("credentials")
                || basename == "clawdbot.json")
        {
            Some((
                "leak-credential-json",
                "Service account or cleartext credential JSON",
            ))
        } else if basename.ends_with(".pem")
            || basename.ends_with(".p12")
            || basename.ends_with(".pfx")
        {
            Some(("leak-private-cert", "Private key or certificate archive"))
        } else if basename == "id_rsa" || basename == "id_ed25519" {
            Some(("leak-ssh-key", "Private SSH key file"))
        } else {
            None
        }
    } else {
        None
    }
}

pub fn scan_line_for_secrets(line: &str) -> Vec<SecretHit> {
    if line.to_lowercase().contains("sentinel:ignore") {
        return vec![];
    }

    let mut hits = vec![];

    let prefixes = [
        ("Stripe", "stripe-live-key", "sk_live_", Severity::Critical),
        (
            "Stripe",
            "stripe-restricted-key",
            "rk_live_",
            Severity::Critical,
        ),
        (
            "Stripe",
            "stripe-webhook-secret",
            "whsec_",
            Severity::Critical,
        ),
        (
            "Supabase",
            "supabase-secret-key",
            "sb_secret_",
            Severity::Critical,
        ),
        ("Supabase", "supabase-pat", "sbp_", Severity::Critical),
        (
            "OpenAI",
            "openai-project-key",
            "sk-proj-",
            Severity::Critical,
        ),
        (
            "OpenAI",
            "openai-svcacct-key",
            "sk-svcacct-",
            Severity::Critical,
        ),
        (
            "Anthropic",
            "anthropic-api-key",
            "sk-ant-",
            Severity::Critical,
        ),
        ("GitHub", "github-pat", "ghp_", Severity::Critical),
        (
            "GitHub",
            "github-fine-pat",
            "github_pat_",
            Severity::Critical,
        ),
        ("GitHub", "github-oauth", "gho_", Severity::Critical),
        ("AWS", "aws-access-key-id", "AKIA", Severity::High),
        ("Google", "google-api-key", "AIza", Severity::High),
        ("Groq", "groq-api-key", "gsk_", Severity::High),
        ("Slack", "slack-token", "xoxb-", Severity::High),
        ("Slack", "slack-user-token", "xoxp-", Severity::High),
    ];

    for (service, rule_id, prefix, severity) in prefixes.iter() {
        if let Some(pos) = line.find(prefix) {
            let token_start = pos;
            let token_end = line[token_start..]
                .char_indices()
                .take_while(|(_, c)| {
                    c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == '.'
                })
                .last()
                .map(|(i, _)| i + token_start + 1)
                .unwrap_or(token_start);

            let full_token = &line[token_start..token_end];
            if full_token.len() >= prefix.len() + 8 && !is_placeholder(full_token, line) {
                hits.push(SecretHit {
                    service: service.to_string(),
                    rule_id: rule_id.to_string(),
                    severity: *severity,
                    redacted: redact_token(full_token),
                });
            }
        }
    }

    if let Some(token_start) = line.find("eyJ") {
        let token_end = line[token_start..]
            .char_indices()
            .take_while(|(_, c)| c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == '.')
            .last()
            .map(|(i, _)| i + token_start + 1)
            .unwrap_or(token_start);

        let full_token = &line[token_start..token_end];
        if full_token.len() >= 8 && !is_placeholder(full_token, line) {
            hits.push(SecretHit {
                service: "Supabase".to_string(),
                rule_id: "supabase-service-role-jwt".to_string(),
                severity: Severity::Critical,
                redacted: redact_token(full_token),
            });
        }
    }

    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_severity_ordering() {
        assert!(Severity::Critical > Severity::High);
        assert!(Severity::High > Severity::Medium);
        assert!(Severity::Medium > Severity::Low);
    }

    #[test]
    fn test_severity_parse() {
        assert_eq!(Severity::parse("low"), Some(Severity::Low));
        assert_eq!(Severity::parse("medium"), Some(Severity::Medium));
        assert_eq!(Severity::parse("high"), Some(Severity::High));
        assert_eq!(Severity::parse("critical"), Some(Severity::Critical));
        assert_eq!(Severity::parse("invalid"), None);
    }

    #[test]
    fn test_severity_label() {
        assert_eq!(Severity::Low.label(), "low");
        assert_eq!(Severity::Medium.label(), "medium");
        assert_eq!(Severity::High.label(), "high");
        assert_eq!(Severity::Critical.label(), "critical");
    }

    #[test]
    fn test_redact_token() {
        assert_eq!(redact_token("1234567890123456"), "123456****...3456");
        assert_eq!(redact_token("short"), "****REDACTED****");
    }

    #[test]
    fn test_shannon_entropy() {
        assert_eq!(shannon_entropy("aaaa"), 0.0);
        assert!(shannon_entropy("randomstring") > 3.0);
    }

    #[test]
    fn test_is_placeholder() {
        assert!(is_placeholder("example", "line"));
        assert!(is_placeholder("your_token", "line"));
        assert!(is_placeholder("replace_me", "line"));
        assert!(is_placeholder("placeholder", "line"));
        assert!(is_placeholder("dummy", "line"));
        assert!(is_placeholder("redacted", "line"));
        assert!(is_placeholder("xxxx", "line"));
        assert!(is_placeholder("000000", "line"));
        assert!(is_placeholder("<token>", "line"));
        assert!(is_placeholder("akiaiosfodnn7example", "line"));
        assert!(is_placeholder("token", "sentinel:ignore"));
    }

    #[test]
    fn test_classify_leak_filename() {
        assert_eq!(
            classify_leak_filename(".env"),
            Some(("leak-env-file", "Environment file exposed"))
        );
        assert_eq!(
            classify_leak_filename(".env.bak"),
            Some(("leak-backup-file", "Backup file leak vector (.bak/.backup)"))
        );
        assert_eq!(
            classify_leak_filename("gcp-service-account.json"),
            Some((
                "leak-credential-json",
                "Service account or cleartext credential JSON"
            ))
        );
        assert_eq!(
            classify_leak_filename("clawdbot.json"),
            Some((
                "leak-credential-json",
                "Service account or cleartext credential JSON"
            ))
        );
        assert_eq!(classify_leak_filename(".env.example"), None);
        assert_eq!(
            classify_leak_filename("key.pem"),
            Some(("leak-private-cert", "Private key or certificate archive"))
        );
        assert_eq!(
            classify_leak_filename("id_rsa"),
            Some(("leak-ssh-key", "Private SSH key file"))
        );
    }

    #[test]
    fn test_scan_line_for_secrets() {
        let line = format!("{}{}{}", "sk_", "live_", "12345678901234567890");
        let hits = scan_line_for_secrets(&line);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].service, "Stripe");
        assert_eq!(hits[0].rule_id, "stripe-live-key");
        assert_eq!(hits[0].severity, Severity::Critical);
        assert_eq!(hits[0].redacted, "sk_liv****...7890");
    }
}
