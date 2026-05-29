-- Fleet events fixture for INFRA-2175 smoke tests.
-- Creates the events table (INFRA-2174 schema) and inserts ~50 representative rows
-- spanning two sessions and multiple activity types.
--
-- Session A: claim-session-aaa  (gap INFRA-100)
-- Session B: claim-session-bbb  (gap INFRA-200)
--
-- ts_ms values are anchored at 1_700_000_000_000 (2023-11-14T22:13:20Z)
-- so tests can use fixed from/to windows.

CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         TEXT NOT NULL,
    ts_ms      INTEGER NOT NULL,
    source     TEXT NOT NULL DEFAULT '',
    subject    TEXT NOT NULL DEFAULT '',
    event_kind TEXT NOT NULL DEFAULT '',
    session_id TEXT NOT NULL DEFAULT '',
    gap_id     TEXT NOT NULL DEFAULT '',
    payload    TEXT NOT NULL DEFAULT '',
    UNIQUE(ts_ms, session_id, event_kind, gap_id)
);

CREATE INDEX IF NOT EXISTS idx_events_ts_ms     ON events(ts_ms);
CREATE INDEX IF NOT EXISTS idx_events_session   ON events(session_id, ts_ms);
CREATE INDEX IF NOT EXISTS idx_events_kind      ON events(event_kind, ts_ms);

