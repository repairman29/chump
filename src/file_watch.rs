//! Live file watch: notify watcher on repo root; assemble_context drains "what changed since last run".
//! Near-zero CPU when idle; instant awareness on save between heartbeat rounds.

use notify::Watcher;
use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

type ReceiverGuard = Option<Mutex<Receiver<PathBuf>>>;
static RECEIVER: OnceLock<ReceiverGuard> = OnceLock::new();

fn init_receiver() -> Option<Mutex<Receiver<PathBuf>>> {
    if !crate::repo_path::repo_root_is_explicit() {
        return None;
    }
    let root = crate::repo_path::repo_root();
    let (tx, rx) = std::sync::mpsc::channel();
    let root_watch = root.clone();
    let _ = std::thread::spawn(move || {
        let mut watcher = match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(ev) = res {
                for path in ev.paths {
                    let _ = tx.send(path);
                }
            }
        }) {
            Ok(w) => w,
            Err(_) => return,
        };
        if watcher.watch(&root_watch, notify::RecursiveMode::Recursive).is_err() {
            return;
        }
        loop {
            std::thread::sleep(Duration::from_secs(86400));
        }
    });
    Some(Mutex::new(rx))
}

/// Drain all pending file-change paths since last drain. Returns paths relative to repo root.
/// Call from assemble_context to inject "Files changed since last run" when non-empty.
pub fn drain_recent_changes() -> Vec<String> {
    let opt = RECEIVER.get_or_init(init_receiver);
    let guard = match opt.as_ref() {
        Some(g) => g,
        None => return Vec::new(),
    };
    let rx = match guard.lock() {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let root = crate::repo_path::repo_root();
    let mut out = Vec::new();
    while let Ok(path) = rx.try_recv() {
        let rel = path
            .strip_prefix(&root)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        if !rel.is_empty() && !rel.starts_with(".git/") && !rel.contains("/.git/") {
            out.push(rel);
        }
    }
    out.sort();
    out.dedup();
    out
}
