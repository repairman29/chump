//! When `chump` is run with `--desktop`, re-exec the `chump-desktop` Tauri binary from the same directory.

use std::process::Command;

pub fn launch_and_wait(args: &[String]) -> ! {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("chump --desktop: could not resolve current exe: {}", e);
            std::process::exit(2);
        }
    };
    let dir = exe.parent().unwrap_or_else(|| {
        eprintln!("chump --desktop: exe has no parent directory");
        std::process::exit(2);
    });
    let desktop_bin = if cfg!(target_os = "windows") {
        dir.join("chump-desktop.exe")
    } else {
        dir.join("chump-desktop")
    };
    if !desktop_bin.is_file() {
        eprintln!(
            "chump --desktop: '{}' not found.\n\
             Build the desktop shell first:\n\
               cargo build -p chump-desktop\n\
             Then run again (both binaries live under target/debug or target/release).",
            desktop_bin.display()
        );
        std::process::exit(2);
    }

    let child_args: Vec<&str> = args
        .iter()
        .skip(1)
        .filter(|a| *a != "--desktop")
        .map(|s| s.as_str())
        .collect();

    let status = Command::new(&desktop_bin)
        .args(child_args)
        .status()
        .unwrap_or_else(|e| {
            eprintln!(
                "chump --desktop: failed to spawn {}: {}",
                desktop_bin.display(),
                e
            );
            std::process::exit(2);
        });
    std::process::exit(status.code().unwrap_or(1));
}
