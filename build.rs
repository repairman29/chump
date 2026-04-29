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
}
