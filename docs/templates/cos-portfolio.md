# COS portfolio map

**Path in brain:** `cos/portfolio.md` (under `CHUMP_BRAIN_PATH`, usually `chump-brain/` — often gitignored locally).

Copy this file into the brain repo, then keep **one row per product/experiment**. Status drives reporting: **experiment** (hypothesis), **active** (committed), **sunset** (winding down).

| Product / repo | Status | Owner | Last reviewed | Metric / next gate | Notes |
|----------------|--------|-------|-----------------|--------------------|-------|
| Chump | active | Jeff | YYYY-MM-DD | Battle QA + wedge pilots | Core platform |
| _example thin repo_ | experiment | chump | | 3 real users or kill Q | Link to validation doc |

## Status definitions

- **experiment:** cheap build; clear kill date or metric; may live outside main Chump repo.
- **active:** in production or committed roadmap; has on-call or owner; metrics in pilot docs.
- **sunset:** no new features; migration or archive plan; date target for decommission.

## Chump actions

- On **promote** experiment → active: update row, episode log, optional notify.
- On **sunset:** move row to a “Graveyard” subsection or second table; link final archive path.
