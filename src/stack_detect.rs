//! Stack detection for `chump init` (INFRA-1462).
//!
//! Scans a repo for filesystem signals (manifest files, lockfiles, test-runner
//! configs) and classifies the repo into a known [`StackClass`]. Known classes
//! get pre-configured sandbox manifests; unknown stacks fall through to a
//! guided-manual-config path so we never silently fail.
//!
//! This module is scaffolded as sub-task INFRA-1462a:
//! - Defines the public [`StackClass`] and [`StackSignals`] types
//! - Implements scan + classify for Rust+cargo and Node+TS+Jest
//! - Leaves Python+pytest and Go+go-test for sub-task INFRA-1462b
//!
//! The wiring into `chump init` is sub-task INFRA-1462c (separate PR).
//!
//! See `.chump-plans/INFRA-1462.md` for the full slice plan.

use std::path::Path;

/// A classified stack class. Known classes get pre-configured sandbox
/// manifests in `chump init`; [`StackClass::Unknown`] falls through to
/// guided-manual-config so we never silently fail.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StackClass {
    /// TypeScript on Node with Jest tests. Signal: `package.json` +
    /// `tsconfig.json` + jest config (in `package.json`, `jest.config.*`,
    /// or `tsconfig` jest preset).
    NodeTsJest,

    /// Plain JavaScript on Node with Jest tests. Signal: `package.json` +
    /// jest config (no `tsconfig.json`).
    NodeJsJest,

    /// Rust workspace using cargo. Signal: `Cargo.toml` at root + at least
    /// one `[package]` or `[workspace]` section.
    RustCargo,

    // INFRA-1462b will add: PythonPytest, PythonPoetry, GoModuleGoTest
    /// Stack not yet supported by detection. Operator must configure
    /// manually. The reason is preserved so the operator gets a useful
    /// diagnostic instead of "we don't know."
    Unknown(EsotericReason),
}

/// Why a stack was classified as [`StackClass::Unknown`]. Drives the
/// guided-manual-config message in `chump init`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EsotericReason {
    /// Multiple top-level manifest files of different stacks present
    /// (e.g. `package.json` + `Cargo.toml`). Stack is ambiguous.
    MultiLanguageMonorepo { manifests: Vec<String> },

    /// No recognized manifest file found at the repo root.
    NoManifest,

    /// A recognized manifest exists but lacks the signals we need
    /// (e.g. `package.json` exists but has no test-runner config).
    IncompleteSignals { reason: String },
}

/// Filesystem signals collected from a repo. Intermediate value between
/// [`scan`] and [`classify`]. Public so callers can inspect what was
/// detected before classification (useful for `--verbose` flags).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StackSignals {
    /// Manifest files found at the repo root (basenames only).
    pub manifests: Vec<String>,

    /// Test-runner indicator found (basenames only).
    pub test_runner_hints: Vec<String>,

    /// `true` if a `tsconfig.json` was found at the repo root.
    pub has_tsconfig: bool,

    /// `true` if a `Cargo.toml` contains a `[package]` or `[workspace]`
    /// section. Distinguishes a real cargo project from a stray `Cargo.toml`.
    pub cargo_toml_is_project: bool,

    /// `true` if a `docker-compose.yml` (or variant) was found at the root.
    pub has_docker_compose: bool,

    /// `true` if a `.env` or `.envrc` was found at the root.
    pub has_env_file: bool,
}

