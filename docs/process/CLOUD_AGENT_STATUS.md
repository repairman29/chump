# Cloud-agent status write-back (RESILIENT-1466)

Cloud agents (claude.ai/code sessions) report status in chumpOS fashion over NATS.

- **Subject:** `chump.cloud.status`; payload `{ts, kind:"cloud_agent_status", agent, session, phase(start|working|blocked|shipped|done|error), task, summary}`.
- **Durability:** JetStream stream `CLOUD` captures `chump.cloud.>` (file, 30d / 1GB, discard old, 2m dupe window), so status survives with no live subscriber.
- **Publish:** `scripts/coord/emit-cloud-status.sh <phase> <task> <summary>` (always appends `~/.chump/cloud-status.jsonl`). **Read:** `scripts/coord/read-cloud-status.sh [N]`.

## Provisioning (idempotent, no hand edits)

1. `bash scripts/setup/nats-jetstream-block-install.sh` — adds the `jetstream {}` block to `nats.conf`, creates the store dir owned by the nats run-user (`NATS_RUN_USER`, default `nats`).
2. `bash scripts/setup/nats-cloud-stream-install.sh` — creates the `CLOUD` stream.
3. **nats CLI** is a documented dependency on publishing/subscribing nodes: download natscli from <https://github.com/nats-io/natscli/releases> to `~/.local/bin/nats`.
4. `chump-fleet-recorder` (JetStream consumer; NATS→store bridge) is a tracked organ in `scripts/ops/organ-manifest.yaml` and `bootstrap-manifest.yaml`; it needs JetStream on (step 1) to stay active.
5. Decay watch: `scripts/coord/cloud-status-audit.sh` exits 1 and emits `kind=cloud_status_decay` if JetStream is off, the CLOUD stream is missing, or the recorder is dark. Run it from the fleet-health sentinel / a timer.

## Off-tailnet reachability decision

`nats.conf` listens on the tailnet IP only. Cloud sessions not on the tailnet **cannot** reach NATS, and NATS must **never** be exposed publicly without auth. Decision: off-tailnet cloud agents use the **git/gap-store fallback** — they commit status to their PR/branch (gap notes, PR body) and the tailnet-side shepherd mirrors it into `chump.cloud.status` via `emit-cloud-status.sh`. A future authed relay (token/NKey-authenticated websocket) is the only acceptable direct channel; until it exists, git is the channel of record.
