#!/usr/bin/env python3.12
"""Generate fixtures/longitudinal_trace.json for EVAL-021.

Produces a 100-session synthetic trace for the fictional "stellar-api"
project, with accumulated facts at checkpoints [10, 25, 50, 75, 100]
and 20 held-out evaluation tasks that span the full session range.

Usage:
    python3.12 gen-longitudinal-fixture.py
    # writes scripts/ab-harness/fixtures/longitudinal_trace.json
"""
from __future__ import annotations
import json
from pathlib import Path

# ---------------------------------------------------------------------------
# 100-session trace: each entry is (session_number, [fact_strings])
# The facts are realistic project-knowledge snippets written in a format
# that the entity-prefetch/blackboard system could store and retrieve.
# ---------------------------------------------------------------------------
SESSION_FACTS: list[tuple[int, list[str]]] = [
    # Sessions 1-10: Framework / stack selection
    (1,  ["stellar-api is written in Rust."]),
    (2,  ["stellar-api HTTP layer: axum (not actix-web) — chosen for tower middleware ecosystem."]),
    (3,  ["stellar-api database: PostgreSQL (not MySQL) — chosen for ACID transactions."]),
    (4,  ["stellar-api auth: stateless JWTs, 24-hour expiry, refresh token in HttpOnly cookie."]),
    (5,  ["stellar-api testing: criterion for benchmarks, proptest for property-based tests."]),
    (6,  ["stellar-api CI: GitHub Actions — runs cargo test, clippy (deny warnings), rustfmt check."]),
    (7,  ["stellar-api error handling: thiserror for library errors, anyhow for application errors."]),
    (8,  ["stellar-api logging: tracing crate with JSON output via tracing-subscriber; opentelemetry for distributed spans."]),
    (9,  ["stellar-api deployment: Docker multi-arch images (linux/arm64 dev, linux/amd64 CI/prod)."]),
    (10, ["stellar-api code style: rustfmt + clippy enforced in CI; deny(warnings) is set."]),

    # Sessions 11-20: Architecture
    (11, ["stellar-api API versioning: all endpoints prefixed with /v1/."]),
    (12, ["stellar-api rate limiting: tower-http RateLimitLayer, 100 req/s per IP."]),
    (13, ["stellar-api caching: Redis for session and profile data."]),
    (14, ["stellar-api cache TTLs: user profile = 60 s, catalog items = 300 s, auth tokens = JWT TTL."]),
    (15, ["stellar-api connection pool: deadpool-postgres, max_size = 20."]),
    (16, ["stellar-api CORS: allow only *.stellar.io origins."]),
    (17, ["stellar-api pagination: cursor-based, max page_size = 100."]),
    (18, ["stellar-api metrics: Prometheus via axum-prometheus, exposed on /metrics."]),
    (19, ["stellar-api healthcheck: GET /v1/health returns {\"status\":\"ok\",\"db\":\"ok\",\"cache\":\"ok\"}."]),
    (20, ["stellar-api config: environment variables loaded via dotenvy crate."]),

    # Sessions 21-30: First bug wave
    (21, ["Bug found: users.email column missing index — slow queries on email lookup."]),
    (22, ["Bug found: WebSocket handler leaks Arc<Mutex<Vec<u8>>> buffers — OOM after ~500 connections (~2 MB per dropped connection)."]),
    (23, ["Bug found: job queue deadlocks when >8 concurrent workers acquire the same DB row lock."]),
    (24, ["Bug found: Redis connection not returned to pool on timeout — pool exhaustion under load."]),
    (25, ["Security fix: JWT was using HS256; switched to RS256 with rotating keys."]),
    (26, ["Fix shipped: migration v07 adds index on users.email."]),
    (27, ["Fix shipped: WebSocket handler refactored to use weak refs — OOM resolved."]),
    (28, ["Fix shipped: job queue now uses SELECT FOR UPDATE SKIP LOCKED — deadlock resolved."]),
    (29, ["Fix shipped: Redis pool sets connection_timeout = 5 s, max_lifetime = 60 s."]),
    (30, ["Fix shipped: JWT now uses RS256; public keys cached for 5 minutes."]),

    # Sessions 31-40: Performance
    (31, ["Perf target: /v1/health p99 < 5 ms."]),
    (32, ["Perf target: /v1/user-profile p99 < 50 ms (cache hit), < 200 ms (miss)."]),
    (33, ["Perf target: /v1/catalog p99 < 100 ms for up to 1000 rows."]),
    (34, ["Perf baseline: /v1/health = 2 ms, /v1/user-profile = 320 ms, /v1/catalog = 890 ms."]),
    (35, ["Optimization: /v1/user-profile reads Redis first — p99 drops to 45 ms."]),
    (36, ["Optimization: /v1/catalog uses indexed scan + LIMIT — p99 drops to 80 ms."]),
    (37, ["Optimization: DB read replicas added for read-heavy endpoints."]),
    (38, ["Optimization: connection pool warmed up at startup (5 idle connections)."]),
    (39, ["Optimization: HTTP/2 enabled via hyper — reduces per-request connection overhead."]),
    (40, ["Load test result: stellar-api handles 500 req/s sustained at p99 < 100 ms on 4 cores."]),

    # Sessions 41-50: New features
    (41, ["Feature shipped: OAuth2 login via GitHub (scopes: user:email)."]),
    (42, ["Feature shipped: OAuth2 login via Google (scopes: openid email profile)."]),
    (43, ["Feature shipped: webhook delivery — POST to registered URL, retry 3× with exponential backoff."]),
    (44, ["Feature shipped: webhook signatures — HMAC-SHA256 in X-Stellar-Signature header."]),
    (45, ["Feature shipped: audit log — immutable append-only events table with FK to users."]),
    (46, ["Feature shipped: soft deletes — deleted_at timestamp on users/accounts, no hard DELETEs."]),
    (47, ["Feature shipped: API keys — sk_ prefix for secret, pk_ for public; stored as bcrypt hash."]),
    (48, ["Feature shipped: multi-tenancy — tenant_id on all tables, enforced via PostgreSQL RLS."]),
    (49, ["Feature shipped: file uploads — S3-compatible via aws-sdk-s3, max 100 MB, signed URLs."]),
    (50, ["Feature shipped: scheduled jobs — tokio-cron-scheduler, job state persisted in DB."]),

    # Sessions 51-60: Scaling
    (51, ["Scaling: stellar-api is fully stateless — no sticky sessions, no in-process shared state."]),
    (52, ["Scaling: Kubernetes HPA — min = 2 pods, max = 10 pods, CPU target = 70%."]),
    (53, ["Scaling: PodDisruptionBudget — min 1 pod available during disruptions."]),
    (54, ["Scaling: rolling update strategy — max_unavailable = 0, max_surge = 1."]),
    (55, ["Scaling: DB — primary + 2 read replicas; pgBouncer for DB-level connection pooling."]),
    (56, ["Scaling: Redis in Sentinel mode — 1 primary + 2 replicas for HA."]),
    (57, ["Scaling: Cloudflare CDN in front for static assets and edge caching."]),
    (58, ["Scaling: event queue — NATS JetStream for async job dispatch."]),
    (59, ["Scaling: stellar-worker is a separate gRPC service handling background jobs."]),
    (60, ["Scaling: circuit breakers on all external calls (stellar-worker, S3, webhooks)."]),

    # Sessions 61-70: Security hardening
    (61, ["Security: parameterized queries only — no string interpolation in SQL."]),
    (62, ["Security: input validation via validator crate; max field lengths enforced."]),
    (63, ["Security: CSP headers — default-src 'self', no inline scripts allowed."]),
    (64, ["Security: HSTS — max-age = 31536000, includeSubDomains."]),
    (65, ["Security: auth endpoint rate limiting tightened to 5 req/min per IP."]),
    (66, ["Security: all secrets stored in HashiCorp Vault, rotated monthly."]),
    (67, ["Security: cargo deny checks for licenses and security advisories in CI."]),
    (68, ["Security: never log passwords, tokens, or PII — enforced in tracing spans."]),
    (69, ["Security: API keys expire after 90 days; email reminder sent at day 75."]),
    (70, ["Security: penetration test 2026-03 — no critical findings; 2 medium findings fixed."]),

    # Sessions 71-80: Refactoring
    (71, ["Refactor: domain split into user_service and catalog_service modules."]),
    (72, ["Refactor: event sourcing for audit trail — events table is source of truth."]),
    (73, ["Refactor: CQRS introduced for high-read tables — separate read models."]),
    (74, ["Refactor: error types consolidated into stellar_errors crate."]),
    (75, ["Refactor: duplicate auth middleware removed from middleware stack."]),
    (76, ["Refactor: database access layer switched from diesel to sqlx (async)."]),
    (77, ["Refactor: config management switched from dotenvy to figment (layered config)."]),
    (78, ["Refactor: legacy /v0/ endpoints removed (deprecated 2025-12, removed 2026-04)."]),
    (79, ["Refactor: stellar-test-utils crate created for shared test fixtures."]),
    (80, ["Refactor: OpenAPI 3.1 spec auto-generated via utoipa."]),

    # Sessions 81-90: Final tuning
    (81, ["Tuning: DB connection pool max_size raised from 20 to 50 after load testing."]),
    (82, ["Tuning: top-1000 catalog items pre-loaded into Redis cache at startup."]),
    (83, ["Tuning: graceful shutdown — 30-second drain timeout for in-flight requests."]),
    (84, ["Tuning: allocator switched from jemalloc to mimalloc — 15% RSS reduction."]),
    (85, ["Tuning: tokio worker threads = num_cpus × 2, set at startup."]),
    (86, ["Tuning: Redis pipelining for bulk cache reads — 40% latency reduction."]),
    (87, ["Tuning: PostgreSQL autovacuum tuned for high-churn tables (audit_events, webhooks)."]),
    (88, ["Tuning: reqwest HTTP client uses connection pool with idle_timeout = 90 s."]),
    (89, ["Tuning: tracing sample rate = 100% for errors, 10% for success in production."]),
    (90, ["Tuning: monthly chaos engineering runs — kill random pod, verify recovery < 30 s."]),

    # Sessions 91-100: Production operations
    (91, ["Operations: runbooks documented in docs/runbooks/ (incident, scaling, rollback)."]),
    (92, ["Operations: PagerDuty alerts fire when p99 > 500 ms for 2 min OR error rate > 1%."]),
    (93, ["Operations: on-call rotation — 1-week shifts, 2 engineers per shift."]),
    (94, ["Operations: backups — pg_dump daily + WAL streaming to S3, restore tested monthly."]),
    (95, ["Operations: disaster recovery — RTO < 1 hr, RPO < 5 min (tested 2026-04)."]),
    (96, ["Operations: AWS cost tracking via resource tags per service."]),
    (97, ["Operations: capacity planning review every quarter."]),
    (98, ["Operations: blameless post-mortems published in docs/post-mortems/."]),
    (99, ["Operations: SLO — 99.9% uptime per month (43.8-minute downtime budget)."]),
    (100,["Operations: SLI dashboard in Grafana, shared real-time with stakeholders."]),
]