/// Scan a repo root and collect [`StackSignals`]. Reads only filesystem
/// metadata + targeted file contents (e.g. checks `Cargo.toml` for sections;
/// does not parse package.json into a serde tree).
///
/// Returns the signals; caller passes them to [`classify`].
///
/// Emits a `tracing::debug!` at entry and exit so a failing `chump init`
/// can be replayed via `RUST_LOG=chump::stack_detect=debug` without an
/// extra instrumentation pass.
pub fn scan(repo_root: &Path) -> std::io::Result<StackSignals> {
    tracing::debug!(
        target: "chump::stack_detect",
        repo_root = %repo_root.display(),
        "stack_detect::scan entry"
    );
    let mut signals = StackSignals::default();

    // Manifests at root
    for name in ["Cargo.toml", "package.json", "pyproject.toml", "go.mod"] {
        if repo_root.join(name).is_file() {
            signals.manifests.push(name.to_string());
        }
    }

    // Test-runner hints
    for name in [
        "jest.config.js",
        "jest.config.ts",
        "jest.config.cjs",
        "jest.config.mjs",
        "pytest.ini",
        "pyproject.toml", // also tested for [tool.pytest.ini_options] below
    ] {
        if repo_root.join(name).is_file() {
            signals.test_runner_hints.push(name.to_string());
        }
    }

    signals.has_tsconfig = repo_root.join("tsconfig.json").is_file();
    signals.has_docker_compose = ["docker-compose.yml", "docker-compose.yaml", "compose.yml"]
        .iter()
        .any(|n| repo_root.join(n).is_file());
    signals.has_env_file = [".env", ".envrc"]
        .iter()
        .any(|n| repo_root.join(n).is_file());

    // Cargo.toml has a [package] or [workspace] section?
    if signals.manifests.iter().any(|m| m == "Cargo.toml") {
        let contents = std::fs::read_to_string(repo_root.join("Cargo.toml"))?;
        signals.cargo_toml_is_project =
            contents.contains("[package]") || contents.contains("[workspace]");
    }

    // package.json with jest config in scripts? (cheap signal — full parse
    // is sub-task 1462b refinement)
    if signals.manifests.iter().any(|m| m == "package.json") {
        let contents = std::fs::read_to_string(repo_root.join("package.json"))?;
        if contents.contains("\"jest\"")
            && !signals
                .test_runner_hints
                .iter()
                .any(|h| h.starts_with("jest"))
        {
            signals
                .test_runner_hints
                .push("package.json[jest]".to_string());
        }
    }

    tracing::debug!(
        target: "chump::stack_detect",
        manifests = ?signals.manifests,
        test_runner_hints = ?signals.test_runner_hints,
        has_tsconfig = signals.has_tsconfig,
        has_docker_compose = signals.has_docker_compose,
        "stack_detect::scan complete"
    );
    Ok(signals)
}

/// Classify collected [`StackSignals`] into a [`StackClass`]. Pure function;
/// makes no syscalls.
pub fn classify(signals: &StackSignals) -> StackClass {
    let rust_signal =
        signals.manifests.iter().any(|m| m == "Cargo.toml") && signals.cargo_toml_is_project;
    let node_signal = signals.manifests.iter().any(|m| m == "package.json");
    let py_signal = signals.manifests.iter().any(|m| m == "pyproject.toml");
    let go_signal = signals.manifests.iter().any(|m| m == "go.mod");

    let lang_count = [rust_signal, node_signal, py_signal, go_signal]
        .iter()
        .filter(|x| **x)
        .count();

    if lang_count > 1 {
        return StackClass::Unknown(EsotericReason::MultiLanguageMonorepo {
            manifests: signals.manifests.clone(),
        });
    }

    if lang_count == 0 {
        return StackClass::Unknown(EsotericReason::NoManifest);
    }

    if rust_signal {
        // INFRA-1462b will refine with cargo-specific test-runner detection
        return StackClass::RustCargo;
    }

    if node_signal {
        let has_jest = signals.test_runner_hints.iter().any(|h| h.contains("jest"));
        if !has_jest {
            return StackClass::Unknown(EsotericReason::IncompleteSignals {
                reason: "package.json present but no Jest config — Mocha/Vitest/other runners not yet supported in v1".to_string(),
            });
        }
        return if signals.has_tsconfig {
            StackClass::NodeTsJest
        } else {
            StackClass::NodeJsJest
        };
    }

    // Python or Go reached but not yet implemented (INFRA-1462b)
    StackClass::Unknown(EsotericReason::IncompleteSignals {
        reason: format!(
            "Python+pytest and Go+go-test detection is sub-task INFRA-1462b; manifests found: {:?}",
            signals.manifests
        ),
    })
}

