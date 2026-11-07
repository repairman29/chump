use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_GIT_SHA");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    let sha = std::env::var("CHUMP_BUILD_GIT_SHA")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            Command::new("git")
                .args(["rev-parse", "HEAD"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let short: String = sha.chars().take(7).collect();
    println!("cargo:rustc-env=CHUMPD_GIT_SHA={short}");
}
