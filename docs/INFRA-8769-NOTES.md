# INFRA-8769 — closed not-a-bug: gap-drift health check already fixed by INFRA-8711/INFRA-8712

INFRA-8769 was auto-filed by fleet-doctor's `gap_file` dispatcher
(`src/fleet_doctor_dispatcher.rs` → `gap_filer::file_gap_with_dedup`) with
tag `health-check:gap-drift`, `created_at=1793246984`
(2026-10-29T04:09:44Z).

This is the same health-check tag already investigated twice:

- **INFRA-8711** (closed `done`, PR #5749): root-caused the permanent
  `gap-drift` FAIL to `chump gap audit-priorities`' `done_with_closed_pr`
  finding — the normal state for every shipped gap (3087+ instances),
  not a drift signal. Removed it from the fail-reasons gate.
- **INFRA-8712** (PR #5750, 2026-10-28T19:44:07-06:00 /
  2026-10-29T01:44:07Z): fixed the remaining bug in
  `scripts/coord/fleet-doctor-strict.sh`'s `check_gap_drift` — it was
  keying off `chump gap audit-priorities`' overall exit code (which is
  non-zero for several unrelated hygiene findings) instead of parsing
  the JSON and checking `open_with_closed_pr` directly.

INFRA-8769 was created ~2.5 hours *after* INFRA-8712 merged to `main`,
by a fleet-doctor run whose dedup lookup (`find_existing_gap_by_tag`)
only matches *open* gaps — once INFRA-8711 flipped to `done`, the next
FAIL re-filed a new ticket under the same tag even though the underlying
bug was already fixed by INFRA-8712 by the time this one was filed. Most
likely cause: a fleet-doctor invocation running against a `chump` binary
or `fleet-doctor-strict.sh` checkout that predated the INFRA-8712 merge.

Verified the check is healthy on current `main` with the current binary:

```
$ chump gap audit-priorities --json | python3 -c "import json,sys; print(json.load(sys.stdin)['open_with_closed_pr'])"
0

$ bash scripts/coord/fleet-doctor-strict.sh --verbose 2>&1 | grep gap-drift
✓ PASS  gap-drift      no gap drift detected
```

`open_with_closed_pr` is 0 (the invariant `check_gap_drift` now gates on,
per INFRA-8712), and the strict health check reports `PASS` for
`gap-drift`. There is no live registry-drift condition to investigate or
fix — the root cause was already remediated.

Closing as not-a-bug per the reality-check doctrine (`AGENTS.md` →
Reality-check before alarm-class beliefs, CREDIBLE-090) rather than
re-litigating an already-fixed root cause. No follow-up filed: the dedup
window (open-gaps-only) re-filing a ticket for a cause that was fixed
between the previous ticket's closure and the next failing run is an
inherent, low-cost property of idempotent-by-open-tag dedup, not a new
defect.
