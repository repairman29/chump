#!/usr/bin/env bash
# scripts/coord/novel-wedge-classifier.sh — INFRA-2067 (META-118 sub-gap 1)
#
# Novel-wedge classifier daemon: scans ambient.jsonl for kind=pr_failed
# events, extracts (failing_test_name, first_error_line_signature_hash),
# tracks recurrences, and emits kind=wedge_class_detected when a novel
# signature repeats >= CHUMP_WEDGE_CLASSIFIER_THRESHOLD times within
# CHUMP_WEDGE_CLASSIFIER_WINDOW_S seconds.
#
# Algorithm:
#   1. Read ambient.jsonl from offset stored in cursor.json
#   2. For each pr_failed event: extract failing_test_name + first_error_line
#   3. Normalize first_error_line (strip timestamps, file:line refs, paths)
#   4. Hash via SHA256 to get signature_hash
#   5. Track in cursor.json: per-signature first_seen, last_seen,
#      occurrence_count, sample_pr_numbers (max 5), window_emit_ts
#   6. When count >= threshold within window AND no re-emit within same window:
#      emit kind=wedge_class_detected
#   7. Rate limit: max 5 wedge_class_detected emits per hour (across all sigs)
#
# Downstream consumers: INFRA-2068 (auto-wedge-file), INFRA-2069 (template
#   library, shipped), INFRA-2070 (cascade-unblock, shipped), INFRA-2071
#   (admin-merge circuit-breaker, shipped).
#
# Cursor state: .chump-locks/wedge-classifier/cursor.json
#   {
#     "offset": <int — byte offset into ambient.jsonl>,
#     "emit_log": [<iso8601>, ...],      # up to last 1h emits for rate-limit
#     "signatures": {
#       "<sig_hash>": {
#         "failing_test_name": str,
#         "first_error_line": str,
#         "first_seen": <epoch_s>,
#         "last_seen": <epoch_s>,
#         "occurrence_count": int,
#         "sample_prs": [str, ...],     # max 5
#         "window_emit_ts": <epoch_s>|null
#       }
#     }
#   }
#
# Config (env):
#   CHUMP_WEDGE_CLASSIFIER_THRESHOLD   N occurrences to classify (default 3)
#   CHUMP_WEDGE_CLASSIFIER_WINDOW_S    window in seconds (default 1800)
#   CHUMP_WEDGE_CLASSIFIER_RATE_LIMIT  max emits per hour total (default 5)
#   CHUMP_WEDGE_CLASSIFIER_SKIP=1      no-op bypass
#   CHUMP_WEDGE_CLASSIFIER_DRY_RUN=1   classify but don't write emits
#   CHUMP_AMBIENT_LOG                  path to ambient.jsonl
#   CHUMP_REPO                         repo root (fallback: git rev-parse)
#
# Exit codes:
#   0 — normal run (including no events found)
#   1 — fatal (cursor corrupt, ambient unreadable)
#   2 — internal error (python missing, jq missing)

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
CURSOR_DIR="$REPO_ROOT/.chump-locks/wedge-classifier"
CURSOR="$CURSOR_DIR/cursor.json"

THRESHOLD="${CHUMP_WEDGE_CLASSIFIER_THRESHOLD:-3}"
WINDOW_S="${CHUMP_WEDGE_CLASSIFIER_WINDOW_S:-1800}"
RATE_LIMIT="${CHUMP_WEDGE_CLASSIFIER_RATE_LIMIT:-5}"
SKIP="${CHUMP_WEDGE_CLASSIFIER_SKIP:-0}"
DRY_RUN="${CHUMP_WEDGE_CLASSIFIER_DRY_RUN:-0}"

if [[ "$SKIP" == "1" ]]; then
    echo "[novel-wedge-classifier] skipped (CHUMP_WEDGE_CLASSIFIER_SKIP=1)"
    exit 0
fi

# ── Dependency checks ────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    echo "[novel-wedge-classifier] FATAL: python3 not found" >&2
    exit 2
fi

