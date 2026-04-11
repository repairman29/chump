//! Tauri binary entry (`chump-desktop`). Launched directly or via `chump --desktop`.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    chump_desktop_lib::run();
}
