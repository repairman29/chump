# Flake Quarantine Runbook

> META-141 operator reference. For the full design rationale, detection
> algorithm, and schema, see [`docs/design/FLAKE_QUARANTINE.md`](../design/FLAKE_QUARANTINE.md).

## What quarantine does

When a test fails with the same error fingerprint across 3 or more distinct
PRs within a 24-hour window, `flake-detector.sh` writes a quarantine entry
to `.chump-locks/quarantined-flakes.json` and emits `kind=flake_detected`
to `ambient.jsonl`. The entry expires automatically after 14 days.

Test runners that source `scripts/coord/lib/flake-quarantine.sh` skip
quarantined tests and emit `kind=flake_skipped` instead of failing the job.

## Viewing current quarantines

```bash
# Pretty-print the quarantine list
python3 -m json.tool .chump-locks/quarantined-flakes.json

# Show only non-expired entries
python3 - <<'EOF'
import json, datetime
with open(".chump-locks/quarantined-flakes.json") as f:
    data = json.load(f)
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
active = [e for e in data if e.get("expires_at", "") > now]
for e in active:
    print(f"{e['test_path']} | fp={e['fingerprint']} | prs={e['affected_pr_count']} | expires={e['expires_at']}")
EOF

# Check the SQLite backing store
sqlite3 .chump/flake_tracker.db \
  "SELECT test_path, fingerprint, quarantined_at, expires_at FROM flake_quarantine;"

# Recent flake_detected events in the ambient stream
grep '"kind":"flake_detected"' .chump-locks/ambient.jsonl | tail -10
```

## Manually adding a quarantine entry

Use this when you know a test is flaky but the 3-PR threshold has not yet
been reached (e.g. you've seen it fail on two PRs and want to pre-empt a
third queue block).

```bash
# Run the detector in dry-run first to confirm the fingerprint
CHUMP_FLAKE_THRESHOLD=2 scripts/coord/flake-detector.sh --dry-run

# If the test is already in the DB with 2+ occurrences, lower the threshold:
CHUMP_FLAKE_THRESHOLD=2 scripts/coord/flake-detector.sh

# To add manually without going through the detector, insert directly:
python3 - <<'EOF'
import json, datetime, pathlib

path = pathlib.Path(".chump-locks/quarantined-flakes.json")
data = json.loads(path.read_text()) if path.exists() else []

now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
expires = (datetime.datetime.utcnow() + datetime.timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ")

entry = {
    "test_path": "crate::module::test_name",   # EDIT THIS
    "fingerprint": "abcdef1234567890",          # EDIT THIS — sha256[:16] of first 200 chars of error
    "quarantined_at": now,
    "expires_at": expires,
    "occurrence_count": 2,
    "affected_pr_count": 2,
    "first_seen": now,
    "last_seen": now,
    "follow_up_gap": "INFRA-XXXX"              # EDIT THIS — file a gap first
}

data = [e for e in data if e.get("test_path") != entry["test_path"]]
data.append(entry)
path.write_text(json.dumps(data, indent=2) + "\n")
print(f"Added quarantine for {entry['test_path']}")
EOF
```

Always file a follow-up gap before manually quarantining so the audit trail
is complete. Set `follow_up_gap` in the entry to the gap ID.

## Manually removing a quarantine entry

Use this when the underlying flake has been fixed and you want to re-enable
the test before the 14-day expiry.

```bash
python3 - <<'EOF'
import json, pathlib, sys

path = pathlib.Path(".chump-locks/quarantined-flakes.json")
test_path = "crate::module::test_name"   # EDIT THIS

data = json.loads(path.read_text())
before = len(data)
data = [e for e in data if e.get("test_path") != test_path]
path.write_text(json.dumps(data, indent=2) + "\n")
print(f"Removed {before - len(data)} entry(ies) for {test_path}")
EOF

# Also remove from the SQLite backing store
sqlite3 .chump/flake_tracker.db \
  "DELETE FROM flake_quarantine WHERE test_path = 'crate::module::test_name';"

# Emit ambient event for audit trail
printf '{"ts":"%s","kind":"flake_unquarantined","test_path":"crate::module::test_name","reason":"manual"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
```

## When to investigate a quarantined test

Quarantine is a hold, not a fix. Investigate immediately when:

- The follow-up gap has been open for more than 7 days.
- `chump fleet flakes` (future CLI) shows more than 10 active quarantines —
  that count triggers `kind=quarantine_creep` and pages the operator.
- A test was quarantined on a PR that *did* touch its source path — that is
  a real regression, not a flake, and should not be quarantined.

To reproduce a quarantined failure locally:

```bash
# Rust test
cargo nextest run --test-threads=1 -- 'crate::module::test_name'

# Run 5 times to confirm intermittency
for i in $(seq 1 5); do
  cargo test crate::module::test_name 2>&1 | tail -3
done
```

## Daemon operation

The detector runs every 30 minutes via launchd after the operator installs it:

```bash
# Install (operator action post-merge, not run by CI)
scripts/setup/install-flake-detector.sh

# Check daemon is registered
launchctl list | grep chump.flake-detector

# Trigger a manual run
launchctl start com.chump.flake-detector

# Watch the log
tail -f /tmp/chump-flake-detector.out.log

# Disable without uninstalling
launchctl stop com.chump.flake-detector
# Or set env bypass:
CHUMP_FLAKE_DETECTOR=0 scripts/coord/flake-detector.sh  # (for manual runs)
```

## Ingesting CI results into flake_tracker.db

The detector only quarantines tests whose failure records are in
`.chump/flake_tracker.db`. Populate it by inserting rows after each CI job:

```bash
# Example: record a failure from a nextest run
sqlite3 .chump/flake_tracker.db <<SQL
INSERT OR IGNORE INTO flake_run
  (test_path, run_id, pr_num, conclusion, error_fingerprint, ts)
VALUES
  ('crate::test', 'run-12345', 99, 'fail',
   '$(printf "error text" | sha256sum | cut -c1-16)',
   '$(date -u +%Y-%m-%dT%H:%M:%SZ)');
SQL
```

A CI integration script to automate this ingestion is tracked as META-142
(Implement Flake Quarantine in Aggregator Status Calculation).