# ── Emit helper ─────────────────────────────────────────────────────────────
_emit() {
    local kind="$1"; shift
    local payload="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$payload}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] would emit: $line"
    else
        mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
        printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# ── Daemon tick emit (INFRA-2280 META-118 scheduling activation) ─────────────
_emit "meta_118_daemon_tick" "\"daemon\":\"novel-wedge-classifier\",\"source\":\"novel_wedge_classifier\""

# ── Main logic via Python (for robust JSON + SHA256 + state) ─────────────────
python3 - "$AMBIENT" "$CURSOR" "$THRESHOLD" "$WINDOW_S" "$RATE_LIMIT" "$DRY_RUN" <<'PYEOF'
import sys, json, os, hashlib, re, time

ambient_path = sys.argv[1]
cursor_path  = sys.argv[2]
threshold    = int(sys.argv[3])
window_s     = int(sys.argv[4])
rate_limit   = int(sys.argv[5])
dry_run      = sys.argv[6] == "1"

now_s = int(time.time())
hour_ago_s = now_s - 3600

# ── Load or init cursor ──────────────────────────────────────────────────────
os.makedirs(os.path.dirname(cursor_path), exist_ok=True)
if os.path.exists(cursor_path):
    try:
        with open(cursor_path) as f:
            cursor = json.load(f)
    except (json.JSONDecodeError, ValueError):
        sys.stderr.write("[novel-wedge-classifier] WARN: corrupt cursor.json — resetting\n")
        cursor = {}
else:
    cursor = {}

cursor.setdefault("offset", 0)
cursor.setdefault("emit_log", [])
cursor.setdefault("signatures", {})

# ── Read ambient.jsonl from offset ───────────────────────────────────────────
if not os.path.exists(ambient_path):
    # Nothing to process yet — persist cursor and exit cleanly.
    with open(cursor_path, "w") as f:
        json.dump(cursor, f, indent=2)
    sys.exit(0)

new_events = []
try:
    with open(ambient_path, "rb") as f:
        f.seek(cursor["offset"])
        raw = f.read()
        new_offset = cursor["offset"] + len(raw)
except OSError as e:
    sys.stderr.write(f"[novel-wedge-classifier] FATAL: cannot read ambient.jsonl: {e}\n")
    sys.exit(1)

for line in raw.decode("utf-8", errors="replace").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("kind") == "pr_failed":
        new_events.append(ev)

cursor["offset"] = new_offset

# ── Normalize + hash first_error_line ────────────────────────────────────────
_PATH_PAT   = re.compile(r'/(?:home|Users|tmp|private/tmp)/[^\s:]+')
_FILELINE   = re.compile(r'\b\w[\w./\-]+\.(?:rs|go|py|sh|ts|js):\d+')
_TIMESTAMP  = re.compile(r'\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\b')
_HEX        = re.compile(r'\b[0-9a-f]{7,64}\b')
_WHITESPACE = re.compile(r'\s+')

def normalize(line: str) -> str:
    line = _PATH_PAT.sub('<PATH>', line)
    line = _FILELINE.sub('<FILELINE>', line)
    line = _TIMESTAMP.sub('<TS>', line)
    line = _HEX.sub('<HEX>', line)
    line = _WHITESPACE.sub(' ', line).strip()
    return line

def sig_hash(test_name: str, first_error: str) -> str:
    normed = normalize(first_error)
    raw = f"{test_name}|{normed}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]

# ── Rate-limit state: prune emit_log to last hour ────────────────────────────
cursor["emit_log"] = [
    ts for ts in cursor["emit_log"]
    if ts >= time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(hour_ago_s))
]

emits_this_run = 0

# ── Process each pr_failed event ─────────────────────────────────────────────
for ev in new_events:
    pr_number = str(ev.get("pr_number") or ev.get("pr") or "unknown")
    # Support multiple field name conventions
    test_name  = (ev.get("failing_test_name")
                  or ev.get("failing_test")
                  or ev.get("test_name")
                  or "unknown_test")
    first_line = (ev.get("first_error_line")
                  or ev.get("first_error")
                  or ev.get("error_line")
                  or "")

    if not first_line:
        continue  # No extractable signature — skip

    h = sig_hash(test_name, first_line)
    sig = cursor["signatures"].setdefault(h, {
        "failing_test_name": test_name,
        "first_error_line":  first_line,
        "first_seen":        now_s,
        "last_seen":         now_s,
        "occurrence_count":  0,
        "sample_prs":        [],
        "window_emit_ts":    None,
    })

    sig["last_seen"]         = now_s
    sig["occurrence_count"] += 1
    if pr_number not in sig["sample_prs"]:
        if len(sig["sample_prs"]) < 5:
            sig["sample_prs"].append(pr_number)

    # Window check: count occurrences within WINDOW_S of first_seen
    window_start = sig["last_seen"] - window_s
    # first_seen might be in a previous window — reset if so
    if sig["first_seen"] < window_start:
        sig["first_seen"]        = now_s
        sig["occurrence_count"]  = 1
        sig["sample_prs"]        = [pr_number] if pr_number != "unknown" else []
        sig["window_emit_ts"]    = None
        continue  # Not enough in this new window yet

    if sig["occurrence_count"] < threshold:
        continue  # Not yet classified

    # Check deduplication: don't re-emit within same window
    if sig["window_emit_ts"] is not None:
        emit_window_start = sig["window_emit_ts"]
        if now_s - emit_window_start < window_s:
            continue  # Already emitted for this window

    # Rate limit check
    if len(cursor["emit_log"]) >= rate_limit:
        sys.stderr.write(
            f"[novel-wedge-classifier] rate limit reached ({rate_limit}/h) — "
            f"skipping emit for sig={h}\n"
        )
        continue

    # Emit wedge_class_detected
    payload_obj = {
        "signature_hash":    h,
        "failing_test_name": sig["failing_test_name"],
        "first_error_line":  sig["first_error_line"],
        "occurrence_count":  sig["occurrence_count"],
        "sample_pr_numbers": sig["sample_prs"],
        "window_s":          window_s,
        "threshold":         threshold,
        "source":            "novel-wedge-classifier",
    }
    payload_json = json.dumps(payload_obj)

    ts_now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now_s))
    emit_line = json.dumps({
        "ts":   ts_now,
        "kind": "wedge_class_detected",
        **payload_obj,
    }, separators=(',', ':'))

    if dry_run:
        print(f"[dry-run] would emit: {emit_line}")
    else:
        ambient_dir = os.path.dirname(ambient_path)
        os.makedirs(ambient_dir, exist_ok=True)
        with open(ambient_path, "a") as af:
            af.write(emit_line + "\n")

    sig["window_emit_ts"] = now_s
    cursor["emit_log"].append(ts_now)
    emits_this_run += 1
    print(f"[novel-wedge-classifier] wedge_class_detected: sig={h} test={test_name!r} count={sig['occurrence_count']}")

# ── Persist cursor ────────────────────────────────────────────────────────────
with open(cursor_path, "w") as f:
    json.dump(cursor, f, indent=2)

if emits_this_run == 0 and not new_events:
    pass  # silent no-op when nothing to do
elif not new_events:
    print(f"[novel-wedge-classifier] processed 0 pr_failed events from offset {cursor['offset']}")
else:
    print(f"[novel-wedge-classifier] processed {len(new_events)} pr_failed events; "
          f"{emits_this_run} wedge_class_detected emits")
PYEOF
