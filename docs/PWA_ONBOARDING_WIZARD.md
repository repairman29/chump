# PWA onboarding wizard (universal power **P5.1**)

**Goal:** One coherent **first-run story** across **browser PWA** and **Tauri / Cowork desktop**, without forcing a heavy framework ([ADR-003](ADR-003-pwa-dashboard-fe-gate.md)).

---

## Surfaces

| Surface | Implementation | Doc |
|---------|----------------|-----|
| **Browser PWA** | Dismissible **setup banner** + **Settings → Quick setup** checklist; `localStorage` progress keys; optional **step dots** on the banner | This file, `web/index.html` |
| **Cowork / Tauri** | **`web/ootb-wizard.js`** — multi-step modal (LLM, paths, model pull, engine) | [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md) |

---

## Browser `localStorage` keys

| Key | Values | Meaning |
|-----|--------|---------|
| `chump_onboarding_step` | `1`–`5` | Rough progress: **1** start → **2** opened Settings / host healthy → **3** saved token → **4** used `/task` → **5** checklist cleared |
| `chump_pwa_onboarding_dismissed` | `1` | User hid the **banner** only; Quick setup remains in Settings |
| `chump_pwa_onboarding_done` | `1` | User cleared the full checklist |

Log **timed naive runs** in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) when you have a third-party pilot.

---

## Operator checklist (browser)

1. Host: `./scripts/chump-preflight.sh` green (or documented rescue path).  
2. PWA: open Settings → bearer token if `CHUMP_WEB_TOKEN` is enabled.  
3. Skim **tool policy** on stack status / Settings.  
4. Durable work: `/task …` or **Tasks** sidecar.

---

## Related

- [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) **P5.1**  
- [PILOT_HANDOFF_CHECKLIST.md](PILOT_HANDOFF_CHECKLIST.md)  
- [templates/pilot-invite-email.md](../templates/pilot-invite-email.md)
