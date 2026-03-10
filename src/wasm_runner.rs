//! Run a WASI WebAssembly module with fixed stdin and capture stdout/stderr.
//! Used by the wasm_calc tool. No filesystem or network is granted by default.

use anyhow::{Context, Result};
use std::path::Path;
use std::process::Stdio;
use tokio::process::Command;
use tokio::io::AsyncWriteExt;

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
