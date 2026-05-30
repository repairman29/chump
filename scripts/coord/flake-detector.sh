#!/usr/bin/env bash
# flake-detector.sh — META-141 (META-131 slice e)
#
# Daemon that scans recent CI results across all open PRs, computes
# per-test error fingerprints, and quarantines tests that fail with the
# same fingerprint 3 or more times within a 24-hour window across at
# least 3 distinct PRs.
#
# Design spec: docs/design/FLAKE_QUARANTINE.md
#
# Usage:
#   scripts/coord/flake-detector.sh               # live scan
#   scripts/coord/flake-detector.sh --dry-run      # report without writing state
#
# Environment:
#   CHUMP_FLAKE_DETECTOR=0          bypass entirely (exit 0)
#   CHUMP_FLAKE_WINDOW_SECS         lookback window in seconds (default: 86400 = 24h)
#   CHUMP_FLAKE_THRESHOLD           min distinct PRs with same fingerprint to quarantine (default: 3)
#   CHUMP_FLAKE_MAX_SCANS           max recent CI runs to scan (default: 50)
#   CHUMP_FLAKE_DB                  override path to flake_tracker.db
#   CHUMP_FLAKE_QUARANTINE_FILE     override path to quarantined-flakes.json
#   CHUMP_AMBIENT_LOG               override ambient.jsonl path
#
# Wired into launchd via .chump/launchd/com.chump.flake-detector.plist
# (every 30 min).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── bypass ───────────────────────────────────────────────────────────────────
if [[ "${CHUMP_FLAKE_DETECTOR:-1}" == "0" ]]; then
    echo "[flake-detector] CHUMP_FLAKE_DETECTOR=0 — bypass"
    exit 0
fi

# ── config ───────────────────────────────────────────────────────────────────
WINDOW_SECS="${CHUMP_FLAKE_WINDOW_SECS:-86400}"          # 24 h
THRESHOLD="${CHUMP_FLAKE_THRESHOLD:-3}"                  # 3 distinct PRs
MAX_SCANS="${CHUMP_FLAKE_MAX_SCANS:-50}"
FLAKE_DB="${CHUMP_FLAKE_DB:-$REPO_ROOT/.chump/flake_tracker.db}"
QUARANTINE_FILE="${CHUMP_FLAKE_QUARANTINE_FILE:-$REPO_ROOT/.chump-locks/quarantined-flakes.json}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ── helpers ──────────────────────────────────────────────────────────────────

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Emit to ambient.jsonl — scanner-anchor: "kind":"flake_detected"
_emit_ambient() {
    local json_line="$1"
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 200; printf '%s\n' "$json_line" >> "$AMBIENT_LOG" ) \
            200>"${AMBIENT_LOG}.lock" 2>&1 \
            || printf '[WARN] %s flake-detector ambient write failed\n' "$(ts_now)" >&2
    else
        printf '%s\n' "$json_line" >> "$AMBIENT_LOG" \
            || printf '[WARN] %s flake-detector ambient write failed\n' "$(ts_now)" >&2
    fi
}

# Compute error fingerprint: sha256 of first 200 chars of error text,
# truncated to 16 hex chars. Matches design spec §Detection algorithm.
compute_fingerprint() {
    local error_text="$1"
    local truncated="${error_text:0:200}"
    printf '%s' "$truncated" | sha256sum | cut -c1-16
}

# SQLite helper — runs a query against FLAKE_DB, creates schema on first use.
_db() {
    sqlite3 "$FLAKE_DB" "$@"
}

# Ensure schema exists
init_db() {
    mkdir -p "$(dirname "$FLAKE_DB")"
    _db <<'SQL'
CREATE TABLE IF NOT EXISTS flake_run (
  test_path         TEXT NOT NULL,
  run_id            TEXT NOT NULL,
  pr_num            INTEGER,
  conclusion        TEXT NOT NULL,
  error_fingerprint TEXT,
  ts                TEXT NOT NULL,
  PRIMARY KEY (test_path, run_id)
);
CREATE INDEX IF NOT EXISTS idx_flake_run_path_ts ON flake_run(test_path, ts DESC);

CREATE TABLE IF NOT EXISTS flake_quarantine (
  test_path         TEXT PRIMARY KEY,
  quarantined_at    TEXT NOT NULL,
  fingerprint       TEXT NOT NULL,
  follow_up_gap     TEXT NOT NULL DEFAULT '',
  expires_at        TEXT NOT NULL,
  consecutive_passes INTEGER NOT NULL DEFAULT 0
);
SQL
}

# ── main logic ────────────────────────────────────────────────────────────────

