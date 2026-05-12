# Sample Spec for INFRA-636 Testing

## Background

This is a sample spec file used to test `chump gap import-spec`.

## Requests

### REQ-001 — Add dashboard URL to session-track output

**Priority.** P1

**What we need.**
The `session-track` command should expose a `dashboard_url` field so operators
can click directly to the per-session progress view.

**Acceptance.**
`chump session-track show <ID>` includes `dashboard_url` in JSON output.
`scripts/ci/test-session-track-url.sh` passes.

### REQ-002 — Automatic retry on gh API 429

**Priority.** P2

**What we need.**
When `gh` calls return HTTP 429, retry with exponential backoff (max 3 attempts).

**Acceptance.**
Retries observed in ambient stream as `kind=gh_api_retry`.
Registered in EVENT_REGISTRY.yaml.

### REQ-003 — Cost report for completed gaps

**Priority.** P1

**What we need.**
After a gap ships, record token cost + USD in the gap row.

**Acceptance.**
`chump gap show <ID>` includes `cost_usd` field after ship.
Test fixture validates the field is populated.
