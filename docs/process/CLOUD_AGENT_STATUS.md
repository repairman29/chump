# Cloud-agent status write-back (RESILIENT-1466)

Cloud agents (claude.ai/code sessions) report status in a chumpOS fashion.

- Subject: `chump.cloud.status`; payload `{ts, kind:"cloud_agent_status", agent, session, phase(start|working|blocked|shipped|done|error), task, summary}`.
- Durability: JetStream stream `CLOUD` (`chump.cloud.>`, file, 30d / 1GB), created by `scripts/setup/nats-cloud-stream-install.sh` (after `scripts/setup/nats-jetstream-block-install.sh`).
- Publish: `scripts/coord/emit-cloud-status.sh <phase> <task> <summary>` — always appends `~/.chump/cloud-status.jsonl`; publishes to NATS when `nats` and `CHUMP_NATS_URL` are set.
- Read: `scripts/coord/read-cloud-status.sh [N]` (stream replay, else local jsonl).
- Dependency: `nats` CLI (natscli v0.5.0+) on any node that publishes/subscribes.

## Off-tailnet reachability decision

NATS listens on the tailnet IP only. Cloud sessions not on the tailnet MUST NOT
get unauthenticated public NATS. Decision: off-tailnet agents use the
**git/gap-store fallback** — they run `emit-cloud-status.sh` (local jsonl) and
write status into their PR body / gap notes via normal `gh`/`chump gap` paths,
which the fleet already ingests. A future authed relay (token-auth websocket in
front of NATS) is the only acceptable network path; never open 4222 publicly.

## Decay detection (follow-up slice RESILIENT-2227)

AC5 (fleet-recorder organ + watcher) and AC7 (state-audit check for
JetStream-off / CLOUD-missing / recorder-dark) are tracked in RESILIENT-2227.
