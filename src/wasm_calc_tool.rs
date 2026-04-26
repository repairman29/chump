//! WASM-based calculator tool: runs a WASI module (wasm/calculator.wasm) with wasmtime CLI.
//! No host filesystem or network; input is passed on stdin, result on stdout.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::wasm_runner;

/// Returns true if the WASM calculator is available (wasmtime on PATH and calculator.wasm exists).
pub fn wasm_calc_available() -> bool {
    std::process::Command::new("wasmtime")
        .arg("--version")
        .output()
        .is_ok()
        && wasm_runner::wasm_artifact_path("calculator.wasm").exists()
}

pub struct WasmCalcTool;

#[async_trait]
impl Tool for WasmCalcTool {
    fn name(&self) -> String {
        "wasm_calc".to_string()
    }

    fn description(&self) -> String {
        "Safe calculator running in WebAssembly (WASI). Use when you need arithmetic without host access. \
         Params: expression (string), e.g. '2 + 3' or '10 * 0.5'. Only + - * / and numbers.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "expression": { "type": "string", "description": "Arithmetic expression, e.g. '2 + 3' or '10 / 2'" }
            },
            "required": ["expression"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let expr = input
            .get("expression")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        if expr.is_empty() {
            return Ok("Error: empty expression".to_string());
        }

        let path = wasm_runner::wasm_artifact_path("calculator.wasm");
        if !path.exists() {
            return Ok("Error: calculator.wasm not found. Build it from wasm/calc-wasm (see docs/architecture/WASM_TOOLS.md).".to_string());
        }

        let stdin = format!("{}\n", expr);
        let (stdout, stderr) = wasm_runner::run_wasm_wasi(&path, stdin.as_bytes()).await?;
        let out = stdout.trim();
        if out.is_empty() && !stderr.is_empty() {
            Ok(format!("stderr: {}", stderr.trim()))
        } else {
            Ok(out.to_string())
        }
    }
}
