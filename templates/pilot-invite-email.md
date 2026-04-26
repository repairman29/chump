# Pilot invite email (template)

Copy into your mail client; replace `{{…}}`. Full handoff: [docs/PILOT_HANDOFF_CHECKLIST.md](../docs/PILOT_HANDOFF_CHECKLIST.md).

---

**Subject:** Chump pilot — {{one_line_goal}}

Hi {{name}},

Thanks for trying Chump as a **local-first** assistant (web PWA and/or desktop shell). Here is a tight start path:

1. **Repo or bundle:** {{clone_url_or_dmg_link}}  
2. **Docs to open first:** [EXTERNAL_GOLDEN_PATH.md](https://github.com/{{org}}/{{repo}}/blob/main/docs/process/EXTERNAL_GOLDEN_PATH.md) (same order as README quick start).  
3. **Health check:** after `./run-web.sh` (or your packaged app), `curl` **/api/health** and send one short chat in the browser.  
4. **If anything fails:** `./scripts/chump-preflight.sh` from the repo root, then [OPERATIONS.md](https://github.com/{{org}}/{{repo}}/blob/main/docs/operations/OPERATIONS.md).  
5. **Rough edges:** inference dominates latency; optional `CHUMP_LIGHT_CONTEXT=1` for snappier interactive chat — [PERFORMANCE.md §8](https://github.com/{{org}}/{{repo}}/blob/main/docs/operations/PERFORMANCE.md).

**What we need back (pick any):**  
- Time to first successful chat (minutes)  
- Top friction (one bullet)  
- Optional: one anonymized screenshot of a confusing error

No need to share secrets, internal URLs with credentials, or private repo data.

Thanks,  
{{your_name}}
