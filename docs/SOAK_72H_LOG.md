# Overnight / 72h soak log (template)

**Purpose:** Capture evidence for [ROADMAP.md](ROADMAP.md) **Architecture vs proof → Overnight / 72h soak** without inventing numbers. Follow the **Day 13** rhythm in [DAILY_DRIVER_95_STEPS.md](DAILY_DRIVER_95_STEPS.md) (#81–87), extended across **≥72h** with your normal **roles** ([OPERATIONS.md](OPERATIONS.md)) and **primary surface** (PWA, Cowork, or Discord).

**Where to paste:** Append a dated section here **or** under [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) **Soak runs**, and add a one-line pointer in [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) §Soak.

---

## Pre-flight (T0)

| Check | Command / action | Value |
|-------|-------------------|-------|
| Time (UTC) | `date -u` | |
| `chump_memory.db` size | `ls -lh sessions/chump_memory.db` | |
| WAL present? | `ls sessions/chump_memory.db-wal 2>/dev/null || echo none` | |
| `logs/` size | `du -sh logs` | |
| Model server | `curl -sS -m 5 …/v1/models` (your base) | OK / fail |
| Stack snapshot | `curl -sS http://127.0.0.1:${CHUMP_WEB_PORT:-3000}/api/stack-status` | save JSON to `logs/soak-stack-T0.json` |

---

## During (T0 + 24h / 48h / 72h)

For each checkpoint:

- Any **model server restarts** (manual or Farmer Brown)?
- **Discord / web** process restarts?
- **SQLite** errors or `database is locked` in logs?
- **Disk:** `du -sh sessions logs` again.

---

## Post-flight (T1)

| Check | Notes |
|-------|-------|
| DB size delta | |
| WAL growth / checkpoint behavior | |
| `logs/` growth (largest files) | |
| Pass / fail vs “no manual inference repair” criterion | |

**Pass (suggested):** No unplanned full-machine reboot; inference recoverable within documented playbook; no unbounded DB or log growth beyond expectations in [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md).

---

## Related

- [STEADY_RUN.md](STEADY_RUN.md) §6 — soak pointer.  
- [scripts/chump-operational-sanity.sh](../scripts/chump-operational-sanity.sh) — quick strip between checkpoints.
