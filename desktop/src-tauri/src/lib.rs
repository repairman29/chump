//! Tauri desktop shell: minimal IPC surface. Full orchestrator wiring comes later.

#[tauri::command]
fn ping_orchestrator() -> &'static str {
    "Chump desktop IPC ok"
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![ping_orchestrator])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
