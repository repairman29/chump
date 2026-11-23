//! Portable home, state, temp-file paths, restricted file permissions (`0o600`),
//! and cross-platform advisory file locking (`flock` on Unix, `LockFileEx` on Windows).

use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};

fn env_nonempty_path(var: &str) -> Option<PathBuf> {
    let val = std::env::var(var).ok()?;
    let trimmed = val.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(PathBuf::from(trimmed))
    }
}

/// Resolve the current user's home directory across Unix (`HOME`) and Windows
/// (`HOME` -> `USERPROFILE` -> `HOMEDRIVE` + `HOMEPATH`), falling back to
/// [`std::env::temp_dir`] (never a hardcoded `"/tmp"`).
pub fn user_home() -> PathBuf {
    if let Some(h) = env_nonempty_path("HOME") {
        return h;
    }
    if let Some(up) = env_nonempty_path("USERPROFILE") {
        return up;
    }
    if let (Ok(drive), Ok(path)) = (std::env::var("HOMEDRIVE"), std::env::var("HOMEPATH")) {
        let combined = format!("{}{}", drive.trim(), path.trim());
        if !combined.is_empty() {
            return PathBuf::from(combined);
        }
    }
    std::env::temp_dir()
}

/// Resolve the base directory that owns `.chump` (and sibling `.claude` under
/// hermetic `CHUMP_HOME` overrides):
/// - If `CHUMP_HOME` is set to `/path/to/.chump`, returns `/path/to`.
/// - If `CHUMP_HOME` is set to `/path/to/home`, returns `/path/to/home`.
/// - Otherwise returns [`user_home`].
pub fn state_base_dir() -> PathBuf {
    if let Some(ch) = env_nonempty_path("CHUMP_HOME") {
        if ch.file_name() == Some(OsStr::new(".chump")) {
            if let Some(parent) = ch.parent() {
                if !parent.as_os_str().is_empty() {
                    return parent.to_path_buf();
                }
            }
        }
        return ch;
    }
    user_home()
}

/// Resolve the `.chump` state directory (`CHUMP_HOME` -> `HOME` / `USERPROFILE` + `.chump`
/// -> `std::env::temp_dir().join(".chump")`).
///
/// Handles both `CHUMP_HOME=/custom/home` (yields `/custom/home/.chump`, matching
/// Chump's existing test & config convention) and `CHUMP_HOME=/custom/home/.chump`
/// (yields `/custom/home/.chump` without double-appending `.chump`).
pub fn chump_home() -> PathBuf {
    if let Some(ch) = env_nonempty_path("CHUMP_HOME") {
        if ch.file_name() == Some(OsStr::new(".chump")) {
            return ch;
        }
        return ch.join(".chump");
    }
    user_home().join(".chump")
}

/// System temporary directory (`std::env::temp_dir()`).
pub fn temp_dir() -> PathBuf {
    std::env::temp_dir()
}

/// Build a temporary file path inside [`temp_dir`] after sanitizing path separators
/// in `name` so callers cannot traverse outside the temp directory.
pub fn temp_file_path(name: &str) -> PathBuf {
    let safe = name.replace(['/', '\\'], "_");
    std::env::temp_dir().join(safe)
}

/// Restrict `path` to owner-only read/write (`0o600` on Unix; clears read-only
/// flag / safe no-op on Windows where per-user profile & temp dirs inherit user ACLs).
pub fn restrict_file_permissions(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)?.permissions();
        perms.set_mode(0o600);
        std::fs::set_permissions(path, perms)
    }

    #[cfg(windows)]
    {
        let mut perms = std::fs::metadata(path)?.permissions();
        if perms.readonly() {
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            std::fs::set_permissions(path, perms)?;
        }
        Ok(())
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Ok(())
    }
}

/// Execute `f` while holding a cross-platform exclusive advisory lock on `lock_path`
/// (`flock(LOCK_EX)` on Unix; `LockFileEx(LOCKFILE_EXCLUSIVE_LOCK)` on Windows).
/// Best-effort: if `lock_path` cannot be opened, `f` still executes (fail-open).
pub fn with_file_lock<T>(lock_path: &Path, f: impl FnOnce() -> T) -> T {
    if let Some(parent) = lock_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(lock_path)
        .ok();

    #[cfg(unix)]
    if let Some(ref file) = lock_file {
        use std::os::unix::io::AsRawFd;
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_EX);
        }
    }

    #[cfg(windows)]
    if let Some(ref file) = lock_file {
        use std::os::windows::io::AsRawHandle;
        let mut overlapped: crate::win32::OVERLAPPED = unsafe { std::mem::zeroed() };
        unsafe {
            let _ = crate::win32::LockFileEx(
                file.as_raw_handle() as crate::win32::HANDLE,
                crate::win32::LOCKFILE_EXCLUSIVE_LOCK,
                0,
                1,
                0,
                &mut overlapped,
            );
        }
    }

    let out = f();

    #[cfg(unix)]
    if let Some(ref file) = lock_file {
        use std::os::unix::io::AsRawFd;
        unsafe {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
    }

    #[cfg(windows)]
    if let Some(ref file) = lock_file {
        use std::os::windows::io::AsRawHandle;
        let mut overlapped: crate::win32::OVERLAPPED = unsafe { std::mem::zeroed() };
        unsafe {
            let _ = crate::win32::UnlockFileEx(
                file.as_raw_handle() as crate::win32::HANDLE,
                0,
                1,
                0,
                &mut overlapped,
            );
        }
    }

    out
}

/// Create a filesystem symlink (or copy fallback on Windows without Developer Mode
/// symlink privilege) from `link` pointing to `target`.
pub fn symlink_or_copy_file(target: &Path, link: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link)
    }

    #[cfg(windows)]
    {
        match std::os::windows::fs::symlink_file(target, link) {
            Ok(()) => Ok(()),
            Err(e) => {
                // On Windows without SeCreateSymbolicLinkPrivilege / Developer Mode,
                // hard_link or copy keeps worktree bootstrap functional.
                if target.is_file() {
                    std::fs::hard_link(target, link)
                        .or_else(|_| std::fs::copy(target, link).map(|_| ()))
                } else {
                    Err(e)
                }
            }
        }
    }
}
