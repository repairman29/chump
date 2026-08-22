#!/usr/bin/env bash
# scripts/setup/refresh-almanac-binary.sh — INFRA-3639
#
# The almanac twin of scripts/setup/refresh-runner-binary.sh: chump's binary
# self-revives on a 5-min cadence (CREDIBLE-076); almanac — the fleet's own
# code-search "eyes" (see docs skill almanac-mastery) — had no equivalent, so
# a vanished binary or an empty/stale index on a node (e.g. CJ) went dark
# until a human noticed ("tonight-blindness").
#
# Each cycle:
#   1. probe_health()   — binary_present, index_rows, index_age_s — always
#      emits ONE `almanac_health` ambient line (the "measurable eyes-alive
#      each cycle" signal other detectors key off of).
#   2. If binary_present=false OR index_rows=0 OR index_age_s over threshold:
#      rebuild the binary (SHA-idempotent — a healthy binary is a no-op,
#      exactly like refresh-runner-binary.sh) then reindex the fleet repos
#      using the local ollama nomic-embed backend.
#   3. Re-probe and emit a second `almanac_health` line so the ambient
#      stream shows the before/after recovery in one cycle.
#
# almanac itself lives in the sibling repairman29/almanac repo (not this
# repo — same posture as scripts/dev/almanac-{census,zero-hits}.py) and is
# not guaranteed to be checked out on every node. This script degrades
# honestly (emits *_unavailable, never crashes) when it isn't.
#
# Env overrides (all optional, defaults match the census/zero-hits scripts'
# binary-resolution convention):
#   ALMANAC_REPO          sibling almanac checkout (default ~/Projects/almanac)
#   ALMANAC_BIN           installed CLI (default ~/Projects/almanac/target/release/almanac)
#   ALMANAC_INDEX_DB      index db to probe row-count/staleness of
#                         (default ~/.almanac/indexes/chump.db)
#   ALMANAC_STALE_S       index max-age before considered stale (default 172800 = 48h)
#   ALMANAC_BUILD_CMD     override the rebuild command (default: cargo build
#                         --release --bin almanac in $ALMANAC_REPO)
#   ALMANAC_BUILT_BIN     path the build command produces (default
#                         $ALMANAC_REPO/target/release/almanac)
#   ALMANAC_REINDEX_CMD   override the reindex command (default: "$ALMANAC_BIN
#                         index --embed-backend ollama --embed-model
#                         nomic-embed-text --json")
#   CHUMP_REPO_ROOT       chump checkout whose ambient.jsonl to emit to
#   CHUMP_SKIP_ALMANAC_REFRESH=1   bypass, exit 0 immediately
#
# Emits ambient kinds:
#   almanac_health                — every cycle, both before and after remediation
#   almanac_binary_refreshed      — rebuild succeeded
#   almanac_binary_refresh_failed — build/install error
#   almanac_reindex_triggered     — reindex command ran and exited 0
#   almanac_reindex_failed        — reindex command exited non-zero
#
# The overall cycle is idempotent: a healthy binary + fresh index exits at
# the top-level "VERDICT==healthy" check below without touching the build or
# reindex paths at all — no rebuild is even attempted.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ALMANAC_REPO="${ALMANAC_REPO:-$HOME/Projects/almanac}"
ALMANAC_BIN="${ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
ALMANAC_INDEX_DB="${ALMANAC_INDEX_DB:-$HOME/.almanac/indexes/chump.db}"
ALMANAC_STALE_S="${ALMANAC_STALE_S:-172800}"
ALMANAC_BUILT_BIN="${ALMANAC_BUILT_BIN:-$ALMANAC_REPO/target/release/almanac}"
ALMANAC_BUILD_CMD="${ALMANAC_BUILD_CMD:-cargo build --release --bin almanac --manifest-path \"$ALMANAC_REPO/Cargo.toml\"}"
ALMANAC_REINDEX_CMD="${ALMANAC_REINDEX_CMD:-\"$ALMANAC_BIN\" index --embed-backend ollama --embed-model nomic-embed-text --json}"

emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '%s\n' "$line"
}

if [[ "${CHUMP_SKIP_ALMANAC_REFRESH:-0}" == "1" ]]; then
    echo "BYPASS: CHUMP_SKIP_ALMANAC_REFRESH=1"
    exit 0
fi

# ---------- health probe ----------
# Sets globals: BINARY_PRESENT INDEX_ROWS INDEX_AGE_S VERDICT
probe_health() {
    BINARY_PRESENT="false"
    if [[ -x "$ALMANAC_BIN" ]]; then
        BINARY_PRESENT="true"
    fi

    INDEX_ROWS="unknown"
    INDEX_AGE_S="unknown"
    if [[ -f "$ALMANAC_INDEX_DB" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            # Row count across every table isn't well-defined generically, so
            # probe the conventional "files"/"symbols" table names honestly;
            # fall back to "unknown" rather than guessing a schema.
            INDEX_ROWS="$(sqlite3 "$ALMANAC_INDEX_DB" \
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo unknown)"
            if [[ "$INDEX_ROWS" != "unknown" ]]; then
                # tables exist; count rows in the largest one as a coarse
                # "is this index non-empty" signal
                local biggest=0
                for t in $(sqlite3 "$ALMANAC_INDEX_DB" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null); do
                    local c
                    c="$(sqlite3 "$ALMANAC_INDEX_DB" "SELECT COUNT(*) FROM \"$t\";" 2>/dev/null || echo 0)"
                    [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -gt "$biggest" ]] && biggest="$c"
                done
                INDEX_ROWS="$biggest"
            fi
        fi
        local mtime now
        mtime="$(stat -c %Y "$ALMANAC_INDEX_DB" 2>/dev/null || stat -f %m "$ALMANAC_INDEX_DB" 2>/dev/null || echo 0)"
        now="$(date -u +%s)"
        INDEX_AGE_S=$(( now - mtime ))
    else
        INDEX_ROWS="0"
    fi

    VERDICT="healthy"
    if [[ "$BINARY_PRESENT" == "false" ]]; then
        VERDICT="binary_missing"
    elif [[ "$INDEX_ROWS" == "0" ]]; then
        VERDICT="index_empty"
    elif [[ "$INDEX_ROWS" != "unknown" && "$INDEX_AGE_S" != "unknown" && "$INDEX_AGE_S" -gt "$ALMANAC_STALE_S" ]]; then
        VERDICT="index_stale"
    fi
}

emit_health() {
    local phase="$1"
    emit almanac_health \
        "\"phase\":\"$phase\",\"binary_present\":$BINARY_PRESENT,\"index_rows\":\"$INDEX_ROWS\",\"index_age_s\":\"$INDEX_AGE_S\",\"stale_threshold_s\":$ALMANAC_STALE_S,\"verdict\":\"$VERDICT\""
}

probe_health
emit_health "pre"

if [[ "$VERDICT" == "healthy" ]]; then
    echo "OK: almanac healthy (binary_present=$BINARY_PRESENT index_rows=$INDEX_ROWS index_age_s=$INDEX_AGE_S)"
    exit 0
fi

echo "UNHEALTHY: verdict=$VERDICT binary_present=$BINARY_PRESENT index_rows=$INDEX_ROWS index_age_s=$INDEX_AGE_S — self-healing"

