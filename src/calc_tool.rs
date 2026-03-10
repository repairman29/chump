//! Calculator tool that accepts string or number params (LLMs often send strings).
//! Replaces axonerai's Calculator for Chump to avoid "invalid type: string, expected f64".

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

fn param_to_f64(v: &Value) -> Result<f64> {
    match v {
        Value::Number(n) => n.as_f64().ok_or_else(|| anyhow!("number not f64")),
        Value::String(s) => s.trim().parse::<f64>().map_err(|e| anyhow!("parse {:?}: {}", s, e)),
        _ => Err(anyhow!("expected number or string, got {:?}", v)),
    }
}

pub struct ChumpCalculator;

#[async_trait]
impl Tool for ChumpCalculator {
    fn name(&self) -> String {
        "calculator".to_string()
    }

    fn description(&self) -> String {
        "Perform arithmetic: add, subtract, multiply, divide. Params: operation (string), a and b (numbers or numeric strings).".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "operation": { "type": "string", "description": "add, subtract, multiply, or divide" },
                "a": { "description": "first number" },
                "b": { "description": "second number" }
            },
            "required": ["operation", "a", "b"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let op = input
            .get("operation")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing operation"))?
            .trim()
            .to_lowercase();
        let a = param_to_f64(input.get("a").ok_or_else(|| anyhow!("missing a"))?)?;
        let b = param_to_f64(input.get("b").ok_or_else(|| anyhow!("missing b"))?)?;
        let result = match op.as_str() {
            "add" | "addition" => a + b,
            "subtract" | "subtraction" => a - b,
            "multiply" | "multiplication" => a * b,
            "divide" | "division" => {
                if b == 0.0 {
                    return Err(anyhow!("division by zero"));
                }
                a / b
            }
            _ => return Err(anyhow!("unknown operation: {}", op)),
        };
        Ok(result.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn add_works() {
        let calc = ChumpCalculator;
        let out = calc
            .execute(json!({ "operation": "add", "a": 2, "b": 3 }))
            .await
            .unwrap();
        assert_eq!(out, "5");
    }

    #[tokio::test]
    async fn divide_by_zero_errors() {
        let calc = ChumpCalculator;
        let err = calc
            .execute(json!({ "operation": "divide", "a": 1, "b": 0 }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("division by zero"));
    }

    #[tokio::test]
    async fn unknown_operation_errors() {
        let calc = ChumpCalculator;
        let err = calc
            .execute(json!({ "operation": "sqrt", "a": 4, "b": 0 }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("unknown operation"));
    }
}
