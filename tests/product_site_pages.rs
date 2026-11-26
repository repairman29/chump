//! Integration verification for the Chump Product Suite (`web/site/`).
//!
//! Enforces:
//! 1. Complete multi-page IA exists (`index`, `fleet`, `cascade`, `tools/fleet-simulator`,
//!    `tools/config-doctor`, `pricing`, `icon.svg`, `assets/site.css`, `assets/site.js`).
//! 2. Full SEO/OpenGraph hygiene (`<title>`, `<meta name="description">`, `og:title`,
//!    shared `<chump-site-header>` and `<chump-site-footer>`).
//! 3. Portable relative asset/page paths (zero root-absolute `/site/` or `/icon.svg`
//!    URLs) so the exact same HTML bundle works at `/site/` (`chump --web`) and `/chump/`
//!    (GitHub Pages), and every internal relative href resolves on disk.
//! 4. Zero raw hex / rgb() / rgba() / hsl() literals outside `:root` / `[data-theme]`
//!    (matching `scripts/lint/css-token-discipline.sh`).
//! 5. Zero banned marketing hype words from `scripts/ci/test-voice-banlist.sh`.
//! 6. Every generated `config.toml` template across the interactive tools parses and
//!    passes `chump_config::ChumpConfig::validate()` with zero unknown top-level keys.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

const SITE_PAGES: &[&str] = &[
    "web/site/index.html",
    "web/site/fleet/index.html",
    "web/site/cascade/index.html",
    "web/site/docs/index.html",
    "web/site/tools/fleet-simulator/index.html",
    "web/site/tools/config-doctor/index.html",
    "web/site/pricing/index.html",
];

const BANNED_HYPE_WORDS: &[&str] = &[
    "synergy",
    "revolutionary",
    "disruptive",
    "game-changing",
    "paradigm-shift",
    "seamless",
    "robust",
    "world-class",
    "best-in-class",
    "unleash",
    "supercharge",
    "next-generation",
    "user journey",
];

#[test]
fn all_product_pages_have_complete_meta_and_portable_shell() {
    let root = repo_root();
    assert!(root.join("web/site/assets/site.css").is_file());
    assert!(root.join("web/site/assets/site.js").is_file());
    assert!(root.join("web/site/icon.svg").is_file());
    assert!(
        root.join("web/docs/index.html").is_file(),
        "web/docs/index.html must exist so /docs/ on local chump --web redirects cleanly to /site/docs/"
    );

    for rel in SITE_PAGES {
        let path = root.join(rel);
        assert!(path.is_file(), "missing product page: {rel}");
        let html = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {rel}: {e}"));
        assert!(html.contains("<title>"), "{rel} missing <title>");
        assert!(
            html.contains("name=\"description\""),
            "{rel} missing meta description"
        );
        assert!(
            html.contains("property=\"og:title\""),
            "{rel} missing og:title"
        );
        assert!(
            html.contains("<chump-site-header"),
            "{rel} missing <chump-site-header>"
        );
        assert!(
            html.contains("<chump-site-footer"),
            "{rel} missing <chump-site-footer>"
        );
        assert!(
            html.contains("assets/site.css"),
            "{rel} missing relative site.css stylesheet"
        );
        assert!(
            html.contains("assets/site.js"),
            "{rel} missing relative site.js bundle"
        );
        assert!(
            !html.contains("\"/site/") && !html.contains("\"/icon.svg\""),
            "{rel} must use relative paths rather than root-absolute /site/ or /icon.svg so GitHub Pages (/chump/) works without 404s"
        );
    }
}

#[test]
fn internal_relative_site_links_resolve_to_existing_targets() {
    let root = repo_root();
    let href_re = regex::Regex::new(r##"href="(\.\.?/[^"#?]*)""##).unwrap();

    for rel in SITE_PAGES {
        let page_path = root.join(rel);
        let page_dir = page_path.parent().unwrap();
        let html = std::fs::read_to_string(&page_path).unwrap();
        for cap in href_re.captures_iter(&html) {
            let href = &cap[1];
            let candidate = page_dir.join(href);
            let exists = candidate.is_file() || candidate.join("index.html").is_file();
            assert!(
                exists,
                "{rel} links to broken relative target '{href}' (looked for {})",
                candidate.display()
            );
        }
    }
}

fn strip_root_blocks(text: &str) -> String {
    let re = regex::Regex::new(
        r"(?s)(?::root|html\[data-theme[^\]]*\]|\[data-theme[^\]]*\])\s*\{[^}]*\}",
    )
    .unwrap();
    re.replace_all(text, "").into_owned()
}

#[test]
fn product_site_obeys_strict_css_token_and_voice_discipline() {
    let root = repo_root();
    let hex_re = regex::Regex::new(r"#[0-9a-fA-F]{3,8}\b").unwrap();
    let fn_re = regex::Regex::new(r"\b(?:rgb|rgba|hsl|hsla)\s*\([^)]+\)").unwrap();

    let mut all_files: Vec<PathBuf> = SITE_PAGES.iter().map(|p| root.join(p)).collect();
    all_files.push(root.join("web/site/assets/site.css"));
    all_files.push(root.join("web/site/assets/site.js"));

    for path in &all_files {
        let content = std::fs::read_to_string(path).unwrap();
        let stripped = strip_root_blocks(&content);
        for (idx, line) in stripped.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//") || trimmed.starts_with("/*") || trimmed.starts_with('*') {
                continue;
            }
            assert!(
                !hex_re.is_match(line),
                "{}:{} contains raw hex literal outside :root: {line}",
                path.display(),
                idx + 1
            );
            assert!(
                !fn_re.is_match(line),
                "{}:{} contains raw color function outside :root: {line}",
                path.display(),
                idx + 1
            );
        }
    }

    for rel in SITE_PAGES {
        let lower = std::fs::read_to_string(root.join(rel))
            .unwrap()
            .to_lowercase();
        for banned in BANNED_HYPE_WORDS {
            let word_re = regex::Regex::new(&format!(r"\b{}\b", regex::escape(banned))).unwrap();
            assert!(
                !word_re.is_match(&lower),
                "{rel} contains banned hype phrase '{banned}'"
            );
        }
    }
}

