#!/usr/bin/env bash
# scripts/coord/lib/peer-memory.sh — RESILIENT-1497 / META-900 / META-901
#
# Persistent memory for the free Opus peer: a running context that survives
# across judgment ticks and Discord commands, so the peer isn't re-deriving
# fleet state from scratch every cadence. Writes to the SAME chump_memory.db
# schema the chump-mcp-memory crate already defines
# (crates/mcp-servers/chump-mcp-memory/src/main.rs) at
# <repo>/sessions/chump_memory.db, so episodes written here are readable via
# the memory_search / episode_search MCP tools without a second store.
#
# shellcheck shell=bash

peer_memory_db_path() {
    if [[ -n "${CHUMP_MEMORY_DB:-}" ]]; then
        printf '%s\n' "$CHUMP_MEMORY_DB"
        return
    fi
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)"
    printf '%s\n' "$repo_root/sessions/chump_memory.db"
}

# peer_memory_init — idempotent; mirrors the Rust open_db() schema exactly
# so either side can read what the other wrote.
peer_memory_init() {
    local db; db="$(peer_memory_db_path)"
    mkdir -p "$(dirname "$db")" 2>/dev/null || true
    command -v sqlite3 >/dev/null 2>&1 || return 1
    sqlite3 "$db" "
        CREATE TABLE IF NOT EXISTS chump_memory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            ts TEXT NOT NULL DEFAULT (datetime('now')),
            source TEXT NOT NULL DEFAULT 'mcp',
            confidence REAL DEFAULT 1.0,
            verified INTEGER DEFAULT 0,
            sensitivity TEXT DEFAULT 'internal',
            expires_at TEXT,
            memory_type TEXT DEFAULT 'semantic_fact'
        );
        CREATE TABLE IF NOT EXISTS chump_episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            happened_at TEXT NOT NULL DEFAULT (datetime('now')),
            summary TEXT NOT NULL,
            detail TEXT,
            tags TEXT,
            repo TEXT,
            sentiment TEXT CHECK(sentiment IN ('win','loss','neutral','frustrating','uncertain')),
            pr_number INTEGER,
            issue_number INTEGER
        );
    " 2>/dev/null
}

# peer_memory_save_episode <summary> <detail> <tags> [sentiment]
peer_memory_save_episode() {
    local summary="${1:?summary required}" detail="${2:-}" tags="${3:-peer}" sentiment="${4:-neutral}"
    peer_memory_init || return 1
    local db; db="$(peer_memory_db_path)"
    sqlite3 "$db" \
        "INSERT INTO chump_episodes (summary, detail, tags, repo, sentiment) VALUES ($(printf '%s' "$summary" | _peer_sql_quote), $(printf '%s' "$detail" | _peer_sql_quote), $(printf '%s' "$tags" | _peer_sql_quote), 'chump', $(printf '%s' "$sentiment" | _peer_sql_quote));" \
        2>/dev/null
}

# peer_memory_recent_episodes [n] — tab-free one-line-per-episode summaries,
# newest first; feeds the "running context" into the next judgment prompt.
peer_memory_recent_episodes() {
    local n="${1:-10}"
    peer_memory_init || return 1
    local db; db="$(peer_memory_db_path)"
    sqlite3 -separator ' | ' "$db" \
        "SELECT happened_at, summary FROM chump_episodes ORDER BY id DESC LIMIT ${n};" 2>/dev/null
}

_peer_sql_quote() {
    local s; s="$(cat)"
    s="${s//\'/\'\'}"
    printf "'%s'" "$s"
}
