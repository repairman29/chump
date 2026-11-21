//! Minimal Win32 `kernel32` FFI declarations for `#[cfg(windows)]`.
//!
//! `kernel32` is linked unconditionally by Rust `std` on every Windows target
//! (`x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`, `x86_64-pc-windows-gnu`),
//! avoiding extra crate/feature churn while providing native zero-shell-out
//! OS primitives.

#![cfg(windows)]
#![allow(non_snake_case, clippy::upper_case_acronyms)]

use std::ffi::c_void;

pub type HANDLE = *mut c_void;
pub type BOOL = i32;
pub type DWORD = u32;

pub const PROCESS_TERMINATE: DWORD = 0x0001;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const STILL_ACTIVE: DWORD = 259;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_INVALID_PARAMETER: DWORD = 87;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const CTRL_LOGOFF_EVENT: DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;

pub const LOCKFILE_EXCLUSIVE_LOCK: DWORD = 0x0000_0002;

#[repr(C)]
pub struct MEMORYSTATUSEX {
    pub dwLength: DWORD,
    pub dwMemoryLoad: DWORD,
    pub ullTotalPhys: u64,
    pub ullAvailPhys: u64,
    pub ullTotalPageFile: u64,
    pub ullAvailPageFile: u64,
    pub ullTotalVirtual: u64,
    pub ullAvailVirtual: u64,
    pub ullAvailExtendedVirtual: u64,
}

#[repr(C)]
pub struct OVERLAPPED {
    pub Internal: usize,
    pub InternalHigh: usize,
    pub Offset: DWORD,
    pub OffsetHigh: DWORD,
    pub hEvent: HANDLE,
}

#[link(name = "kernel32")]
extern "system" {
    pub fn GetDiskFreeSpaceExW(
        lpDirectoryName: *const u16,
        lpFreeBytesAvailableToCaller: *mut u64,
        lpTotalNumberOfBytes: *mut u64,
        lpTotalNumberOfFreeBytes: *mut u64,
    ) -> BOOL;

    pub fn GlobalMemoryStatusEx(lpBuffer: *mut MEMORYSTATUSEX) -> BOOL;

    pub fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) -> HANDLE;

    pub fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *mut DWORD) -> BOOL;

    pub fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) -> BOOL;

    pub fn CloseHandle(hObject: HANDLE) -> BOOL;

    pub fn GetLastError() -> DWORD;

    pub fn SetConsoleCtrlHandler(
        HandlerRoutine: Option<unsafe extern "system" fn(DWORD) -> BOOL>,
        Add: BOOL,
    ) -> BOOL;

    pub fn LockFileEx(
        hFile: HANDLE,
        dwFlags: DWORD,
        dwReserved: DWORD,
        nNumberOfBytesToLockLow: DWORD,
        nNumberOfBytesToLockHigh: DWORD,
        lpOverlapped: *mut OVERLAPPED,
    ) -> BOOL;

    pub fn UnlockFileEx(
        hFile: HANDLE,
        dwReserved: DWORD,
        nNumberOfBytesToUnlockLow: DWORD,
        nNumberOfBytesToUnlockHigh: DWORD,
        lpOverlapped: *mut OVERLAPPED,
    ) -> BOOL;
}