-- ── Session A: claim → edit → push → merge ───────────────────────────────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:13:20Z', 1700000000000, 'claude', 'agent', 'INTENT',    'claim-session-aaa', 'INFRA-100', '{"intent":"picking INFRA-100"}'),
  ('2023-11-14T22:13:25Z', 1700000005000, 'claude', 'agent', 'claim',     'claim-session-aaa', 'INFRA-100', '{"gap_id":"INFRA-100","status":"claimed"}'),
  ('2023-11-14T22:14:00Z', 1700000040000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo fmt --all -- --check'),
  ('2023-11-14T22:14:10Z', 1700000050000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo clippy --workspace --all-targets -- -D warnings'),
  ('2023-11-14T22:14:20Z', 1700000060000, 'claude', 'agent', 'Edit',      'claim-session-aaa', 'INFRA-100', 'src/lib.rs'),
  ('2023-11-14T22:14:30Z', 1700000070000, 'claude', 'agent', 'Edit',      'claim-session-aaa', 'INFRA-100', 'src/main.rs'),
  ('2023-11-14T22:14:40Z', 1700000080000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo build --workspace'),
  ('2023-11-14T22:14:50Z', 1700000090000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'git push -u origin chump/infra-100-fix --force-with-lease'),
  ('2023-11-14T22:15:00Z', 1700000100000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'gh pr create --base main --title "fix(INFRA-100): fleet server base"'),
  ('2023-11-14T22:15:10Z', 1700000110000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'gh pr merge 2587 --auto --squash'),
  ('2023-11-14T22:15:20Z', 1700000120000, 'claude', 'agent', 'DONE',      'claim-session-aaa', 'INFRA-100', '{"pr":2587,"status":"merged"}');

-- ── Session A: PR-2587 referenced in payload for /api/trace/pr/2587 ──────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:15:05Z', 1700000105000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'gh pr view 2587 --json mergeStateStatus'),
  ('2023-11-14T22:15:08Z', 1700000108000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'gh pr checks pr 2587');

-- ── Session A: idle gap (>60s) between edit and push ─────────────────────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:16:00Z', 1700000160000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo test --workspace'),
  ('2023-11-14T22:18:05Z', 1700000285000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'git push -u origin chump/infra-100-v2');

-- ── Session B: blocked path ───────────────────────────────────────────────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:13:30Z', 1700000010000, 'claude', 'agent', 'INTENT',    'claim-session-bbb', 'INFRA-200', '{"intent":"picking INFRA-200"}'),
  ('2023-11-14T22:13:35Z', 1700000015000, 'claude', 'agent', 'claim',     'claim-session-bbb', 'INFRA-200', '{"gap_id":"INFRA-200","status":"claimed"}'),
  ('2023-11-14T22:13:45Z', 1700000025000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'cargo build'),
  ('2023-11-14T22:13:55Z', 1700000035000, 'claude', 'agent', 'STUCK',     'claim-session-bbb', 'INFRA-200', '{"reason":"CI red: cannot merge"}'),
  ('2023-11-14T22:14:05Z', 1700000045000, 'claude', 'agent', 'WARN',      'claim-session-bbb', 'INFRA-200', '{"reason":"GraphQL exhausted"}'),
  ('2023-11-14T22:14:15Z', 1700000055000, 'claude', 'agent', 'ALERT',     'claim-session-bbb', 'INFRA-200', '{"reason":"lease expiring soon"}'),
  ('2023-11-14T22:14:25Z', 1700000065000, 'claude', 'agent', 'Edit',      'claim-session-bbb', 'INFRA-200', 'scripts/ci/test-foo.sh'),
  ('2023-11-14T22:14:35Z', 1700000075000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'git push -u origin chump/infra-200-fix'),
  ('2023-11-14T22:14:45Z', 1700000085000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'gh pr create --base main --title "fix(INFRA-200)"'),
  ('2023-11-14T22:15:00Z', 1700000100000, 'claude', 'agent', 'DONE',      'claim-session-bbb', 'INFRA-200', '{"pr":2590,"status":"merged"}');

-- ── Session B: merge event ────────────────────────────────────────────────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:15:02Z', 1700000102000, 'claude', 'agent', 'merge',     'claim-session-bbb', 'INFRA-200', '{"pr":2590}');

-- ── Extra events to reach ~50 rows ───────────────────────────────────────────
INSERT INTO events(ts, ts_ms, source, subject, event_kind, session_id, gap_id, payload) VALUES
  ('2023-11-14T22:16:00Z', 1700000160000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'cargo fmt --all'),
  ('2023-11-14T22:16:10Z', 1700000170000, 'claude', 'agent', 'Edit',      'claim-session-bbb', 'INFRA-200', 'Cargo.toml'),
  ('2023-11-14T22:16:20Z', 1700000180000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'cargo check --workspace'),
  ('2023-11-14T22:16:30Z', 1700000190000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'bot-merge.sh --gap INFRA-200 --auto-merge'),
  ('2023-11-14T22:17:00Z', 1700000220000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo test --workspace -- --test-threads=4'),
  ('2023-11-14T22:17:10Z', 1700000230000, 'claude', 'agent', 'Edit',      'claim-session-aaa', 'INFRA-100', 'crates/chump-fleet-server/src/routes.rs'),
  ('2023-11-14T22:17:20Z', 1700000240000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'cargo clippy --workspace'),
  ('2023-11-14T22:17:30Z', 1700000250000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'git push -u origin chump/infra-100-final'),
  ('2023-11-14T22:17:40Z', 1700000260000, 'claude', 'agent', 'bash_call', 'claim-session-aaa', 'INFRA-100', 'gh pr merge 2588 --auto --squash'),
  ('2023-11-14T22:17:50Z', 1700000270000, 'claude', 'agent', 'DONE',      'claim-session-aaa', 'INFRA-100', '{"pr":2588,"status":"merged"}'),
  ('2023-11-14T22:18:00Z', 1700000280000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'gh pr view 2590 --json state'),
  ('2023-11-14T22:18:10Z', 1700000290000, 'claude', 'agent', 'Edit',      'claim-session-bbb', 'INFRA-200', 'docs/gaps/INFRA-200.yaml'),
  ('2023-11-14T22:18:20Z', 1700000300000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'cargo build --release'),
  ('2023-11-14T22:18:30Z', 1700000310000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-200', 'gh pr checks pr 2590'),
  ('2023-11-14T22:18:40Z', 1700000320000, 'claude', 'agent', 'INTENT',    'claim-session-bbb', 'INFRA-201', '{"intent":"picking INFRA-201 follow-up"}'),
  ('2023-11-14T22:18:50Z', 1700000330000, 'claude', 'agent', 'claim',     'claim-session-bbb', 'INFRA-201', '{"gap_id":"INFRA-201","status":"claimed"}'),
  ('2023-11-14T22:19:00Z', 1700000340000, 'claude', 'agent', 'Edit',      'claim-session-bbb', 'INFRA-201', 'src/new_feature.rs'),
  ('2023-11-14T22:19:10Z', 1700000350000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-201', 'cargo test --package chump-fleet-server'),
  ('2023-11-14T22:19:20Z', 1700000360000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-201', 'git push -u origin chump/infra-201'),
  ('2023-11-14T22:19:30Z', 1700000370000, 'claude', 'agent', 'bash_call', 'claim-session-bbb', 'INFRA-201', 'gh pr create --base main --title "feat(INFRA-201)"');
