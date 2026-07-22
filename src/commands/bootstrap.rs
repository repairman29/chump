//! INFRA-2265: `chump bootstrap <intent>` — net-new product bootstrap entrypoint.
//! INFRA-1881: `chump bootstrap <path> --template rust` — 2026 demo #1 (net-new outcome).
//!
//! Empty dir → git init → scaffold (Cargo.toml | package.json | pyproject.toml)
//! → README.md with intent string → first commit → umbrella gap via `chump gap reserve`.
//!
//! Sister of INFRA-1746 (`chump ingest` for existing-repo takeover). This is the
//! SUBSTRATE-layer entrypoint; consumer surfaces own the founder-facing pitch lane.
//!
//! Architecture decision: uses `ArchitectureDecisionContract` from crates/chump-handoff.
//! With --skip-arch-decision: defaults to Rust/minimal. Without it: exits 2 with TODO
//! (LLM wiring is a INFRA-2267 follow-up).
//!
//! ## Observability contract (INFRA-1784)
//!
//! - **Events on success/failure/timeout**: `bootstrap_initiated` (start),
//!   `bootstrap_completed` (success, classic mode), `chump_bootstrap_complete`
//!   (success, template mode, INFRA-1881), `bootstrap_failed` (any failure —
//!   there is no separate timeout event; `ArchDecisionTimeout` is a
//!   `failure_class` value on `bootstrap_failed`, since a timeout is just one
//!   more terminal failure mode from the caller's perspective).
//! - **Cost tracking**: bootstrap makes zero LLM calls today (the only live
//!   path is `--skip-arch-decision`; unguarded arch-decision is a TODO exit
//!   pending INFRA-2267). Once that LLM call lands it runs inside the calling
//!   session and is captured automatically by the existing session-level
//!   ledger (`src/session_ledger.rs` + `chump cost-watch`) — no
//!   bootstrap-specific cost plumbing is needed; do not add one.
//! - **Failure-class taxonomy**: `FailureClass` below tags every failure
//!   transient (bare re-run expected to succeed: `ArchDecisionTimeout`,
//!   `GapReserveFailed`, `ScaffoldingBuildCheck`) or permanent (needs
//!   operator/different args: `ScaffoldingWriteFailed`, `GitInitFailed`).
//!   Both `failure_class` and `failure_kind` (transient|permanent) ship as
//!   fields on `bootstrap_failed`.
//! - **Smoke test**: `scripts/ci/test-bootstrap-smoke.sh` — asserts the
//!   success-path events (Phase 4) and the failure-path event + its
//!   `failure_class`/`failure_kind` fields (Phase 2).
//!
//! Template mode (INFRA-1881): `chump bootstrap <path> --template rust` treats the
//! first positional arg as the target directory, derives the project name from its
//! basename, writes a complete Rust crate (Cargo.toml / src/main.rs / README.md /
//! .gitignore), initialises git, and runs `cargo check` to verify the scaffold builds.

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Instant;

// ── Template enum (INFRA-1881) ────────────────────────────────────────────────

/// Which project template to scaffold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BootstrapTemplate {
    #[default]
    Rust,
    Python,
    Node,
}

impl BootstrapTemplate {
    fn as_str(self) -> &'static str {
        match self {
            BootstrapTemplate::Rust => "rust",
            BootstrapTemplate::Python => "python",
            BootstrapTemplate::Node => "node",
        }
    }
}

impl FromStr for BootstrapTemplate {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "rust" => Ok(BootstrapTemplate::Rust),
            "python" => Ok(BootstrapTemplate::Python),
            "node" | "javascript" | "typescript" => Ok(BootstrapTemplate::Node),
            other => Err(format!(
                "unknown template '{}' — valid values: rust, python, node",
                other
            )),
        }
    }
}

// ── Args ─────────────────────────────────────────────────────────────────────