# ---------------------------------------------------------------------------
# Held-out evaluation tasks — 20 tasks spanning the full session range.
# For each checkpoint, a task is "answerable" if the answer fact was
# established in a session <= that checkpoint.
# ---------------------------------------------------------------------------
HELD_OUT_TASKS: list[dict] = [
    # Checkpoint 10 tasks (sessions 1-10)
    {
        "id": "lg-01",
        "category": "stack",
        "first_answerable_at": 2,
        "prompt": "What HTTP framework does stellar-api use, and why was it chosen?",
        "expected_in_response": "axum",
        "judge_rubric": (
            "Score 1.0 if the response correctly identifies axum as the HTTP framework "
            "for stellar-api and mentions tower middleware as the reason. "
            "Score 0.5 if it names axum without the rationale. "
            "Score 0.0 if it names actix-web or gives a generic answer."
        ),
    },
    {
        "id": "lg-02",
        "category": "stack",
        "first_answerable_at": 3,
        "prompt": "What database does stellar-api use and why was it chosen over alternatives?",
        "expected_in_response": "PostgreSQL",
        "judge_rubric": (
            "Score 1.0 if the response identifies PostgreSQL and mentions ACID transactions "
            "as the rationale. Score 0.5 if PostgreSQL is named without rationale. "
            "Score 0.0 if MySQL or another DB is suggested."
        ),
    },
    {
        "id": "lg-03",
        "category": "testing",
        "first_answerable_at": 5,
        "prompt": "What crates does stellar-api use for performance benchmarking and property-based testing?",
        "expected_in_response": "criterion",
        "judge_rubric": (
            "Score 1.0 if the response names both criterion (benchmarks) and proptest "
            "(property-based tests) for stellar-api. Score 0.5 if only one is named. "
            "Score 0.0 if neither is mentioned."
        ),
    },
    {
        "id": "lg-04",
        "category": "error-handling",
        "first_answerable_at": 7,
        "prompt": "What error-handling crates does stellar-api use for library vs application code?",
        "expected_in_response": "thiserror",
        "judge_rubric": (
            "Score 1.0 if the response names thiserror for library errors and anyhow for "
            "application errors in stellar-api. Score 0.5 if only one is named. "
            "Score 0.0 if it gives generic advice without naming both."
        ),
    },
    # Checkpoint 25 tasks (sessions 11-25)
    {
        "id": "lg-05",
        "category": "caching",
        "first_answerable_at": 14,
        "prompt": "What is the Redis cache TTL for user profile data in stellar-api?",
        "expected_in_response": "60",
        "judge_rubric": (
            "Score 1.0 if the response correctly states user profile TTL = 60 seconds "
            "for stellar-api's Redis cache. Score 0.5 if it says 'short TTL' without "
            "the specific value. Score 0.0 if it invents a different number."
        ),
    },
    {
        "id": "lg-06",
        "category": "database",
        "first_answerable_at": 15,
        "prompt": "What is the original database connection pool max size for stellar-api?",
        "expected_in_response": "20",
        "judge_rubric": (
            "Score 1.0 if the response gives max_size = 20 for stellar-api's "
            "deadpool-postgres connection pool (original config). "
            "Score 0.0 if it gives 50 (the post-tuning value) or any other number."
        ),
    },
    {
        "id": "lg-07",
        "category": "security",
        "first_answerable_at": 16,
        "prompt": "What CORS origins does stellar-api allow?",
        "expected_in_response": "stellar.io",
        "judge_rubric": (
            "Score 1.0 if the response states stellar-api allows *.stellar.io origins. "
            "Score 0.0 if it gives a different pattern or says all origins are allowed."
        ),
    },
    {
        "id": "lg-08",
        "category": "security",
        "first_answerable_at": 25,
        "prompt": "What JWT signing algorithm does stellar-api use after the security fix?",
        "expected_in_response": "RS256",
        "judge_rubric": (
            "Score 1.0 if the response says stellar-api uses RS256 (switched from HS256). "
            "Score 0.0 if it says HS256 (the old value) or a different algorithm."
        ),
    },
    # Checkpoint 50 tasks (sessions 26-50)
    {
        "id": "lg-09",
        "category": "debugging",
        "first_answerable_at": 22,
        "prompt": "What was the root cause of the OOM crashes in stellar-api?",
        "expected_in_response": "WebSocket",
        "judge_rubric": (
            "Score 1.0 if the response identifies the leaking Arc<Mutex<Vec<u8>>> buffers "
            "in the WebSocket handler (~2 MB per dropped connection) as the OOM cause. "
            "Score 0.0 if it gives a generic answer not referencing the WebSocket handler."
        ),
    },
    {
        "id": "lg-10",
        "category": "performance",
        "first_answerable_at": 32,
        "prompt": "What is the p99 latency target for /v1/user-profile on a cache hit?",
        "expected_in_response": "50",
        "judge_rubric": (
            "Score 1.0 if the response gives p99 < 50 ms for a cache hit on "
            "/v1/user-profile in stellar-api. Score 0.0 if it gives a different target."
        ),
    },
    {
        "id": "lg-11",
        "category": "features",
        "first_answerable_at": 43,
        "prompt": "How many times does stellar-api retry failed webhook deliveries?",
        "expected_in_response": "3",
        "judge_rubric": (
            "Score 1.0 if the response says stellar-api retries webhooks 3 times with "
            "exponential backoff. Score 0.0 if it gives a different retry count."
        ),
    },
    {
        "id": "lg-12",
        "category": "features",
        "first_answerable_at": 41,
        "prompt": "What OAuth2 providers does stellar-api support?",
        "expected_in_response": "GitHub",
        "judge_rubric": (
            "Score 1.0 if the response names both GitHub and Google as stellar-api's "
            "OAuth2 providers. Score 0.5 if only one is named. "
            "Score 0.0 if a different provider is mentioned."
        ),
    },
    # Checkpoint 75 tasks (sessions 51-75)
    {
        "id": "lg-13",
        "category": "scaling",
        "first_answerable_at": 52,
        "prompt": "What are the Kubernetes HPA min and max pod counts for stellar-api?",
        "expected_in_response": "10",
        "judge_rubric": (
            "Score 1.0 if the response gives min = 2 pods and max = 10 pods for "
            "stellar-api's HPA config. Score 0.5 if only one bound is correct. "
            "Score 0.0 if different values are given."
        ),
    },
    {
        "id": "lg-14",
        "category": "scaling",
        "first_answerable_at": 58,
        "prompt": "What event queue technology does stellar-api use for async job dispatch?",
        "expected_in_response": "NATS",
        "judge_rubric": (
            "Score 1.0 if the response names NATS JetStream as stellar-api's event queue "
            "for async job dispatch. Score 0.0 if a different queue (Kafka, RabbitMQ, etc.) is named."
        ),
    },
    {
        "id": "lg-15",
        "category": "security",
        "first_answerable_at": 61,
        "prompt": "What SQL security practice does stellar-api mandate?",
        "expected_in_response": "parameterized",
        "judge_rubric": (
            "Score 1.0 if the response states stellar-api requires parameterized queries "
            "only (no string interpolation). Score 0.0 if it gives a generic answer."
        ),
    },
    {
        "id": "lg-16",
        "category": "scaling",
        "first_answerable_at": 56,
        "prompt": "What Redis deployment mode does stellar-api use for high availability?",
        "expected_in_response": "Sentinel",
        "judge_rubric": (
            "Score 1.0 if the response says stellar-api uses Redis Sentinel mode "
            "(1 primary + 2 replicas). Score 0.0 if it says Cluster or standalone."
        ),
    },
    # Checkpoint 100 tasks (sessions 76-100)
    {
        "id": "lg-17",
        "category": "refactoring",
        "first_answerable_at": 76,
        "prompt": "What database access crate replaced diesel in the stellar-api refactor?",
        "expected_in_response": "sqlx",
        "judge_rubric": (
            "Score 1.0 if the response says sqlx replaced diesel in stellar-api. "
            "Score 0.0 if it says diesel is still in use or names a different crate."
        ),
    },
    {
        "id": "lg-18",
        "category": "operations",
        "first_answerable_at": 83,
        "prompt": "What is the graceful shutdown drain timeout for stellar-api?",
        "expected_in_response": "30",
        "judge_rubric": (
            "Score 1.0 if the response gives a 30-second graceful shutdown drain timeout "
            "for stellar-api. Score 0.0 if a different duration is given."
        ),
    },
    {
        "id": "lg-19",
        "category": "operations",
        "first_answerable_at": 99,
        "prompt": "What is stellar-api's monthly uptime SLO?",
        "expected_in_response": "99.9",
        "judge_rubric": (
            "Score 1.0 if the response gives 99.9% monthly uptime as stellar-api's SLO "
            "(43.8-minute downtime budget). Score 0.0 if a different percentage is given."
        ),
    },
    {
        "id": "lg-20",
        "category": "operations",
        "first_answerable_at": 81,
        "prompt": "What is stellar-api's DB connection pool max size after tuning?",
        "expected_in_response": "50",
        "judge_rubric": (
            "Score 1.0 if the response gives max_size = 50 (the post-tuning value after "
            "raising from 20). Score 0.0 if it gives 20 (the original) or another number."
        ),
    },
]

