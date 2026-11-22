//! Integration verification for the Chump Product Suite (`web/site/`).
//!
//! Enforces:
//! 1. Complete multi-page IA exists (`index`, `fleet`, `cascade`, `tools/fleet-simulator`,
//!    `tools/config-doctor`, `pricing`) plus shared `site.css` and `site.js`.
//! 2. Full SEO/OpenGraph hygiene (`<title>`, `<meta name="description">`, `og:title`,
//!    shared `<chump-site-header>` and `<chump-site-footer>`).
//! 3. Every internal `/site/...` href resolves to a real file or directory in `web/`.
//! 4. Zero raw hex / rgb() / rgba() / hsl() literals outside `:root` / `[data-theme]`
//!    (matching `scripts/lint/css-token-discipline.sh`).
//! 5. Zero banned marketing hype words from `scripts/ci/test-voice-banlist.sh`.

use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

const SITE_PAGES: &[&str] = &[
    "web/site/index.html",
    "web/site/fleet/index.html",
    "web/site/cascade/index.html",
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
fn all_product_pages_have_complete_meta_and_shell() {
    let root = repo_root();
    assert!(root.join("web/site/assets/site.css").is_file());
    assert!(root.join("web/site/assets/site.js").is_file());

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
            html.contains("/site/assets/site.css"),
            "{rel} missing site.css stylesheet"
        );
        assert!(
            html.contains("/site/assets/site.js"),
            "{rel} missing site.js bundle"
        );
    }
}

#[test]
fn internal_site_links_resolve_to_existing_targets() {
    let root = repo_root();
    let web_dir = root.join("web");
    let href_re = regex::Regex::new(r##"href="(/site[^"#?]*)""##).unwrap();

    for rel in SITE_PAGES {
        let html = std::fs::read_to_string(root.join(rel)).unwrap();
        for cap in href_re.captures_iter(&html) {
            let href = &cap[1];
            let sub = href.trim_start_matches('/');
            let candidate = web_dir.join(sub);
            let exists = candidate.is_file() || candidate.join("index.html").is_file();
            assert!(
                exists,
                "{rel} links to broken internal target '{href}' (looked for {})",
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

#[test]
fn web_server_exposes_site_redirect_route() {
    let ws = std::fs::read_to_string(Path::new(&repo_root()).join("src/web_server.rs")).unwrap();
    assert!(
        ws.contains(r#".route("/site", get(|| async { Redirect::permanent("/site/") }))"#),
        "src/web_server.rs must redirect /site to /site/"
    );
}
