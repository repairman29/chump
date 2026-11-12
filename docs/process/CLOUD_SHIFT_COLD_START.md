# Cloud shift cold-start: cached tailscale + bus deps (INFRA-8066)

Each ephemeral cloud shift used to re-download Tailscale (~38MB) and re-pip-install
`nats-py`/`nkeys`/`pynacl` in `cloud_worker.sh up` before taking a task (~60-90s/shift).

## Where the fix lives

The implementation is in the private `chump-proprietary` repo (PR #21):

- `nats/cloud/env-setup.sh` bakes tailscale + bus deps into the cached environment image.
- `nats/cloud/cloud_worker.sh` prefers pre-installed binaries, skips pip when the deps
  import, and falls back to cold download on an unprimed environment.

Shifts clone `main`, so the worker-side change self-deploys.

## Remaining (operator / follow-up)

1. **One-time UI step:** in the claude.ai cloud environment settings, set the setup script to
   run `nats/cloud/env-setup.sh` so the image is cached.
2. **Receipt:** a shift run log should show `using cached tailscale` and
   `bus deps present (cached)` and reach READY in under ~15s.
3. **Fallback check:** an unprimed environment must still come up via cold download.
4. **Amortize:** widen the shift budget beyond 3 tasks / 120 min so one warm node drains
   more of the queue per spin-up.

## Verifying

```bash
grep -E 'using cached tailscale|bus deps present \(cached\)' shift.log
```

Absence of the "No setup script configured" line confirms step 1 took effect.