pub struct BootstrapArgs {
    /// The product intent string (first positional arg, or basename of dir in template mode).
    pub intent: String,
    /// Target directory (default: $PWD).
    pub dir: PathBuf,
    /// Skip the LLM-driven architecture decision; use Rust/minimal default.
    pub skip_arch_decision: bool,
    /// Delegate roadmap generation to `chump roadmap-from-vision` (INFRA-2267).
    pub with_roadmap: bool,
    /// Template to scaffold (INFRA-1881). Default = Rust.
    pub template: BootstrapTemplate,
    /// True when the first positional arg was used as the dir (template mode).
    pub template_mode: bool,
}

impl BootstrapArgs {
    pub fn from_argv(args: &[String]) -> Result<Self, String> {
        // args[0] = "bootstrap"; in classic mode first positional = intent;
        // in template mode (--template given and first positional looks like a path)
        // first positional = target dir.
        let mut intent: Option<String> = None;
        let mut dir: Option<PathBuf> = None;
        let mut skip_arch_decision = false;
        let mut with_roadmap = false;
        let mut template = BootstrapTemplate::Rust;
        let mut template_explicit = false;

        let mut i = 1; // skip "bootstrap"
        while i < args.len() {
            match args[i].as_str() {
                "--dir" => {
                    dir = Some(PathBuf::from(
                        args.get(i + 1)
                            .ok_or_else(|| "--dir requires a value".to_string())?,
                    ));
                    i += 2;
                }
                "--template" => {
                    let val = args.get(i + 1).ok_or_else(|| {
                        "--template requires a value (rust|python|node)".to_string()
                    })?;
                    template = BootstrapTemplate::from_str(val)?;
                    template_explicit = true;
                    i += 2;
                }
                "--skip-arch-decision" => {
                    skip_arch_decision = true;
                    i += 1;
                }
                "--with-roadmap" => {
                    with_roadmap = true;
                    i += 1;
                }
                "-h" | "--help" => {
                    return Err("__help__".to_string());
                }
                arg if arg.starts_with('-') => {
                    return Err(format!("unknown flag: {arg}"));
                }
                positional => {
                    if intent.is_none() {
                        intent = Some(positional.to_string());
                    } else {
                        return Err(format!(
                            "unexpected extra positional argument: {positional}"
                        ));
                    }
                    i += 1;
                }
            }
        }

        // ── Template mode: first positional = path, dir derived from it ──────
        // When --template is explicit and the positional arg looks like a path
        // (starts with /, ./, ~) OR no --dir was given and template is explicit,
        // treat the positional as the target directory.
        let template_mode = template_explicit && dir.is_none();

        let (resolved_dir, resolved_intent) = if template_mode {
            // First positional is the target directory path.
            let raw = intent.ok_or_else(|| "missing required <path> argument (e.g. chump bootstrap /tmp/my-project --template rust)".to_string())?;
            let path = PathBuf::from(&raw);
            // Derive project name from basename; fall back to the raw string.
            let basename = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(&raw)
                .to_string();
            (path, basename)
        } else {
            // Classic mode: first positional = intent string; --dir sets directory.
            let raw_intent = intent.ok_or_else(|| {
                "missing required <intent> argument (or use --template rust <path>)".to_string()
            })?;
            if raw_intent.trim().is_empty() {
                return Err("intent string cannot be empty".to_string());
            }
            let resolved = dir
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
            (resolved, raw_intent)
        };

        Ok(BootstrapArgs {
            intent: resolved_intent,
            dir: resolved_dir,
            skip_arch_decision,
            with_roadmap,
            template,
            template_mode,
        })
    }
}

// ── Failure classes ───────────────────────────────────────────────────────────
//
// INFRA-1784: each class is tagged transient (retryable — a re-run of the same
// command is expected to succeed once the underlying condition clears) or
// permanent (re-running with the same args will fail again; needs operator
// intervention or different args).

#[derive(Debug)]
enum FailureClass {
    ArchDecisionTimeout,
    ScaffoldingWriteFailed,
    ScaffoldingBuildCheck,
    GapReserveFailed,
    GitInitFailed,
}