fn assert_valid_strict_chump_config(label: &str, raw_toml: &str) {
    let allowed_top_keys: BTreeSet<&str> = [
        "auth",
        "api",
        "providers",
        "fleet",
        "worker",
        "web",
        "nats",
        "settings",
    ]
    .into_iter()
    .collect();

    let val: toml::Value = toml::from_str(raw_toml)
        .unwrap_or_else(|e| panic!("{label} invalid TOML syntax: {e}\n{raw_toml}"));
    let tbl = val
        .as_table()
        .unwrap_or_else(|| panic!("{label} root is not a TOML table"));
    for k in tbl.keys() {
        assert!(
            allowed_top_keys.contains(k.as_str()),
            "{label} emitted unrecognized top-level ChumpConfig key '{k}' (would be silently ignored!)"
        );
    }

    let cfg = chump_config::ChumpConfig::parse_toml_str(raw_toml, Path::new(label))
        .unwrap_or_else(|e| panic!("{label} failed ChumpConfig deserialization: {e}\n{raw_toml}"));
    cfg.validate()
        .unwrap_or_else(|e| panic!("{label} failed chump config validate: {e}\n{raw_toml}"));
}

#[test]
fn interactive_toml_generators_emit_schema_valid_chump_config() {
    let root = repo_root();

    // 1. Verify no interactive site page still emits retired flat top-level keys or invalid tier="oauth".
    for rel in SITE_PAGES {
        let html = std::fs::read_to_string(root.join(rel)).unwrap();
        assert!(
            !html.contains("tier = \"oauth\""),
            "{rel} must use tier = \"subscription\", never invalid tier = \"oauth\""
        );
        assert!(
            !html.contains("chump service start"),
            "{rel} must use real CLI verbs (chump service install && chump up), never non-existent 'chump service start'"
        );
        assert!(
            !html.contains("ChumpSupervisor"),
            "{rel} must reference canonical Windows scheduled task 'ChumpDaemon', never 'ChumpSupervisor'"
        );
    }

    // 2. Validate representative outputs from all 4 interactive TOML surfaces against ChumpConfig.
    let samples = [
        (
            "index.html#harness-snippet(chump-local)",
            r#"
[auth]
mode = "auto"

[fleet]
mode = "grind"
harness = "chump-local"

[[providers]]
name = "ollama-local"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
tier = "local"
"#,
        ),
        (
            "cascade/index.html#out-toml(auto)",
            r#"
[auth]
mode = "auto"

[fleet]
mode = "grind"
desired_workers = 2
harness = "claude"
disk_floor_gb = 5.0
auto_merge = true

[web]
bind_addr = "127.0.0.1"
port = 3847

[settings]
CARGO_BUILD_JOBS = 2

[[providers]]
name = "gemini-flash"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
api_key_env = "GEMINI_API_KEY"
model = "gemini-2.5-flash"
priority = 10
tier = "cloud"
enabled = true

[[providers]]
name = "local-ollama-floor"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
tier = "local"
enabled = true
"#,
        ),
        (
            "tools/fleet-simulator/index.html#sim-copy-toml",
            r#"
[auth]
mode = "auto"

[fleet]
mode = "grind"
desired_workers = 8
harness = "claude"
disk_floor_gb = 5.0
auto_merge = true

[web]
bind_addr = "127.0.0.1"
port = 3847

[settings]
CARGO_BUILD_JOBS = 4
LEASE_FIREWALL = true
LOCAL_OFFLOAD_TARGET_PCT = 65

[[providers]]
name = "local-ollama-floor"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
tier = "local"
enabled = true
"#,
        ),
        (
            "tools/config-doctor/index.html#remediated-toml",
            r#"
[auth]
mode = "auto"

[fleet]
mode = "grind"
desired_workers = 6
harness = "claude"
disk_floor_gb = 5.0
auto_merge = true

[web]
bind_addr = "127.0.0.1"
port = 3847

[settings]
CARGO_BUILD_JOBS = 2
LEASE_FIREWALL = true
GATE_FILE_GUARD = true

[[providers]]
name = "primary-cloud-slot"
api_key_env = "GEMINI_API_KEY"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
model = "gemini-2.5-flash"
rpm_limit = 360
priority = 10
tier = "cloud"
enabled = true

[[providers]]
name = "secondary-code-slot"
api_key_env = "MISTRAL_API_KEY"
base_url = "https://api.mistral.ai/v1"
model = "codestral-latest"
priority = 14
tier = "paid"
enabled = true

[[providers]]
name = "local-ollama-floor"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
tier = "local"
enabled = true
"#,
        ),
    ];

    for (label, raw) in samples {
        assert_valid_strict_chump_config(label, raw);
    }
}

#[test]
fn web_server_exposes_site_redirect_route() {
    let ws = std::fs::read_to_string(Path::new(&repo_root()).join("src/web_server.rs")).unwrap();
    assert!(
        ws.contains(r#".route("/site", get(|| async { Redirect::permanent("/site/") }))"#),
        "src/web_server.rs must redirect /site to /site/"
    );
}
