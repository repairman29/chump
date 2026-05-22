//! INFRA-941 — ambient.jsonl rotation at configurable size threshold.
//!
//! When ambient.jsonl exceeds the threshold (default 50 MB), it is renamed
//! to ambient.jsonl.1. A prior .1 becomes .2; a prior .2 is deleted. The
//! rename is the atomic step — after it completes, the next append creates a
//! fresh ambient.jsonl. At most 2 rotated files are kept alongside the active
//! log.
//!
//! Override with CHUMP_AMBIENT_MAX_MB environment variable.

use std::path::Path;

/// Default rotation threshold: 10 MB (lowered from 50 MB — INFRA-1468).
///
/// At 50 MB the file caused measurable endpoint hangs (INFRA-1464 / INFRA-1466).
/// 10 MB is small enough that reads stay fast while still allowing reasonable burst.
/// Override via CHUMP_AMBIENT_MAX_MB environment variable.
pub const DEFAULT_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Read CHUMP_AMBIENT_MAX_MB from the environment. Falls back to DEFAULT_MAX_BYTES.
pub fn max_bytes() -> u64 {
    std::env::var("CHUMP_AMBIENT_MAX_MB")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(|mb| mb * 1024 * 1024)
        .unwrap_or(DEFAULT_MAX_BYTES)
}

/// Check `ambient_path` size and rotate if it exceeds the threshold.
///
/// Rotation sequence (each rename is atomic on Unix):
///   ambient.jsonl.2  →  deleted
///   ambient.jsonl.1  →  ambient.jsonl.2
///   ambient.jsonl    →  ambient.jsonl.1
///
/// Returns `true` if rotation was performed.
pub fn rotate_if_needed(ambient_path: &Path) -> bool {
    let threshold = max_bytes();
    let size = match std::fs::metadata(ambient_path) {
        Ok(m) => m.len(),
        Err(_) => return false,
    };
    if size < threshold {
        return false;
    }

    let dir = ambient_path.parent().unwrap_or(Path::new("."));
    let name = ambient_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("ambient.jsonl");

    let slot1 = dir.join(format!("{}.1", name));
    let slot2 = dir.join(format!("{}.2", name));

    // Remove .2 if present.
    let _ = std::fs::remove_file(&slot2);
    // Rotate .1 → .2 if present.
    if slot1.exists() {
        let _ = std::fs::rename(&slot1, &slot2);
    }
    // Rotate current → .1 (atomic step).
    std::fs::rename(ambient_path, &slot1).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::io::Write as _;

    fn tempdir() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!(
            "chump-ambient-rotate-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    #[serial]
    fn no_rotation_below_threshold() {
        let dir = tempdir();
        let path = dir.join("ambient.jsonl");
        std::fs::write(&path, b"small content").unwrap();
        // Use a very large threshold so file is below it.
        std::env::set_var("CHUMP_AMBIENT_MAX_MB", "9999");
        let rotated = rotate_if_needed(&path);
        std::env::remove_var("CHUMP_AMBIENT_MAX_MB");
        assert!(!rotated, "should not rotate below threshold");
        assert!(path.exists(), "ambient.jsonl still present");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn rotation_triggers_at_threshold() {
        let dir = tempdir();
        let path = dir.join("ambient.jsonl");
        // Write exactly 1 byte over 1MB threshold.
        let data = vec![b'x'; 1024 * 1024 + 1];
        std::fs::write(&path, &data).unwrap();
        std::env::set_var("CHUMP_AMBIENT_MAX_MB", "1");
        let rotated = rotate_if_needed(&path);
        std::env::remove_var("CHUMP_AMBIENT_MAX_MB");
        assert!(rotated, "should rotate at threshold");
        assert!(!path.exists(), "ambient.jsonl renamed away");
        assert!(dir.join("ambient.jsonl.1").exists(), ".1 created");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn old_slot2_pruned_on_rotation() {
        let dir = tempdir();
        let path = dir.join("ambient.jsonl");
        // Pre-populate .1 and .2.
        std::fs::write(dir.join("ambient.jsonl.1"), b"old-1").unwrap();
        std::fs::write(dir.join("ambient.jsonl.2"), b"old-2").unwrap();
        let data = vec![b'x'; 1024 * 1024 + 1];
        std::fs::write(&path, &data).unwrap();
        std::env::set_var("CHUMP_AMBIENT_MAX_MB", "1");
        let rotated = rotate_if_needed(&path);
        std::env::remove_var("CHUMP_AMBIENT_MAX_MB");
        assert!(rotated, "rotation happened");
        assert!(
            !dir.join("ambient.jsonl.2").exists() || {
                // .2 may exist as the renamed .1; the OLD .2 (b"old-2") should be gone
                let contents = std::fs::read(dir.join("ambient.jsonl.2")).unwrap_or_default();
                contents != b"old-2"
            },
            "old .2 should be replaced, not original old-2"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[serial]
    fn append_after_rotation_creates_fresh_file() {
        let dir = tempdir();
        let path = dir.join("ambient.jsonl");
        let data = vec![b'x'; 1024 * 1024 + 1];
        std::fs::write(&path, &data).unwrap();
        std::env::set_var("CHUMP_AMBIENT_MAX_MB", "1");
        rotate_if_needed(&path);
        std::env::remove_var("CHUMP_AMBIENT_MAX_MB");
        // Simulate a fresh append.
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        writeln!(f, "{{\"kind\":\"test\"}}").unwrap();
        drop(f);
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("test"), "fresh file has new content");
        assert!(content.len() < 100, "fresh file is small");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
