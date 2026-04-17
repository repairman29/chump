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

/// Read the WASM fuel budget from `CHUMP_WASM_FUEL_BUDGET` env var (u64 instructions).
/// Default is 100M instructions (~100ms on modern hardware). Can be disabled entirely
/// by setting `CHUMP_WASM_FUEL_ENABLED=0`. See Sprint A2 (Defense Trinity, wasmtime
/// fuel metering, adopted from Capsule) in docs/NEXT_GEN_COMPETITIVE_INTEL.md.
fn wasm_fuel_budget() -> u64 {
    std::env::var("CHUMP_WASM_FUEL_BUDGET")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(100_000_000)
}

fn wasm_fuel_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_WASM_FUEL_ENABLED").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

pub async fn run_wasm_wasi(wasm_path: &Path, stdin_bytes: &[u8]) -> Result<(String, String)> {
    use wasmtime::*;
    use wasmtime_wasi::pipe::{MemoryInputPipe, MemoryOutputPipe};
    use wasmtime_wasi::WasiCtxBuilder;

    let fuel_enabled = wasm_fuel_enabled();
    let fuel_budget = wasm_fuel_budget();

    let mut config = Config::new();
    if fuel_enabled {
        config.consume_fuel(true);
    }
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
    if fuel_enabled {
        store.set_fuel(fuel_budget)?;
    }

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
            if fuel_enabled {
                if let Some(_trap) = e.downcast_ref::<Trap>() {
                    let remaining = store.get_fuel().unwrap_or(fuel_budget);
                    if remaining == 0 {
                        anyhow::bail!(
                            "WASM execution exceeded fuel budget ({} instructions). Set CHUMP_WASM_FUEL_BUDGET to raise. stderr: {}",
                            fuel_budget,
                            err_str
                        );
                    }
                }
            }
            anyhow::bail!("wasm exit failed: {}, stderr: {}", e, err_str)
        }
    }
}

#[cfg(test)]
mod fuel_tests {
    use super::*;

    #[test]
    fn fuel_budget_reads_env() {
        std::env::set_var("CHUMP_WASM_FUEL_BUDGET", "500000000");
        assert_eq!(wasm_fuel_budget(), 500_000_000);
        std::env::remove_var("CHUMP_WASM_FUEL_BUDGET");
    }

    #[test]
    fn fuel_budget_default() {
        std::env::remove_var("CHUMP_WASM_FUEL_BUDGET");
        assert_eq!(wasm_fuel_budget(), 100_000_000);
    }

    #[test]
    fn fuel_budget_invalid_falls_back_to_default() {
        std::env::set_var("CHUMP_WASM_FUEL_BUDGET", "not_a_number");
        assert_eq!(wasm_fuel_budget(), 100_000_000);
        std::env::remove_var("CHUMP_WASM_FUEL_BUDGET");
    }

    #[test]
    fn fuel_enabled_default_on() {
        std::env::remove_var("CHUMP_WASM_FUEL_ENABLED");
        assert!(wasm_fuel_enabled());
    }

    #[test]
    fn fuel_enabled_off_via_env() {
        std::env::set_var("CHUMP_WASM_FUEL_ENABLED", "0");
        assert!(!wasm_fuel_enabled());
        std::env::set_var("CHUMP_WASM_FUEL_ENABLED", "false");
        assert!(!wasm_fuel_enabled());
        std::env::set_var("CHUMP_WASM_FUEL_ENABLED", "off");
        assert!(!wasm_fuel_enabled());
        std::env::remove_var("CHUMP_WASM_FUEL_ENABLED");
    }
}
