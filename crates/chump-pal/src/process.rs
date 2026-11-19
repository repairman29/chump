//! Cross-platform process liveness, process/group termination, and isolated
//! child spawning for macOS, Linux, and Windows.

use std::io;
use std::process::{Command, ExitStatus};

/// Returns `true` if `pid` refers to a currently live OS process.
pub fn is_pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }

    #[cfg(unix)]
    {
        if pid > i32::MAX as u32 {
            return false;
        }
        let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
        if rc == 0 {
            return true;
        }
        io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }

    #[cfg(windows)]
    {
        let handle = unsafe {
            crate::win32::OpenProcess(crate::win32::PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        };
        if handle.is_null() {
            return unsafe { crate::win32::GetLastError() } == crate::win32::ERROR_ACCESS_DENIED;
        }
        let mut exit_code: u32 = 0;
        let ok = unsafe { crate::win32::GetExitCodeProcess(handle, &mut exit_code) };
        unsafe {
            crate::win32::CloseHandle(handle);
        }
        ok != 0 && exit_code == crate::win32::STILL_ACTIVE
    }

    #[cfg(not(any(unix, windows)))]
    {
        false
    }
}

/// Parent process ID on Unix (`getppid()`), or `None` on platforms without cheap
/// parent-PID syscalls (callers fall back to `std::process::id()`).
pub fn parent_pid() -> Option<u32> {
    #[cfg(unix)]
    {
        let ppid = unsafe { libc::getppid() };
        if ppid > 1 {
            Some(ppid as u32)
        } else {
            None
        }
    }
    #[cfg(not(unix))]
    {
        None
    }
}

/// Terminate a single process by `pid`.
///
/// - On Unix: sends `SIGTERM` (`force = false`) or `SIGKILL` (`force = true`);
///   treats `ESRCH` (already exited) as `Ok(())`.
/// - On Windows: attempts graceful `taskkill /PID <pid>` when `force = false`,
///   otherwise opens the process handle and calls `TerminateProcess`.
pub fn terminate_process(pid: u32, force: bool) -> io::Result<()> {
    if pid <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("refusing to signal reserved pid {pid}"),
        ));
    }

    #[cfg(unix)]
    {
        let sig = if force { libc::SIGKILL } else { libc::SIGTERM };
        let rc = unsafe { libc::kill(pid as libc::pid_t, sig) };
        if rc == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(err)
        }
    }

    #[cfg(windows)]
    {
        if !is_pid_alive(pid) {
            return Ok(());
        }
        if !force {
            if let Ok(status) = Command::new("taskkill")
                .args(["/PID", &pid.to_string()])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
            {
                if status.success() || !is_pid_alive(pid) {
                    return Ok(());
                }
            }
        }
        let handle = unsafe { crate::win32::OpenProcess(crate::win32::PROCESS_TERMINATE, 0, pid) };
        if handle.is_null() {
            let code = unsafe { crate::win32::GetLastError() };
            if code == crate::win32::ERROR_INVALID_PARAMETER || !is_pid_alive(pid) {
                return Ok(());
            }
            return Err(io::Error::from_raw_os_error(code as i32));
        }
        let ok = unsafe { crate::win32::TerminateProcess(handle, 1) };
        let err = io::Error::last_os_error();
        unsafe {
            crate::win32::CloseHandle(handle);
        }
        if ok != 0 || !is_pid_alive(pid) {
            Ok(())
        } else {
            Err(err)
        }
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = force;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "terminate_process unsupported on target",
        ))
    }
}

/// Terminate an isolated child process group / process tree rooted at `pid`.
///
/// - On Unix: sends `SIGTERM` (`force = false`) or `SIGKILL` (`force = true`) to
///   `-pid` (process group created via [`configure_isolated_child`]), treating
///   `ESRCH` as `Ok(())`.
/// - On Windows: invokes `taskkill /PID <pid> /T` (plus `/F` when `force = true`)
///   to reap the entire child process tree, falling back to [`terminate_process`].
pub fn terminate_process_group(pid: u32, force: bool) -> io::Result<()> {
    if pid <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("refusing to signal reserved pgid {pid}"),
        ));
    }

    #[cfg(unix)]
    {
        let sig = if force { libc::SIGKILL } else { libc::SIGTERM };
        let rc = unsafe { libc::kill(-(pid as libc::pid_t), sig) };
        if rc == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::ESRCH) {
            Ok(())
        } else {
            Err(err)
        }
    }

    #[cfg(windows)]
    {
        if !is_pid_alive(pid) {
            return Ok(());
        }
        let pid_str = pid.to_string();
        let mut cmd = Command::new("taskkill");
        cmd.args(["/PID", &pid_str, "/T"]);
        if force {
            cmd.arg("/F");
        }
        cmd.stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if let Ok(status) = cmd.status() {
            if status.success() || !is_pid_alive(pid) {
                return Ok(());
            }
        }
        terminate_process(pid, force)
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = force;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "terminate_process_group unsupported on target",
        ))
    }
}

/// Configure `cmd` so the spawned child runs in its own isolated process group:
/// - Unix: `process_group(0)` (`pgid == child_pid`) + `PR_SET_PDEATHSIG(SIGTERM)` on Linux.
/// - Windows: `creation_flags(CREATE_NEW_PROCESS_GROUP)`.
pub fn configure_isolated_child(cmd: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
        #[cfg(target_os = "linux")]
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        cmd.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }
}

/// Construct a synthetic exit-code-0 [`ExitStatus`] portably across Unix and Windows.
pub fn success_exit_status() -> ExitStatus {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        ExitStatus::from_raw(0)
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::ExitStatusExt;
        ExitStatus::from_raw(0)
    }
}
