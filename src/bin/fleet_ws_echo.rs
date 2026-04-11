//! Outbound WebSocket line client for fleet lab spikes (WP-5.1). Connects to a
//! `websocat … mirror:` or compatible echo server; sends each stdin line as a text frame.
//!
//! Usage: `cargo run --bin fleet-ws-echo --release -- ws://127.0.0.1:18766`

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};

#[tokio::main]
async fn main() -> Result<()> {
    let url = std::env::args()
        .nth(1)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "ws://127.0.0.1:18766".to_string());

    let (ws_stream, _) = connect_async(url.as_str())
        .await
        .with_context(|| format!("connect {}", url))?;
    let (mut write, mut read) = ws_stream.split();

    println!("Connected to {} — type lines (Ctrl-D to exit)", url);

    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break;
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            continue;
        }
        write
            .send(Message::Text(trimmed.into()))
            .await
            .context("send")?;
        match read.next().await {
            Some(Ok(Message::Text(t))) => println!("{}", t),
            Some(Ok(Message::Binary(b))) => println!("<binary {} bytes>", b.len()),
            Some(Ok(Message::Close(_))) => {
                println!("<closed>");
                break;
            }
            Some(Err(e)) => {
                eprintln!("read error: {}", e);
                break;
            }
            None => break,
            _ => {}
        }
    }
    Ok(())
}