main() {
    echo "[flake-detector] start ts=$(ts_now) dry_run=$DRY_RUN window=${WINDOW_SECS}s threshold=$THRESHOLD max_scans=$MAX_SCANS"

    init_db

    # Derive cutoff timestamp for the window
    if date --version >/dev/null 2>&1; then
        # GNU date
        CUTOFF_TS="$(date -u -d "@$(($(date +%s) - WINDOW_SECS))" +%Y-%m-%dT%H:%M:%SZ)"
    else
        # BSD date (macOS)
        CUTOFF_TS="$(date -u -v-${WINDOW_SECS}S +%Y-%m-%dT%H:%M:%SZ)"
    fi
    echo "[flake-detector] window cutoff=$CUTOFF_TS"

    # Query: per test_path+fingerprint, count distinct PRs with failures in window
    # If a test has >= THRESHOLD distinct PRs with same fingerprint → quarantine
    local query
    query="
SELECT
    test_path,
    error_fingerprint,
    COUNT(DISTINCT pr_num) AS affected_pr_count,
    MIN(ts) AS first_seen,
    MAX(ts) AS last_seen,
    COUNT(*) AS occurrence_count
FROM flake_run
WHERE conclusion = 'fail'
  AND error_fingerprint IS NOT NULL
  AND ts >= '$CUTOFF_TS'
  AND pr_num IS NOT NULL
GROUP BY test_path, error_fingerprint
HAVING affected_pr_count >= $THRESHOLD
ORDER BY affected_pr_count DESC, last_seen DESC;
"

    local hits
    hits="$(_db "$query" 2>/dev/null || true)"

    if [[ -z "$hits" ]]; then
        echo "[flake-detector] no flake candidates in window"
    else
        echo "[flake-detector] candidates:"
        printf '%s\n' "$hits"
    fi

    # Process each candidate
    local new_quarantines=0
    while IFS='|' read -r test_path fingerprint affected_pr_count first_seen last_seen occurrence_count; do
        [[ -z "$test_path" ]] && continue
        echo "[flake-detector] candidate: test='$test_path' fingerprint='$fingerprint' prs=$affected_pr_count occurrences=$occurrence_count"

        # Already quarantined?
        local already
        already="$(_db "SELECT COUNT(*) FROM flake_quarantine WHERE test_path='$(printf '%s' "$test_path" | sed "s/'/''/g")';" 2>/dev/null || echo 0)"
        if [[ "$already" -gt 0 ]]; then
            echo "[flake-detector] $test_path already quarantined — skipping"
            continue
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[flake-detector] DRY-RUN: would quarantine '$test_path' (prs=$affected_pr_count fingerprint=$fingerprint)"
            continue
        fi

        # Compute expiry (14 days)
        local expires_at
        if date --version >/dev/null 2>&1; then
            expires_at="$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ)"
        else
            expires_at="$(date -u -v+14d +%Y-%m-%dT%H:%M:%SZ)"
        fi

        local quarantined_at
        quarantined_at="$(ts_now)"

        # Write to SQLite
        _db "INSERT OR IGNORE INTO flake_quarantine
             (test_path, quarantined_at, fingerprint, follow_up_gap, expires_at, consecutive_passes)
             VALUES ('$(printf '%s' "$test_path" | sed "s/'/''/g")', '$quarantined_at', '$fingerprint', '', '$expires_at', 0);" \
             2>/dev/null || true

        # Update quarantined-flakes.json — append/merge entry
        _write_quarantine_json "$test_path" "$fingerprint" "$affected_pr_count" \
                               "$first_seen" "$last_seen" "$occurrence_count" \
                               "$quarantined_at" "$expires_at"

        # Emit ambient event — scanner-anchor: "kind":"flake_detected"
        local event
        event="$(printf '{"ts":"%s","kind":"flake_detected","test_path":"%s","fingerprint":"%s","occurrence_count":%s,"affected_pr_count":%s,"first_seen":"%s","last_seen":"%s","expires_at":"%s"}' \
            "$quarantined_at" "$test_path" "$fingerprint" "$occurrence_count" \
            "$affected_pr_count" "$first_seen" "$last_seen" "$expires_at")"
        _emit_ambient "$event"

        echo "[flake-detector] quarantined: $test_path (fingerprint=$fingerprint prs=$affected_pr_count)"
        new_quarantines=$((new_quarantines + 1))
    done <<< "$hits"

    echo "[flake-detector] done new_quarantines=$new_quarantines"
}

# Write or update an entry in quarantined-flakes.json.
# File format: array of JSON objects, one per quarantined test.
_write_quarantine_json() {
    local test_path="$1"
    local fingerprint="$2"
    local affected_pr_count="$3"
    local first_seen="$4"
    local last_seen="$5"
    local occurrence_count="$6"
    local quarantined_at="$7"
    local expires_at="$8"

    mkdir -p "$(dirname "$QUARANTINE_FILE")"

    # Build the new entry
    local entry
    entry="$(printf '{"test_path":"%s","fingerprint":"%s","quarantined_at":"%s","expires_at":"%s","occurrence_count":%s,"affected_pr_count":%s,"first_seen":"%s","last_seen":"%s","follow_up_gap":""}' \
        "$test_path" "$fingerprint" "$quarantined_at" "$expires_at" \
        "$occurrence_count" "$affected_pr_count" "$first_seen" "$last_seen")"

    if [[ ! -f "$QUARANTINE_FILE" ]]; then
        printf '[%s]\n' "$entry" > "$QUARANTINE_FILE"
        return
    fi

    # Read existing, filter out any matching test_path, append new entry
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$QUARANTINE_FILE" "$test_path" "$entry" <<'PYEOF'
import json, sys
path, test_path, entry_json = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
# remove old entry for this test if present
data = [e for e in data if e.get("test_path") != test_path]
data.append(json.loads(entry_json))
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    else
        # Fallback: append without dedup (best effort on systems without python3)
        local existing
        existing="$(cat "$QUARANTINE_FILE")"
        # Strip trailing ] and append
        printf '%s,\n%s\n]\n' "${existing%]}" "$entry" > "$QUARANTINE_FILE"
    fi
}

main "$@"