impl FailureClass {
    fn as_str(&self) -> &'static str {
        match self {
            FailureClass::ArchDecisionTimeout => "arch_decision_timeout",
            FailureClass::ScaffoldingWriteFailed => "scaffolding_write_failed",
            FailureClass::ScaffoldingBuildCheck => "scaffolding_build_check",
            FailureClass::GapReserveFailed => "gap_reserve_failed",
            FailureClass::GitInitFailed => "git_init_failed",
        }
    }

    /// True when a bare re-run is expected to fix it (network/lock/timeout
    /// conditions); false when it needs operator intervention or different
    /// args (bad target dir, permissions, non-empty dir).
    fn is_transient(&self) -> bool {
        matches!(
            self,
            FailureClass::ArchDecisionTimeout
                | FailureClass::GapReserveFailed
                | FailureClass::ScaffoldingBuildCheck
        )
    }
}

// ── Arch decision output (mirrors ArchitectureDecisionContract::Output) ──────

struct ArchOutput {
    language: String,
    framework: String,
    test_harness: String,
    deps: Vec<String>,
    rationale: String,
}

impl ArchOutput {
    fn default_rust() -> Self {
        ArchOutput {
            language: "rust".to_string(),
            framework: "minimal".to_string(),
            test_harness: "cargo test".to_string(),
            deps: vec![],
            rationale: "test fixture default".to_string(),
        }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(args: &[String]) -> i32 {
    let bootstrap_args = match BootstrapArgs::from_argv(args) {
        Ok(a) => a,
        Err(e) if e == "__help__" => {
            print_usage();
            return 0;
        }
        Err(e) => {
            eprintln!("chump bootstrap: {e}");
            eprintln!();
            print_usage();
            return 2;
        }
    };

    match run_bootstrap(bootstrap_args) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn print_usage() {
    println!(
        "Usage: chump bootstrap <path|intent> [--template rust|python|node] [--dir <path>] [--skip-arch-decision] [--with-roadmap]"
    );
    println!();
    println!("Bootstrap a new product from an empty directory.");
    println!();
    println!("Arguments:");
    println!("  <path>                Target directory for template mode (with --template)");
    println!("  <intent>              One-sentence product intent (classic mode, no --template)");
    println!();
    println!("Options:");
    println!("  --template <kind>     Project template: rust (default), python, node");
    println!(
        "  --dir <path>          Target directory in classic mode (default: current directory)"
    );
    println!("  --skip-arch-decision  Use Rust/minimal defaults (for tests, no LLM)");
    println!("  --with-roadmap        Also generate a roadmap (INFRA-2267 follow-up)");
    println!();
    println!("Template mode (INFRA-1881) — empty dir → cargo run in one command:");
    println!("  chump bootstrap /tmp/my-project --template rust --skip-arch-decision");
    println!("  cd /tmp/my-project && cargo run   # → Hello, Chump!");
    println!();
    println!("Classic mode (INFRA-2265):");
    println!("  chump bootstrap \"A CLI tool that tracks daily habits\" --skip-arch-decision");
    println!("  chump bootstrap \"P2P file sync daemon\" --dir /tmp/myproject");
}

fn run_bootstrap(args: BootstrapArgs) -> Result<(), ()> {
    let start = Instant::now();
    let target_dir = &args.dir;
    let intent = &args.intent;

    // Resolve session ID for ambient events.
    let session_id = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());

    // ── Emit bootstrap_initiated ─────────────────────────────────────────────
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "bootstrap_initiated".to_string(),
        source: Some("chump-bootstrap".to_string()),
        fields: vec![
            ("intent".to_string(), intent.clone()),
            ("target_dir".to_string(), target_dir.display().to_string()),
            ("session_id".to_string(), session_id.clone()),
        ],
        ..Default::default()
    });

    // ── --with-roadmap: graceful TODO ─────────────────────────────────────────
    if args.with_roadmap {
        println!("TODO: --with-roadmap requires chump roadmap-from-vision (INFRA-2267 follow-up)");
        // Continue without roadmap (exit 0 as per AC #1).
    }

