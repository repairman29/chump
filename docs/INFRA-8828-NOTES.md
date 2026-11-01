# INFRA-8828 — closed not-a-bug: gap-drift health check already fixed by INFRA-8711/INFRA-8712

INFRA-8828 was auto-filed by fleet-doctor's `gap_file` dispatcher with tag
`health-check:gap-drift`, the same recurring tag already investigated and
root-caused by:

- **INFRA-8711** (done, PR #5749): root-caused the permanent `gap-drift`
  FAIL to `chump gap audit-priorities`' `done_with_closed_pr` finding — the
  normal state for every shipped gap — and removed it from the fail-reasons
  gate.
- **INFRA-8712** (PR #5750): fixed `scripts/coord/fleet-doctor-strict.sh`'s
  `check_gap_drift` to key off `open_with_closed_pr` from the JSON directly
  instead of the overall `chump gap audit-priorities` exit code.

And already re-filed multiple times more under the same tag after the fix
landed: INFRA-8769, INFRA-8771, RESILIENT-1773, RESILIENT-1777, RESILIENT-1764,
RESILIENT-1761, RESILIENT-1809, RESILIENT-1829 — all closed not-a-bug for the
same reason (see `docs/INFRA-8771-NOTES.md`).

Verified healthy on current `main` with the current binary:

```
$ chump gap audit-priorities --json | python3 -c "import json,sys; print(json.load(sys.stdin)['open_with_closed_pr'])"
0

$ bash scripts/coord/fleet-doctor-strict.sh --verbose 2>&1 | grep gap-drift
✓ PASS  gap-drift      no gap drift detected
```

`open_with_closed_pr` is 0 and the strict health check reports `PASS` for
`gap-drift`. No live registry-drift condition exists to investigate.

Closing as not-a-bug per the reality-check doctrine (`AGENTS.md` →
Reality-check before alarm-class beliefs, CREDIBLE-090). No follow-up
filed — this is the same inherent, low-cost dedup-window property
(open-gaps-only matching re-files a ticket for a cause fixed between the
previous ticket's closure and the next failing fleet-doctor run) already
documented as acceptable in INFRA-8769's closure notes.
