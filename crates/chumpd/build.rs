fn main() {
    println!("cargo:rerun-if-env-changed=CHUMP_BUILD_SHA");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    let sha = std::env::var("CHUMP_BUILD_SHA")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            std::process::Command::new("git")
                .args(["rev-parse", "--short", "HEAD"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        })
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=CHUMPD_BUILD_SHA={sha}");
}
