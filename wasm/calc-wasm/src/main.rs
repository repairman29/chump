//! WASI calculator: read one line from stdin (e.g. "3 + 4" or "10 / 2"), print result to stdout.

use std::io::{self, BufRead, Write};

fn main() {
    let stdin = io::stdin();
    let mut line = String::new();
    if stdin.lock().read_line(&mut line).is_err() {
        println!("error: read");
        return;
    }
    let result = eval_line(line.trim());
    println!("{}", result);
}

fn eval_line(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() {
        return "error: empty".to_string();
    }
    let mut a = 0.0f64;
    let mut op = None;
    let mut b = 0.0f64;
    let mut cur = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() || c == '.' || (c == '-' && cur.is_empty()) {
            cur.push(c);
        } else if c == '+' || c == '-' || c == '*' || c == '/' {
            if op.is_some() {
                return "error: multiple ops".to_string();
            }
            a = cur.parse().unwrap_or(0.0);
            cur.clear();
            op = Some(c);
        } else if !c.is_whitespace() {
            return format!("error: bad char {:?}", c);
        }
    }
    if op.is_none() {
        return "error: no operator".to_string();
    }
    b = cur.parse().unwrap_or(0.0);
    let out = match op {
        Some('+') => a + b,
        Some('-') => a - b,
        Some('*') => a * b,
        Some('/') => {
            if b == 0.0 {
                return "error: division by zero".to_string();
            }
            a / b
        }
        _ => return "error: unknown op".to_string(),
    };
    out.to_string()
}
