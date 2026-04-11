//! Run a WASI WebAssembly module with fixed stdin and capture stdout/stderr.
//! Used by WASM tools (`wasm_calc`, `wasm_text`, …). No filesystem or network is granted by default.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const MAX_WASM_TEXT_INPUT_BYTES: usize = 8192;

/// Resolve `wasm/<filename>` relative to cwd, then next to the executable (same as `wasm_calc`).
pub fn wasm_artifact_path(filename: &str) -> PathBuf {
    let rel = PathBuf::from("wasm").join(filename);
    std::env::current_dir()
        .ok()
        .and_then(|cwd| {
            let p = cwd.join(&rel);
            if p.exists() {
                Some(p)
            } else {
                None
            }
        })
        .or_else(|| {
            let exe = std::env::current_exe().ok()?;
            let dir = exe.parent()?;
            let p = dir.join(&rel);
            if p.exists() {
                Some(p)
            } else {
                None
            }
        })
        .unwrap_or(rel)
}

/// Cap UTF-8 text passed into WASM tools (byte length).
#[inline]
pub fn clamp_wasm_text_input(text: &str) -> &str {
    if text.len() <= MAX_WASM_TEXT_INPUT_BYTES {
        return text;
    }
    let mut end = MAX_WASM_TEXT_INPUT_BYTES;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// Runs a WASI module at `wasm_path` with `stdin_bytes` as stdin.
/// Returns (stdout, stderr) as UTF-8 strings (non-UTF-8 is replaced with replacement char).
/// The module gets no preopened dirs, no env, and no network.
pub async fn run_wasm_wasi(wasm_path: &Path, stdin_bytes: &[u8]) -> Result<(String, String)> {
    let mut child = Command::new("wasmtime")
        .arg("run")
        .arg("--disable-cache")
        .arg(wasm_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("wasmtime not found: install wasmtime (e.g. brew install wasmtime)")?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(stdin_bytes).await?;
        stdin.shutdown().await?;
    }

    let out = child.wait_with_output().await?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();

    if !out.status.success() {
        anyhow::bail!("wasm exit {:?}: stderr: {}", out.status.code(), stderr);
    }

    Ok((stdout, stderr))
}