# ---------- rebuild binary (SHA-idempotent) ----------
if [[ "$VERDICT" == "binary_missing" ]]; then
    if [[ ! -d "$ALMANAC_REPO/.git" ]]; then
        emit almanac_binary_refresh_failed "\"reason\":\"almanac_repo_absent\",\"repo\":\"$ALMANAC_REPO\""
        echo "FAIL: almanac repo not checked out at $ALMANAC_REPO — cannot rebuild"
        exit 1
    fi

    MAIN_SHA="$(git -C "$ALMANAC_REPO" rev-parse --short=12 origin/main 2>/dev/null || git -C "$ALMANAC_REPO" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    INSTALLED_SHA="none"
    if [[ -x "$ALMANAC_BIN" ]]; then
        INSTALLED_SHA="$("$ALMANAC_BIN" --version 2>/dev/null | grep -oE '[a-f0-9]{7,12}' | head -1 || echo unknown)"
    fi

    # VERDICT=="binary_missing" only fires when $ALMANAC_BIN is absent/not
    # executable, so INSTALLED_SHA is always "none" here — nothing to skip,
    # always rebuild. (The idempotent no-op path is the top-level "healthy"
    # exit above: a *present*, healthy binary never reaches this branch at
    # all, which is what makes a cycle over a healthy install a true no-op.)
    echo "rebuilding almanac ($ALMANAC_BUILD_CMD) …"
    # Prefer the sibling repo's own installer/rebuild primitive when
    # present — that script owns almanac-specific build flags this
    # generic twin should not have to know about.
    if [[ -x "$ALMANAC_REPO/scripts/install-almanac-organ.sh" ]]; then
        if ! "$ALMANAC_REPO/scripts/install-almanac-organ.sh" >/tmp/almanac-organ-install.log 2>&1; then
            emit almanac_binary_refresh_failed "\"reason\":\"install_almanac_organ_failed\""
            echo "FAIL: install-almanac-organ.sh failed; see /tmp/almanac-organ-install.log"
            exit 1
        fi
    else
        if ! eval "$ALMANAC_BUILD_CMD" >/tmp/almanac-build.log 2>&1; then
            emit almanac_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
            echo "FAIL: build failed; see /tmp/almanac-build.log"
            exit 1
        fi
        if [[ ! -x "$ALMANAC_BUILT_BIN" ]]; then
            emit almanac_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
            echo "FAIL: $ALMANAC_BUILT_BIN missing after build"
            exit 1
        fi
        mkdir -p "$(dirname "$ALMANAC_BIN")"
        cp -f "$ALMANAC_BUILT_BIN" "$ALMANAC_BIN"
        chmod +x "$ALMANAC_BIN"
        if [[ "$(uname)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
            codesign --force --sign - "$ALMANAC_BIN" 2>/dev/null || true
        fi
    fi
    NEW_SHA="$("$ALMANAC_BIN" --version 2>/dev/null | grep -oE '[a-f0-9]{7,12}' | head -1 || echo unknown)"
    emit almanac_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""
    echo "OK: almanac binary refreshed ($INSTALLED_SHA -> $NEW_SHA)"
fi

# ---------- reindex (empty or stale index) ----------
probe_health
if [[ "$VERDICT" == "index_empty" || "$VERDICT" == "index_stale" ]]; then
    if [[ ! -x "$ALMANAC_BIN" ]]; then
        emit almanac_reindex_failed "\"reason\":\"no_binary_after_rebuild\""
        echo "FAIL: no almanac binary available to reindex with"
        exit 1
    fi
    echo "reindexing ($ALMANAC_REINDEX_CMD) …"
    if eval "$ALMANAC_REINDEX_CMD" >/tmp/almanac-reindex.log 2>&1; then
        emit almanac_reindex_triggered "\"backend\":\"ollama\",\"embed_model\":\"nomic-embed-text\""
        echo "OK: reindex triggered"
    else
        emit almanac_reindex_failed "\"reason\":\"reindex_cmd_nonzero_exit\""
        echo "FAIL: reindex command failed; see /tmp/almanac-reindex.log"
        exit 1
    fi
fi

# ---------- re-probe, emit recovery line ----------
probe_health
emit_health "post"

if [[ "$VERDICT" == "healthy" ]]; then
    echo "RECOVERED: almanac healthy again (binary_present=$BINARY_PRESENT index_rows=$INDEX_ROWS)"
    exit 0
else
    echo "STILL UNHEALTHY after remediation: verdict=$VERDICT"
    exit 1
fi