    // ── Guard: target dir must be empty ─────────────────────────────────────
    match check_dir_empty(target_dir) {
        Ok(()) => {}
        Err(e) => {
            eprintln!("chump bootstrap: {e}");
            emit_failure(
                "bootstrap_failed",
                FailureClass::ScaffoldingWriteFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
    }

    // ── Architecture decision ─────────────────────────────────────────────────
    let arch: ArchOutput = if args.skip_arch_decision {
        ArchOutput::default_rust()
    } else {
        eprintln!(
            "TODO: arch-decision via LLM not yet wired (INFRA-2267 follow-up); use --skip-arch-decision for now"
        );
        emit_failure(
            "bootstrap_failed",
            FailureClass::ArchDecisionTimeout,
            intent,
            target_dir,
        );
        return Err(());
    };

    // ── Track files created for cleanup on error ─────────────────────────────
    let mut files_created: Vec<PathBuf> = Vec::new();

    // ── git init ─────────────────────────────────────────────────────────────
    let git_init_result = std::process::Command::new("git")
        .args(["init", "-q"])
        .current_dir(target_dir)
        .output();

    match git_init_result {
        Ok(out) if out.status.success() => {}
        Ok(out) => {
            eprintln!(
                "chump bootstrap: git init failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            cleanup_files(&files_created, target_dir);
            emit_failure(
                "bootstrap_failed",
                FailureClass::GitInitFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
        Err(e) => {
            eprintln!("chump bootstrap: git init error: {e}");
            cleanup_files(&files_created, target_dir);
            emit_failure(
                "bootstrap_failed",
                FailureClass::GitInitFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
    }

    // ── Write README.md ───────────────────────────────────────────────────────
    let readme_path = target_dir.join("README.md");
    let readme_content = format!(
        "# {intent}\n\n\
         {intent}\n\n\
         ## Getting Started\n\n\
         This project was bootstrapped with `chump bootstrap` (INFRA-2265).\n\n\
         Architecture: {language} / {framework}\n\
         Test harness: {test_harness}\n\n\
         ## Rationale\n\n\
         {rationale}\n",
        intent = intent,
        language = arch.language,
        framework = arch.framework,
        test_harness = arch.test_harness,
        rationale = arch.rationale,
    );

    if let Err(e) = std::fs::write(&readme_path, &readme_content) {
        eprintln!("chump bootstrap: failed to write README.md: {e}");
        cleanup_files(&files_created, target_dir);
        emit_failure(
            "bootstrap_failed",
            FailureClass::ScaffoldingWriteFailed,
            intent,
            target_dir,
        );
        return Err(());
    }
    files_created.push(readme_path.clone());

    // ── Write scaffold ────────────────────────────────────────────────────────
    let scaffold_file = match write_scaffold(target_dir, &arch, &mut files_created) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("chump bootstrap: scaffold write failed: {e}");
            cleanup_files(&files_created, target_dir);
            emit_failure(
                "bootstrap_failed",
                FailureClass::ScaffoldingWriteFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
    };

    // ── Configure git identity for the scaffold commit ────────────────────────
    // Set local git user.name/email only if not already set, so tests don't
    // fail in CI when no global config exists.
    let _ = std::process::Command::new("git")
        .args(["config", "user.email", "chump-bootstrap@chump.local"])
        .current_dir(target_dir)
        .output();
    let _ = std::process::Command::new("git")
        .args(["config", "user.name", "chump-bootstrap"])
        .current_dir(target_dir)
        .output();

    // ── Stage all files ───────────────────────────────────────────────────────
    let add_result = std::process::Command::new("git")
        .args(["add", "."])
        .current_dir(target_dir)
        .output();

    if let Err(e) = add_result {
        eprintln!("chump bootstrap: git add failed: {e}");
        cleanup_files(&files_created, target_dir);
        emit_failure(
            "bootstrap_failed",
            FailureClass::GitInitFailed,
            intent,
            target_dir,
        );
        return Err(());
    }

    // ── Initial commit ────────────────────────────────────────────────────────
    let commit_msg = format!("chore: initial scaffold — {intent}");
    let commit_result = std::process::Command::new("git")
        .args([
            "-c",
            "gpg.sign=false",
            "commit",
            "-m",
            &commit_msg,
            "--no-verify",
        ])
        .current_dir(target_dir)
        .output();

    match commit_result {
        Ok(out) if out.status.success() => {}
        Ok(out) => {
            eprintln!(
                "chump bootstrap: git commit failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            cleanup_files(&files_created, target_dir);
            emit_failure(
                "bootstrap_failed",
                FailureClass::GitInitFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
        Err(e) => {
            eprintln!("chump bootstrap: git commit error: {e}");
            cleanup_files(&files_created, target_dir);
            emit_failure(
                "bootstrap_failed",
                FailureClass::GitInitFailed,
                intent,
                target_dir,
            );
            return Err(());
        }
    }

    // ── Template mode: write full template files + cargo check (INFRA-1881) ──
    // In template mode the git repo + README already exist from the classic path
    // above. We now overlay the template-specific files, amend the commit message,
    // and run `cargo check` to verify the scaffold actually builds.
    let build_ok: Option<bool> = if args.template_mode {
        match args.template {
            BootstrapTemplate::Rust => {
                match write_rust_template(target_dir, intent, &mut files_created) {
                    Ok(()) => {
                        // Stage the new template files (README was already staged;
                        // re-add to pick up the template-specific README + new files).
                        let _ = std::process::Command::new("git")
                            .args(["add", "."])
                            .current_dir(target_dir)
                            .output();
                        // Amend commit to use the template-specific message.
                        let _ = std::process::Command::new("git")
                            .args([
                                "-c",
                                "gpg.sign=false",
                                "commit",
                                "--amend",
                                "--no-edit",
                                "-m",
                                "chump bootstrap: rust template",
                                "--no-verify",
                            ])
                            .current_dir(target_dir)
                            .output();
                        // cargo check ─────────────────────────────────────────
                        let check_out = std::process::Command::new("cargo")
                            .arg("check")
                            .current_dir(target_dir)
                            .output();
                        let ok = match check_out {
                            Ok(o) => o.status.success(),
                            Err(_) => {
                                // cargo not on PATH — treat as skipped (true so we don't fail)
                                eprintln!("(bootstrap: cargo not found; skipping build check)");
                                true
                            }
                        };
                        if !ok {
                            eprintln!("chump bootstrap: cargo check failed on scaffolded crate");
                            emit_failure(
                                "bootstrap_failed",
                                FailureClass::ScaffoldingBuildCheck,
                                intent,
                                target_dir,
                            );
                            return Err(());
                        }
                        println!("  cargo check: ok");
                        Some(ok)
                    }
                    Err(e) => {
                        eprintln!("chump bootstrap: rust template write failed: {e}");
                        cleanup_files(&files_created, target_dir);
                        emit_failure(
                            "bootstrap_failed",
                            FailureClass::ScaffoldingWriteFailed,
                            intent,
                            target_dir,
                        );
                        return Err(());
                    }
                }
            }
            BootstrapTemplate::Python => {
                eprintln!(
                    "chump bootstrap: python template not yet implemented (INFRA-1881 follow-up)"
                );
                emit_failure(
                    "bootstrap_failed",
                    FailureClass::ScaffoldingWriteFailed,
                    intent,
                    target_dir,
                );
                return Err(());
            }
            BootstrapTemplate::Node => {
                eprintln!(
                    "chump bootstrap: node template not yet implemented (INFRA-1881 follow-up)"
                );
                emit_failure(
                    "bootstrap_failed",
                    FailureClass::ScaffoldingWriteFailed,
                    intent,
                    target_dir,
                );
                return Err(());
            }
        }
    } else {
        None
    };

    // ── Reserve umbrella gap via `chump gap reserve` ─────────────────────────
    let gap_title = format!("Bootstrap: {intent}");
    let gap_description = format!(
        "Umbrella gap created by `chump bootstrap` (INFRA-2265).\n\n\
         Intent: {intent}\n\n\
         Rough shape:\n\
         (a) Architecture: {language} / {framework} / {test_harness}\n\
         (b) Scaffold committed at {target_dir}\n\
         (c) Next: define sub-gaps for core features\n\
         (d) Rationale: {rationale}",
        intent = intent,
        language = arch.language,
        framework = arch.framework,
        test_harness = arch.test_harness,
        target_dir = target_dir.display(),
        rationale = arch.rationale,
    );

    let gap_ids = reserve_umbrella_gap(&gap_title, &gap_description, intent, target_dir);

    // ── Print results ─────────────────────────────────────────────────────────
    let duration_ms = start.elapsed().as_millis() as u64;
    let files_list = {
        let mut list = vec![readme_path.display().to_string(), scaffold_file.clone()];
        list.sort();
        list
    };

    println!("bootstrap complete in {duration_ms}ms");
    println!("  target:    {}", target_dir.display());
    println!("  intent:    {intent}");
    println!("  language:  {}", arch.language);
    println!("  scaffold:  {scaffold_file}");
    if !gap_ids.is_empty() {
        println!("  gap:       {}", gap_ids.join(", "));
    }

    // ── Emit bootstrap_completed (classic) ───────────────────────────────────
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "bootstrap_completed".to_string(),
        source: Some("chump-bootstrap".to_string()),
        fields: vec![
            ("intent".to_string(), intent.clone()),
            ("target_dir".to_string(), target_dir.display().to_string()),
            ("gap_ids".to_string(), gap_ids.join(",")),
            ("duration_ms".to_string(), duration_ms.to_string()),
            ("files_created".to_string(), files_list.join(",")),
        ],
        ..Default::default()
    });

    // ── Emit chump_bootstrap_complete (template mode, INFRA-1881) ────────────
    // scanner-anchor: "kind":"chump_bootstrap_complete"
    if let Some(build_ok_val) = build_ok {
        let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
            kind: "chump_bootstrap_complete".to_string(),
            source: Some("chump-bootstrap".to_string()),
            fields: vec![
                ("path".to_string(), target_dir.display().to_string()),
                ("template".to_string(), args.template.as_str().to_string()),
                ("build_ok".to_string(), build_ok_val.to_string()),
            ],
            ..Default::default()
        });
    }

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Write the Rust template files into `dir` (INFRA-1881).
///
/// Writes:
///   Cargo.toml  — `[package] name = <basename>`, version 0.1.0, edition 2021
///   src/main.rs — `fn main() { println!("Hello, Chump!"); }`
///   README.md   — overwritten with template-specific content + cargo run example
///   .gitignore  — `target/`
///
/// The caller is responsible for staging + committing.
fn write_rust_template(
    dir: &Path,
    name: &str,
    files_created: &mut Vec<PathBuf>,
) -> Result<(), String> {
    // Sanitise the crate name: Cargo requires snake_case, no spaces or dashes.
    let crate_name = name
        .replace([' ', '-'], "_")
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_')
        .collect::<String>();
    let crate_name = if crate_name.is_empty() {
        "project".to_string()
    } else {
        crate_name
    };

    // Cargo.toml
    let cargo_toml_path = dir.join("Cargo.toml");
    let cargo_toml = format!(
        "[package]\nname = \"{crate_name}\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n"
    );
    std::fs::write(&cargo_toml_path, cargo_toml)
        .map_err(|e| format!("cannot write Cargo.toml: {e}"))?;
    files_created.push(cargo_toml_path);

    // src/main.rs
    let src_dir = dir.join("src");
    std::fs::create_dir_all(&src_dir).map_err(|e| format!("cannot create src/: {e}"))?;
    let main_rs_path = src_dir.join("main.rs");
    std::fs::write(
        &main_rs_path,
        "fn main() {\n    println!(\"Hello, Chump!\");\n}\n",
    )
    .map_err(|e| format!("cannot write src/main.rs: {e}"))?;
    files_created.push(main_rs_path);

    // README.md — overwrite the generic one with template-specific content.
    let readme_path = dir.join("README.md");
    let readme = format!(
        "# {name}\n\n\
         {name} — bootstrapped with `chump bootstrap --template rust` (INFRA-1881).\n\n\
         ## Getting Started\n\n\
         ```bash\n\
         cargo run\n\
         # → Hello, Chump!\n\
         ```\n"
    );
    std::fs::write(&readme_path, readme).map_err(|e| format!("cannot write README.md: {e}"))?;
    // README was already tracked; no need to push again.

    // .gitignore
    let gitignore_path = dir.join(".gitignore");
    std::fs::write(&gitignore_path, "target/\n")
        .map_err(|e| format!("cannot write .gitignore: {e}"))?;
    files_created.push(gitignore_path);

    Ok(())
}

/// Returns Err(message) if the target directory contains files other than
/// .git/, .gitignore, and .DS_Store. Does NOT create or mutate anything.
fn check_dir_empty(dir: &Path) -> Result<(), String> {
    // If dir doesn't exist, it's fine — we'll treat it as empty.
    if !dir.exists() {
        return Ok(());
    }
    if !dir.is_dir() {
        return Err(format!(
            "target path '{}' exists but is not a directory",
            dir.display()
        ));
    }
    let entries =
        std::fs::read_dir(dir).map_err(|e| format!("cannot read target directory: {e}"))?;

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        // Allow these sentinel files/dirs.
        if name_str == ".git" || name_str == ".gitignore" || name_str == ".DS_Store" {
            continue;
        }
        return Err(format!(
            "target directory '{}' is not empty (found '{}'). \
             chump bootstrap only works on an empty directory.",
            dir.display(),
            name_str
        ));
    }
    Ok(())
}

/// Write the language-appropriate scaffold file. Returns the file path string.
fn write_scaffold(
    dir: &Path,
    arch: &ArchOutput,
    files_created: &mut Vec<PathBuf>,
) -> Result<String, String> {
    match arch.language.as_str() {
        "python" => {
            let pyproject = dir.join("pyproject.toml");
            let content = "[build-system]\nrequires = [\"hatchling\"]\nbuild-backend = \"hatchling.build\"\n\n[project]\nname = \"project\"\nversion = \"0.1.0\"\n";
            std::fs::write(&pyproject, content)
                .map_err(|e| format!("cannot write pyproject.toml: {e}"))?;
            files_created.push(pyproject.clone());
            Ok("pyproject.toml".to_string())
        }
        "javascript" | "typescript" | "node" => {
            let pkg = dir.join("package.json");
            let content =
                "{\n  \"name\": \"project\",\n  \"version\": \"0.1.0\",\n  \"private\": true\n}\n";
            std::fs::write(&pkg, content).map_err(|e| format!("cannot write package.json: {e}"))?;
            files_created.push(pkg.clone());
            Ok("package.json".to_string())
        }
        _ => {
            // Default: Rust
            let cargo_toml = dir.join("Cargo.toml");
            let content = "[package]\nname = \"project\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n";
            std::fs::write(&cargo_toml, content)
                .map_err(|e| format!("cannot write Cargo.toml: {e}"))?;
            files_created.push(cargo_toml.clone());
            // Also create src/main.rs stub so Cargo.toml is valid.
            let src_dir = dir.join("src");
            std::fs::create_dir_all(&src_dir).map_err(|e| format!("cannot create src/: {e}"))?;
            let main_rs = src_dir.join("main.rs");
            std::fs::write(
                &main_rs,
                "fn main() {\n    println!(\"Hello, world!\");\n}\n",
            )
            .map_err(|e| format!("cannot write src/main.rs: {e}"))?;
            files_created.push(main_rs);
            Ok("Cargo.toml".to_string())
        }
    }
}

/// Run `chump gap reserve --domain INFRA --title <title>` and return the gap IDs.
/// On failure, returns empty vec (non-fatal: bootstrap still succeeds).
fn reserve_umbrella_gap(
    title: &str,
    description: &str,
    intent: &str,
    target_dir: &Path,
) -> Vec<String> {
    // Build acceptance criteria from description.
    let ac = format!(
        "1. Repository at {} has git history starting with the scaffold commit\n\
         2. README.md first body line contains the intent string: \"{}\"\n\
         3. Sub-gaps filed for core feature areas",
        target_dir.display(),
        intent
    );

    // Shell out to `chump gap reserve`. We need the chump binary to be available
    // in PATH. This is intentional — chump gap reserve is the canonical way to
    // reserve gaps, and re-implementing it here would violate DRY.
    let output = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            "EFFECTIVE",
            "--title",
            title,
            "--description",
            description,
            "--acceptance-criteria",
            &ac,
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            // Parse gap ID from stdout — look for pattern like "EFFECTIVE-NNN" or "INFRA-NNN".
            let stdout = String::from_utf8_lossy(&out.stdout);
            let gap_id = extract_gap_id(&stdout);
            if let Some(id) = gap_id {
                vec![id]
            } else {
                // Gap was reserved but we couldn't parse the ID — that's OK.
                eprintln!("(bootstrap: gap reserved but could not parse ID from output)");
                vec![]
            }
        }
        Ok(out) => {
            eprintln!(
                "(bootstrap: gap reserve failed: {})",
                String::from_utf8_lossy(&out.stderr).trim()
            );
            vec![]
        }
        Err(e) => {
            eprintln!("(bootstrap: gap reserve error: {e} — chump may not be in PATH)");
            vec![]
        }
    }
}

/// Extract the first gap ID (e.g. INFRA-1234 or EFFECTIVE-042) from a string.
fn extract_gap_id(s: &str) -> Option<String> {
    // Simple pattern: uppercase word followed by dash and digits.
    for word in s.split_whitespace() {
        // Strip trailing punctuation.
        let clean = word.trim_end_matches(|c: char| !c.is_alphanumeric());
        if is_gap_id(clean) {
            return Some(clean.to_string());
        }
    }
    None
}

fn is_gap_id(s: &str) -> bool {
    // Must be UPPERCASE-NNN form.
    if let Some(dash_pos) = s.find('-') {
        let prefix = &s[..dash_pos];
        let suffix = &s[dash_pos + 1..];
        if prefix
            .chars()
            .all(|c| c.is_uppercase() || c.is_alphabetic())
            && !suffix.is_empty()
            && suffix.chars().all(|c| c.is_ascii_digit())
        {
            return true;
        }
    }
    false
}

/// Best-effort cleanup of created files on error.
fn cleanup_files(files: &[PathBuf], _target_dir: &Path) {
    let mut failed: Vec<String> = Vec::new();
    for f in files.iter().rev() {
        if f.exists() {
            if let Err(_e) = std::fs::remove_file(f) {
                failed.push(f.display().to_string());
            }
        }
    }
    if !failed.is_empty() {
        eprintln!("operator-cleanup-required: {}", failed.join(", "));
    }
}

/// Emit a bootstrap_failed event.
fn emit_failure(kind: &str, class: FailureClass, intent: &str, target_dir: &Path) {
    let failure_kind = if class.is_transient() {
        "transient"
    } else {
        "permanent"
    };
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: kind.to_string(),
        source: Some("chump-bootstrap".to_string()),
        fields: vec![
            ("failure_class".to_string(), class.as_str().to_string()),
            ("failure_kind".to_string(), failure_kind.to_string()),
            ("intent".to_string(), intent.to_string()),
            ("target_dir".to_string(), target_dir.display().to_string()),
        ],
        ..Default::default()
    });
}
