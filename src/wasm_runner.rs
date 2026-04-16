//! Run a WASI WebAssembly module with fixed stdin and capture stdout/stderr.
//! Used by WASM tools (`wasm_calc`, `wasm_text`, …). No filesystem or network is granted by default.

use anyhow::Result;
use std::path::{Path, PathBuf};

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

pub async fn run_wasm_wasi(wasm_path: &Path, stdin_bytes: &[u8]) -> Result<(String, String)> {
    use wasmtime::*;
    use wasmtime_wasi::WasiCtxBuilder;
    use wasmtime_wasi::pipe::{MemoryOutputPipe, MemoryInputPipe};

    // 10 million instructions as a safe upper bound for tool calls.
    const FUEL_LIMIT: u64 = 10_000_000;

    let mut config = Config::new();
    config.consume_fuel(true);
    config.async_support(true);
    
    let engine = Engine::new(&config)?;
    let module = Module::from_file(&engine, wasm_path)?;

    // Use 1MB buffer capacity to avoid exhausting memory accidentally.
    let stdout = MemoryOutputPipe::new(1024 * 1024);
    let stderr = MemoryOutputPipe::new(1024 * 1024);
    let stdin = MemoryInputPipe::new(stdin_bytes.to_vec());

    let mut wasi = WasiCtxBuilder::new();
    wasi.stdout(stdout.clone())
        .stderr(stderr.clone())
        .stdin(stdin);
    let ctx = wasi.build_p1();

    let mut store = Store::new(&engine, ctx);
    store.set_fuel(FUEL_LIMIT)?;

    let mut linker = Linker::new(&engine);
    wasmtime_wasi::preview1::add_to_linker_async(&mut linker, |s| s)?;

    let instance = linker.instantiate_async(&mut store, &module).await?;
    let start_fun = instance.get_typed_func::<(), ()>(&mut store, "_start")?;

    let res = start_fun.call_async(&mut store, ()).await;

    let stdout_bytes = stdout.contents();
    let stderr_bytes = stderr.contents();

    let out_str = String::from_utf8_lossy(&stdout_bytes).into_owned();
    let err_str = String::from_utf8_lossy(&stderr_bytes).into_owned();

    match res {
        Ok(_) => Ok((out_str, err_str)),
        Err(e) => {
            if let Some(_trap) = e.downcast_ref::<Trap>() {
                // If get_fuel is nearly zero, it trap exhausted.
                let remaining = store.get_fuel().unwrap_or(FUEL_LIMIT);
                if remaining == 0 {
                    anyhow::bail!("ToolError::ResourceExhausted WASM fuel limit exceeded ({} instructions). stderr: {}", FUEL_LIMIT, err_str);
                }
            }
            anyhow::bail!("wasm exit failed: {}, stderr: {}", e, err_str)
        }
    }
}
