# Chump: Smart Memory (semantic + keyword)

## Implemented (all local)

- **Proactive recall**: Before each Discord turn we call `recall_for_context(&user_message, 10)` and inject "Relevant context from memory" above the user message.
- **Storage**: Prefers **SQLite** (`sessions/chump_memory.db`) with **FTS5** for keyword search; migrates from `sessions/chump_memory.json` on first use. Falls back to JSON when the DB path is not available.
- **Keyword recall**: When using SQLite, recall uses FTS5; when using JSON, recall matches by word overlap. Used whenever the embed server is not used or unavailable.
- **Semantic recall (local)**: When the **local embed server** is running, Chump uses it to:
  - **Embed** each new stored memory and append the vector to `sessions/chump_memory_embeddings.json`.
  - **Recall** by embedding similarity: the user message is embedded, then we return the top-k memories by cosine similarity. So "I gave you some upgrades" can pull "User set up 30B model on port 8000" even without shared words.
- **Hybrid recall (RRF)**: When **both** SQLite and the embed server are available, we merge keyword (FTS5) and semantic (cosine) results using **reciprocal rank fusion (RRF)** so that matches that appear in both lists rank higher.
- **Backfill**: If the embeddings file has fewer vectors than memory entries (e.g. after first enabling the server), we backfill missing embeddings on the next recall.
- **No API keys**: The embed server uses [sentence-transformers](https://www.sbert.net/) (e.g. `all-MiniLM-L6-v2`) and runs entirely on your machine.

## Running the embed server

1. **Install Python deps** (one-time):

   ```bash
   pip install -r scripts/requirements-embed.txt
   ```

   First run will download the model (~80MB for all-MiniLM-L6-v2).

2. **Start the server** (in a separate terminal or under launchd):

   ```bash
   ./scripts/start-embed-server.sh
   ```

   Default: `http://127.0.0.1:18765`. Override with `CHUMP_EMBED_PORT` or `CHUMP_EMBED_URL` (full base URL) in the **agent** process (e.g. `export CHUMP_EMBED_URL=http://127.0.0.1:18765`). The server itself uses `CHUMP_EMBED_PORT` and optional `CHUMP_EMBED_MODEL`.

3. **Optional**: Run the embed server at login (e.g. add to your Chump launchd or a second LaunchAgent so it starts before or with the bot).

If the embed server is not running (and in-process embedding is not used), Chump falls back to keyword-only recall; no errors, just less semantic matching.

**Optional: in-process embeddings.** Build with `cargo build --features inprocess-embed` to embed locally (fastembed, all-MiniLM-L6-v2). When `CHUMP_EMBED_URL` is unset, the agent uses in-process embedding and does not require the Python server. Env: `CHUMP_EMBED_INPROCESS=1` to prefer in-process even when URL is set; `CHUMP_EMBED_CACHE_DIR` to override model cache directory. See [SPECULATIVE_AND_EMBEDDINGS.md](SPECULATIVE_AND_EMBEDDINGS.md).

## Storage

| File                                    | Purpose                                                                                                                                        |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `sessions/chump_memory.db`              | Preferred: SQLite DB with `chump_memory` table and FTS5 virtual table for keyword search. Created on first use; migrates from JSON if present. |
| `sessions/chump_memory.json`            | Fallback when DB is not used. Memory entries (content, ts, source).                                                                            |
| `sessions/chump_memory_embeddings.json` | One vector per entry, same order as memory (array of arrays). Used for semantic recall and RRF.                                                |

## Optional: RAG over repo/docs (not implemented)

For "Chump knows the codebase," a future step is to embed doc chunks or file summaries and inject "Relevant from repo: …" when the question is about the project. Lower priority than semantic user memory.
