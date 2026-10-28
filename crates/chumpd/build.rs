// RESILIENT-1738: bake the git SHA into the chumpd binary so `chumpd
// --version` can print it without executing the supervisor (and therefore
// without the host-wide takeover() sweep a plain-argv invocation used to
// trigger). Mirrors the root build.rs (INFRA-148) pattern, scoped to this
// crate — chumpd is a separate compilation unit so it needs its own
// cargo:rustc-env, not the workspace root's.
//
// Failure mode is "unknown", not panic — building outside a git checkout
// still works; `chumpd --version` just prints "unknown" for the sha.

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/refs/heads");
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_SHA");

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

    println!("cargo:rustc-env=CHUMPD_BUILD_SHA={sha}");
}