CHECKPOINTS = [10, 25, 50, 75, 100]


def build_accumulated_facts(checkpoint: int) -> list[str]:
    """Return all facts from sessions 1..checkpoint as a flat list."""
    facts = []
    for session_num, session_facts in SESSION_FACTS:
        if session_num <= checkpoint:
            for fact in session_facts:
                facts.append(f"[session-{session_num:03d}] {fact}")
    return facts


def build_fixture() -> dict:
    session_trace = []
    for session_num, facts in SESSION_FACTS:
        session_trace.append({
            "session": session_num,
            "facts": facts,
        })

    accumulated = {}
    for cp in CHECKPOINTS:
        accumulated[str(cp)] = build_accumulated_facts(cp)

    return {
        "_comment": (
            "EVAL-021: Longitudinal accumulation A/B. Synthetic 100-session trace "
            "for the fictional 'stellar-api' project. Mode A: inject all accumulated "
            "facts from sessions 1..checkpoint into each held-out task system prompt. "
            "Mode B: no accumulated context. "
            "Checkpoints: [10, 25, 50, 75, 100]. "
            "Metric: does the held-out task score improve as accumulated context grows?"
        ),
        "project": "stellar-api",
        "checkpoints": CHECKPOINTS,
        "session_trace": session_trace,
        "accumulated_facts": accumulated,
        "held_out_tasks": HELD_OUT_TASKS,
    }


def main() -> None:
    fixture = build_fixture()
    out_path = Path(__file__).parent / "fixtures" / "longitudinal_trace.json"
    out_path.write_text(json.dumps(fixture, indent=2))

    # Quick validation
    for cp in CHECKPOINTS:
        n = len(fixture["accumulated_facts"][str(cp)])
        print(f"  checkpoint {cp:3d}: {n} accumulated facts")
    print(f"  held-out tasks:   {len(fixture['held_out_tasks'])}")
    cp_range = {cp: 0 for cp in CHECKPOINTS}
    for task in fixture["held_out_tasks"]:
        fa = task["first_answerable_at"]
        for cp in CHECKPOINTS:
            if fa <= cp:
                cp_range[cp] += 1
                break
    print("  Tasks first answerable per checkpoint window:")
    for cp, count in cp_range.items():
        print(f"    session <= {cp:3d}: {count} task(s)")
    print(f"Written: {out_path}")


if __name__ == "__main__":
    main()
