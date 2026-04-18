-- EVAL-019: Cross-session continuity seed data.
-- Seeds 20 "session 1" context facts into chump_blackboard_persist.
-- Each fact is written with entity-rich content so COG-015's entity
-- prefetch can retrieve it when the session-2 prompt mentions matching entities.
--
-- Usage:
--   sqlite3 sessions/chump_memory.db < scripts/ab-harness/fixtures/cross_session_seeds.sql
--
-- Idempotent: DELETE WHERE content LIKE 'EVAL-019:%' then INSERT.

BEGIN;

DELETE FROM chump_blackboard_persist WHERE content LIKE 'EVAL-019:%';

INSERT INTO chump_blackboard_persist (content, salience) VALUES
  ('EVAL-019: auralux FFT — User is working on a Rust audio DSP crate called auralux — next milestone is implementing the FFT module using rustfft.', 0.9),
  ('EVAL-019: helios PostgreSQL — Architecture decision: the helios user-service uses PostgreSQL (not MongoDB) for ACID transactions on account linking.', 0.9),
  ('EVAL-019: prism API kebab-case — Naming convention: all prism API endpoints use kebab-case with a /v2/ prefix, e.g. /v2/user-profile, /v2/auth-token.', 0.9),
  ('EVAL-019: nexus-worker deadlock — Bug: nexus-worker job queue deadlocks when more than 12 concurrent workers acquire the same database row lock. Repros under load.', 0.9),
  ('EVAL-019: sentinel SENTINEL_MAX_RETRIES — Config: sentinel service uses SENTINEL_MAX_RETRIES=5 and SENTINEL_TIMEOUT_MS=3000 (tuned 2026-04-10).', 0.9),
  ('EVAL-019: vortex axum — Tech choice: vortex HTTP server uses axum (not actix-web) for tower middleware ecosystem and simpler async model.', 0.9),
  ('EVAL-019: cobalt-db migration v43 — cobalt-db is at migration v42; next migration v43 adds index on events.user_id column.', 0.9),
  ('EVAL-019: aurora LRU cache sprint 14 — Sprint 14 goal for team-echo: ship aurora cache layer with LRU eviction policy and 10-second TTL default.', 0.9),
  ('EVAL-019: beacon OOM Arc WebSocket — Root cause: beacon service OOM crashes caused by leaked Arc<Mutex<Vec<u8>>> buffers in WebSocket handler (~2MB per dropped connection).', 0.9),
  ('EVAL-019: meridian Python 3.12 match — meridian service upgraded to Python 3.12 (from 3.10) to use match statement syntax for the event router.', 0.9),
  ('EVAL-019: flux proptest parser — Test plan: flux parser uses property-based tests with proptest; message broker uses integration tests against real NATS.', 0.9),
  ('EVAL-019: radiant JWT 15-minute — Auth: radiant API uses stateless JWTs with 15-minute expiry and refresh tokens in HttpOnly cookies.', 0.9),
  ('EVAL-019: solstice-core event_dispatcher — Refactor scope: only touch event_dispatcher.rs in solstice-core this sprint; do NOT touch scheduler or persistence layer until v2.', 0.9),
  ('EVAL-019: pulsar-gateway circuit breaker PULSE-4421 — Incident 2026-04-15: pulsar-gateway cascade outage caused by missing circuit breaker on omega-pricing call. Ticket: PULSE-4421.', 0.9),
  ('EVAL-019: nova-agent tracing — Logging decision: nova-agent uses tracing crate with JSON output via tracing-subscriber (not log or slog).', 0.9),
  ('EVAL-019: ember-service ARM64 x86_64 — Deployment: ember-service runs ARM64 (dev) and x86_64 (CI); Dockerfile must use multi-arch builds.', 0.9),
  ('EVAL-019: quartz /batch /stream deprecation — quartz v2.4 (May) deprecates legacy /batch endpoint in favor of /stream.', 0.9),
  ('EVAL-019: opal p99 50ms — Performance target: opal query engine p99 < 50ms for <= 1000 rows. Current baseline: 130ms. Need 60% reduction.', 0.9),
  ('EVAL-019: prism feat/ branch naming — Branch naming: prism feature branches use feat/<ticket-id>/<short-description> format, e.g. feat/PRISM-123/add-oauth.', 0.9),
  ('EVAL-019: zenith rollback zenith-pre-migration — Rollback plan: if zenith migration causes p99 regression > 20%, restore from snapshots/zenith-pre-migration.sql (created 2026-04-17).', 0.9);

COMMIT;

SELECT COUNT(*) AS seeded_cross_session_facts FROM chump_blackboard_persist WHERE content LIKE 'EVAL-019:%';
