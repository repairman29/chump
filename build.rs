// INFRA-148: bake git commit SHA + build date into the binary so
// `chump gap ship --update-yaml` / `chump gap dump --out PATH` can detect
// when the operator's binary is older than the gap_store-affecting code on
// origin/main and warn before silently corrupting docs/gaps.yaml.
//
// Outputs two cargo env vars consumed by `src/version.rs`:
//   CHUMP_BUILD_SHA  — short SHA of HEAD at build time, or "unknown"
//   CHUMP_BUILD_DATE — UTC date of HEAD commit (yyyy-mm-dd), or "unknown"
//
// Cache invalidation:
//   - Re-run when .git/HEAD changes (commit / branch switch)
//   - Re-run when .git/refs/heads/* tip moves
//
// Failure mode is "unknown", not panic — building outside a git checkout
// (cargo install --git URL, packaged source) still works; staleness check
// at runtime treats "unknown" as "skip the check, no info to compare".

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-changed=.git/refs/heads");
    // Also re-run if the baked SHA explicitly overridden in the environment.
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_SHA");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_DATE");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_GIT_SHA");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_TIMESTAMP");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_RUSTC");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_WORKSPACE_ROOT");

    let sha = std::env::var("CHUMP_BUILD_SHA")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            Command::new("git")
                .args(["rev-parse", "--short=12", "HEAD"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "unknown".to_string());

    let date = std::env::var("CHUMP_BUILD_DATE")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            Command::new("git")
                .args(["log", "-1", "--format=%cs", "HEAD"]) // %cs = committer date YYYY-MM-DD
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .unwrap_or_else(|| "unknown".to_string());

    println!("cargo:rustc-env=CHUMP_BUILD_SHA={sha}");
    println!("cargo:rustc-env=CHUMP_BUILD_DATE={date}");

    // INFRA-2054 (META-114 freshness cluster, binary-staleness layer):
    // four NEW env vars consumed by `src/staleness.rs` via env!() to power
    // `chump --build-info` + `chump self-check-staleness`. These are
    // deliberately separate from the INFRA-148 vars above (short SHA vs
    // full SHA, build-time vs commit-time, etc.) so the two consumers
    // stay independent.

    // Full (not short) git SHA for HEAD at build time. Fallback sentinel
    // is "unknown-no-git-context" rather than "unknown" so downstream
    // probes can distinguish "build outside a git checkout" from "build
    // inside a git checkout but git failed for some other reason"
    // (we only emit "unknown-no-git-context" right now, but the sentinel
    // is explicit about its meaning).
    let git_sha_full = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown-no-git-context".to_string());

    // UTC build timestamp in ISO-8601 form (YYYY-MM-DDTHH:MM:SSZ). Generated
    // by the build host's `date -u` so it tracks the BUILD time, not the
    // commit time (CHUMP_BUILD_DATE above is the commit date). Falls back
    // to a sentinel if `date` itself isn't on PATH (very unlikely).
    let build_ts = Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());

    // rustc version string — `rustc --version` output verbatim.
    let rustc_version =
        Command::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string()))
            .arg("--version")
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string());

    // Absolute workspace root path (CARGO_MANIFEST_DIR points at the package
    // being built — for the top-level chump crate that's also the workspace
    // root). Used by the staleness probe to locate .git/ at runtime.
    let workspace_root =
        std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| "unknown".to_string());

    println!("cargo:rustc-env=CHUMP_BUILD_GIT_SHA={git_sha_full}");
    println!("cargo:rustc-env=CHUMP_BUILD_TIMESTAMP={build_ts}");
    println!("cargo:rustc-env=CHUMP_BUILD_RUSTC={rustc_version}");
    println!("cargo:rustc-env=CHUMP_BUILD_WORKSPACE_ROOT={workspace_root}");
}
