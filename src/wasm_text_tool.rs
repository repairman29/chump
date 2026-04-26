//! WASM text transform: `wasm/text_transform.wasm` — reverse / uppercase / lowercase with no host access.
//! See `docs/architecture/WASM_TOOLS.md`.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::wasm_runner;

/// wasmtime on PATH and `wasm/text_transform.wasm` present.
pub fn wasm_text_available() -> bool {
    std::process::Command::new("wasmtime")
        .arg("--version")
        .output()
        .is_ok()
        && wasm_runner::wasm_artifact_path("text_transform.wasm").exists()
}

pub struct WasmTextTool;

#[async_trait]
impl Tool for WasmTextTool {
    fn name(&self) -> String {
        "wasm_text".to_string()
    }

    fn description(&self) -> String {
        "Sandboxed UTF-8 text transform in WebAssembly (no host FS/network). \
         Params: operation (reverse | upper | lower), text (string)."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "operation": {
                    "type": "string",
                    "enum": ["reverse", "upper", "lower"],
                    "description": "reverse = reverse graphemes; upper/lower = Unicode case mapping"
                },
                "text": { "type": "string", "description": "Input text (truncated at 8192 UTF-8 bytes)" }
            },
            "required": ["operation", "text"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let op = input
            .get("operation")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_lowercase();
        let text = input.get("text").and_then(|v| v.as_str()).unwrap_or("");
        let text = wasm_runner::clamp_wasm_text_input(text);

        if !matches!(op.as_str(), "reverse" | "upper" | "lower") {
            return Ok("Error: operation must be reverse, upper, or lower".to_string());
        }

        let path = wasm_runner::wasm_artifact_path("text_transform.wasm");
        if !path.exists() {
            return Ok(
                "Error: text_transform.wasm not found. Build from wasm/text-wasm (see docs/architecture/WASM_TOOLS.md)."
                    .to_string(),
            );
        }

        let stdin = format!("{}\n{}\n", op, text);
        let (stdout, stderr) = wasm_runner::run_wasm_wasi(&path, stdin.as_bytes()).await?;
        let out = stdout.trim();
        if out.is_empty() && !stderr.is_empty() {
            Ok(format!("stderr: {}", stderr.trim()))
        } else {
            Ok(out.to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn wasm_text_roundtrip_upper() {
        if !wasm_text_available() {
            return;
        }
        let t = WasmTextTool;
        let out = t
            .execute(json!({ "operation": "upper", "text": "ab" }))
            .await
            .unwrap();
        assert_eq!(out, "AB");
    }
}
