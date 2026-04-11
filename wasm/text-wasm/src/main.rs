//! WASI text transform: first stdin line = operation (reverse, upper, lower), second line = text.

use std::io::{self, BufRead};

fn main() {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();
    let op = match lines.next() {
        Some(Ok(l)) => l.trim().to_lowercase(),
        _ => {
            println!("error: missing operation line");
            return;
        }
    };
    let text = match lines.next() {
        Some(Ok(l)) => l,
        _ => {
            println!("error: missing text line");
            return;
        }
    };
    let out = match op.as_str() {
        "reverse" => text.chars().rev().collect::<String>(),
        "upper" | "uppercase" => text.to_uppercase(),
        "lower" | "lowercase" => text.to_lowercase(),
        _ => {
            println!("error: unknown op (use reverse, upper, lower)");
            return;
        }
    };
    println!("{}", out);
}
