//! Cross-platform host resource probes (disk, RAM, CPU, load, cargo build jobs)
//! with zero subprocess shell-outs (`statvfs` / `sysctlbyname` / `sysconf` on
//! Unix; `GetDiskFreeSpaceExW` / `GlobalMemoryStatusEx` on Windows).

use std::path::{Path, PathBuf};

const BYTES_PER_GIB: f64 = 1_073_741_824.0;

fn nearest_existing_path(path: &Path) -> PathBuf {
    for ancestor in path.ancestors() {
        if !ancestor.as_os_str().is_empty() && ancestor.exists() {
            return ancestor.to_path_buf();
        }
    }
    std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir())
}

/// Available free disk space (in GiB) accessible to the current caller on the
/// filesystem containing `path` (or its nearest existing ancestor).
///
/// Uses `statvfs` on Unix and `GetDiskFreeSpaceExW` on Windows with zero shell-outs.
pub fn free_disk_gb(path: &Path) -> Option<f64> {
    let target = nearest_existing_path(path);

    #[cfg(unix)]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let c_path = CString::new(target.as_os_str().as_bytes()).ok()?;
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };
        if rc != 0 {
            return None;
        }
        // Cast both fields to u128 because f_bavail / f_frsize widths vary
        // across macOS (u32/u64), Linux glibc (u64), and 32-bit Unix targets.
        #[allow(clippy::unnecessary_cast)]
        let free_bytes = (stat.f_bavail as u128).saturating_mul(stat.f_frsize as u128);
        Some(free_bytes as f64 / BYTES_PER_GIB)
    }

    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let wide: Vec<u16> = target
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut free_avail: u64 = 0;
        let ok = unsafe {
            crate::win32::GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free_avail,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            return None;
        }
        Some(free_avail as f64 / BYTES_PER_GIB)
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = target;
        None
    }
}

/// Total physical RAM in GiB on the current host, with zero shell-outs.
pub fn total_ram_gb() -> Option<f64> {
    #[cfg(target_os = "macos")]
    {
        let mut mem_bytes: u64 = 0;
        let mut len = std::mem::size_of::<u64>();
        let name = c"hw.memsize";
        let rc = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                (&mut mem_bytes as *mut u64).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc == 0 && mem_bytes > 0 {
            return Some(mem_bytes as f64 / BYTES_PER_GIB);
        }
        None
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let pages = unsafe { libc::sysconf(libc::_SC_PHYS_PAGES) };
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        if pages > 0 && page_size > 0 {
            let total = (pages as u128).saturating_mul(page_size as u128);
            return Some(total as f64 / BYTES_PER_GIB);
        }
        // Fallback to /proc/meminfo if sysconf is unavailable on an exotic libc.
        if let Ok(text) = std::fs::read_to_string("/proc/meminfo") {
            let kb: f64 = text
                .lines()
                .find(|l| l.starts_with("MemTotal:"))?
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()?;
            return Some(kb / 1_048_576.0);
        }
        None
    }

    #[cfg(windows)]
    {
        let mut status: crate::win32::MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
        status.dwLength = std::mem::size_of::<crate::win32::MEMORYSTATUSEX>() as u32;
        let ok = unsafe { crate::win32::GlobalMemoryStatusEx(&mut status) };
        if ok != 0 && status.ullTotalPhys > 0 {
            Some(status.ullTotalPhys as f64 / BYTES_PER_GIB)
        } else {
            None
        }
    }

    #[cfg(not(any(unix, windows)))]
    {
        None
    }
}

/// Number of logical CPUs available to the current process (at least 1).
pub fn available_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .max(1)
}

/// Pure calculation of safe `CARGO_BUILD_JOBS` given optional physical RAM (GiB)
/// and logical CPU count: budgets half of physical RAM at ~1.2 GiB per `rustc`
/// job, clamped to `1..=cpus` (falling back to `4.min(cpus)` when RAM is unknown).
pub fn derive_cargo_build_jobs_from(total_ram_gb: Option<f64>, cpus: usize) -> usize {
    let cpus = cpus.max(1);
    match total_ram_gb {
        Some(gb) if gb > 0.0 => (((gb * 0.5) / 1.2) as usize).clamp(1, cpus),
        _ => 4.min(cpus),
    }
}

/// Derive safe `CARGO_BUILD_JOBS` for the current host.
pub fn derive_cargo_build_jobs() -> usize {
    derive_cargo_build_jobs_from(total_ram_gb(), available_cpus())
}

/// 1-minute OS load average on Unix (`getloadavg`), or `0.0` on platforms
/// without POSIX load averages (Windows), where callers fail-open.
pub fn load_average_1m() -> f64 {
    #[cfg(unix)]
    {
        let mut avg = [0.0f64; 1];
        let n = unsafe { libc::getloadavg(avg.as_mut_ptr(), 1) };
        if n == 1 {
            avg[0]
        } else {
            0.0
        }
    }
    #[cfg(not(unix))]
    {
        0.0
    }
}
