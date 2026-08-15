# LOOP STATE — tick 218 — 2026-08-15T05:20Z

## Ambient tail (relevant)
05:18 farmer_auth_dead (worker=fleet-worker-2, exit=78)
05:16 farmer_auth_dead (worker=fleet-worker-1, exit=78)
05:15 farmer_heartbeat
05:12 ship_landed (pr=3794, gap=CREDIBLE-249)
05:03 ship_landed (pr=3793, gap=INFRA-2161)
04:55 pr_auto_rebased (pr=3795)

## Ships (git log origin/main --since=1h)
b81f2c33 CREDIBLE-249: judge-verdict provenance in PR body (#3794)  [17 min ago]
a4092e11 INFRA-2161: cache reconcile on webhook gap (#3793)        [28 min ago]
9f77d0e2 RESILIENT-327: farmer revive backoff jitter (#3796)       [51 min ago]

## Auth probe (scripts/coord/auth-status.sh, ran at 05:19)
AUTH OK — oauth token valid, refreshed 3m ago, keychain mirror fresh

## Fleet brief (24h)
Ships: 26 | last 1h: 3 | Stalls: 0

## Historical context available to you
docs/process/PLAYBOOK_REGISTRY.yaml lists farmer_auth_dead:
  false_positive_class: "known #1 false-positive (CREDIBLE-090); mis-called 4x"
  action: SUPPRESS — ship-check first (git log --since=1h); never escalate on this alone

## Inbox
(no unread broadcasts)
