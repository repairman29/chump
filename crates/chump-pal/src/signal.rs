//! Cross-platform graceful shutdown signal handling for both synchronous loops
//! (`install_shutdown_signal`) and async Tokio daemons (`wait_for_shutdown_signal`).

use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering};

/// Conventional POSIX signal number for SIGINT / Ctrl+C.
pub const SIGINT_NUM: i32 = 2;
/// Conventional POSIX signal number for SIGTERM / graceful termination.
pub const SIGTERM_NUM: i32 = 15;

/// Map a shutdown signal number (`0` = clean internal stop) to a conventional
/// `128 + signum` exit code (`130` for SIGINT, `143` for SIGTERM).
pub fn exit_code_for_signal(sig: i32) -> i32 {
    if sig <= 0 {
        0
    } else {
        128 + sig
    }
}

static SYNC_SHUTDOWN_TARGET: AtomicPtr<AtomicI32> = AtomicPtr::new(std::ptr::null_mut());

#[cfg(unix)]
extern "C" fn unix_signal_handler(sig: i32) {
    let ptr = SYNC_SHUTDOWN_TARGET.load(Ordering::SeqCst);
    if !ptr.is_null() {
        // SAFETY: `install_shutdown_signal` only accepts `&'static AtomicI32`.
        unsafe { (*ptr).store(sig, Ordering::SeqCst) };
    }
}

#[cfg(windows)]
unsafe extern "system" fn windows_ctrl_handler(
    ctrl_type: crate::win32::DWORD,
) -> crate::win32::BOOL {
    let sig = match ctrl_type {
        crate::win32::CTRL_C_EVENT | crate::win32::CTRL_BREAK_EVENT => SIGINT_NUM,
        crate::win32::CTRL_CLOSE_EVENT
        | crate::win32::CTRL_LOGOFF_EVENT
        | crate::win32::CTRL_SHUTDOWN_EVENT => SIGTERM_NUM,
        _ => return 0,
    };
    let ptr = SYNC_SHUTDOWN_TARGET.load(Ordering::SeqCst);
    if !ptr.is_null() {
        (*ptr).store(sig, Ordering::SeqCst);
        return 1;
    }
    0
}

/// Register a process-wide shutdown handler that stores [`SIGINT_NUM`] (`2`) or
/// [`SIGTERM_NUM`] (`15`) into `target` on Ctrl+C / SIGINT / SIGTERM / console close.
pub fn install_shutdown_signal(target: &'static AtomicI32) {
    SYNC_SHUTDOWN_TARGET.store(std::ptr::from_ref(target).cast_mut(), Ordering::SeqCst);

    #[cfg(unix)]
    unsafe {
        let handler = unix_signal_handler as extern "C" fn(i32) as *const () as usize;
        libc::signal(libc::SIGINT, handler);
        libc::signal(libc::SIGTERM, handler);
    }

    #[cfg(windows)]
    unsafe {
        let _ = crate::win32::SetConsoleCtrlHandler(Some(windows_ctrl_handler), 1);
    }
}

/// Await Ctrl+C (`SIGINT_NUM`) or Unix `SIGTERM` (`SIGTERM_NUM`) asynchronously
/// inside a Tokio runtime, returning the signal number (`2` or `15`).
pub async fn wait_for_shutdown_signal() -> i32 {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm = signal(SignalKind::terminate()).ok();
        tokio::select! {
            _ = tokio::signal::ctrl_c() => SIGINT_NUM,
            _ = async {
                match sigterm.as_mut() {
                    Some(s) => { let _ = s.recv().await; }
                    None => std::future::pending::<()>().await,
                }
            } => SIGTERM_NUM,
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
        SIGINT_NUM
    }
}