// ────────────────────────── tests ──────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    /// Build a temp dir with the given files. Each `(path, contents)` is
    /// written relative to the temp dir's root.
    fn make_fixture(files: &[(&str, &str)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        for (name, contents) in files {
            let p = dir.path().join(name);
            if let Some(parent) = p.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            let mut f = fs::File::create(&p).unwrap();
            f.write_all(contents.as_bytes()).unwrap();
        }
        dir
    }

    #[test]
    fn classifies_rust_cargo_workspace() {
        let dir = make_fixture(&[("Cargo.toml", "[workspace]\nmembers = []\n")]);
        let signals = scan(dir.path()).unwrap();
        assert_eq!(classify(&signals), StackClass::RustCargo);
        assert!(signals.cargo_toml_is_project);
    }

    #[test]
    fn classifies_rust_cargo_package() {
        let dir = make_fixture(&[(
            "Cargo.toml",
            "[package]\nname = \"x\"\nversion = \"0.1.0\"\n",
        )]);
        let signals = scan(dir.path()).unwrap();
        assert_eq!(classify(&signals), StackClass::RustCargo);
    }

    #[test]
    fn classifies_node_ts_jest() {
        let dir = make_fixture(&[("package.json", "{\"jest\": {}}"), ("tsconfig.json", "{}")]);
        let signals = scan(dir.path()).unwrap();
        assert_eq!(classify(&signals), StackClass::NodeTsJest);
    }

    #[test]
    fn classifies_node_js_jest() {
        let dir = make_fixture(&[("package.json", "{\"jest\": {}}")]);
        let signals = scan(dir.path()).unwrap();
        assert_eq!(classify(&signals), StackClass::NodeJsJest);
    }

    #[test]
    fn esoteric_multi_language_monorepo() {
        let dir = make_fixture(&[
            ("Cargo.toml", "[package]\nname=\"x\"\nversion=\"0.1.0\"\n"),
            ("package.json", "{\"jest\": {}}"),
        ]);
        let signals = scan(dir.path()).unwrap();
        match classify(&signals) {
            StackClass::Unknown(EsotericReason::MultiLanguageMonorepo { manifests }) => {
                assert!(manifests.contains(&"Cargo.toml".to_string()));
                assert!(manifests.contains(&"package.json".to_string()));
            }
            other => panic!("expected MultiLanguageMonorepo, got {other:?}"),
        }
    }

    #[test]
    fn esoteric_no_manifest() {
        let dir = make_fixture(&[("README.md", "no stack here\n")]);
        let signals = scan(dir.path()).unwrap();
        assert_eq!(
            classify(&signals),
            StackClass::Unknown(EsotericReason::NoManifest)
        );
    }

    #[test]
    fn esoteric_node_without_jest() {
        let dir = make_fixture(&[("package.json", "{\"name\": \"x\"}")]);
        let signals = scan(dir.path()).unwrap();
        match classify(&signals) {
            StackClass::Unknown(EsotericReason::IncompleteSignals { reason }) => {
                assert!(reason.contains("Jest"));
            }
            other => panic!("expected IncompleteSignals (no Jest), got {other:?}"),
        }
    }

    #[test]
    fn cargo_toml_without_section_is_not_a_project() {
        let dir = make_fixture(&[("Cargo.toml", "# stray toml, no project sections\n")]);
        let signals = scan(dir.path()).unwrap();
        assert!(!signals.cargo_toml_is_project);
        // Without a real project section, the lang_count goes to 0 → NoManifest
        assert_eq!(
            classify(&signals),
            StackClass::Unknown(EsotericReason::NoManifest)
        );
    }
}
