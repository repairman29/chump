# PRODUCT-310: billing-reopen reverification — 2026-10-02

PRODUCT-310 is parked pending Jeff reopening the Firebase/GCP billing account
`017801-838BC8-3504BF` (ASK-021 / ASK-061). The 2026-09-27 ledger entry in
`/tmp/wsdocs/GCP_EXIT.md` recorded the decision as "deferred to 2026-10-02" —
today's date — so this session re-checked ground truth before touching
anything, per the gap's own doctrine (do not pick until Jeff un-parks it).

## What was checked (read-only, no mutation)

```
gcloud billing accounts describe 017801-838BC8-3504BF
  → open: false

gcloud billing projects describe trove-web / echeo-vid / fulcrum-41e50
  → billingEnabled: false (all three)
```

No export commands were run — `gcloud firestore export` / `gcloud storage cp`
would still 403 BILLING_DISABLED exactly as the 2026-09-26/27 sessions found,
so re-attempting them would only burn API calls against an account already
confirmed closed.

## Status

- **AC #1, #2, #4** (Firestore export, Storage copy, read-back verification) —
  still blocked. No change since 2026-09-27: `$473.97` overdue, card declined,
  billing account not in good standing.
- **AC #3** (password hash params) — already resolved by Jeff's 2026-09-27
  decision to skip (dev users reset passwords); nothing further to collect.
- **No project deleted, no data mutated.**

## Disposition

Gap stays `open` / parked at P3. Re-pick only after Jeff reopens billing
(ASK-021/ASK-061) or makes an explicit skip decision for the remaining
Storage/Firestore export. Full ledger: `/tmp/wsdocs/GCP_EXIT.md`.
