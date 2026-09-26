# Self-hosted Supabase on cuphead (RESILIENT-314)

Self-hosted Supabase OSS on **cuphead** (Oracle Always-Free A1, us-phoenix-1) — the
data + auth layer for the tiny apps being migrated off Firebase (smuggler, postsub,
trove-web, pov-video). Part of the GCP exit (`workspace-docs/GCP_EXIT.md`).

## Security model (this is a PUBLIC repo)

- **No secrets are committed.** `docker-compose.yml` reads every credential via `${VAR}`.
- Secrets live only in `/srv/supabase-data/.env` (chmod 600, **gitignored**, off the repo).
- `.env.example` documents the variables; `scripts/gen-secrets.sh` generates a real `.env`
  (random `POSTGRES_PASSWORD`/`JWT_SECRET`, then mints the anon/service_role API keys as
  HS256 JWTs signed with `JWT_SECRET`). Only `GOOGLE_CLIENT_ID/SECRET` are pasted by hand
  ("Sign in with Google" stays with Google).

## Deploy on a fresh cuphead

```bash
# prereqs (done once, see GCP_EXIT.md): 50GB volume at /srv/supabase-data, 4GB swap +
# systemd-oomd + supabase.slice (MemoryMax=4G), ports 80/443 open (VCN + host iptables),
# api.* DNS -> cuphead. docker + docker compose installed.
bash scripts/gen-secrets.sh                 # writes /srv/supabase-data/.env (chmod 600)
# edit /srv/supabase-data/.env -> paste GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET
bash scripts/start-supabase.sh              # brings the stack up under supabase.slice
sudo cp Caddyfile ~/caddy-config/Caddyfile && sudo systemctl restart caddy-reverse-proxy
```

## What runs

| Service | Host port (bind) | Notes |
|---|---|---|
| Postgres | 127.0.0.1:54322 | local only, never public |
| PostgREST (REST) | 127.0.0.1:54321 | |
| GoTrue (auth) | 127.0.0.1:9999 | Google provider kept |
| Storage | 127.0.0.1:5000 | |
| Studio | **tailnet** :8000 | tailnet-only, never public |
| postgres-meta / imgproxy | internal | |

Public access is via **Caddy** (auto-TLS) on the four `api.*` hosts, routing
`/rest/v1` -> PostgREST, `/auth/v1` -> GoTrue, `/storage/v1` -> Storage.

## Memory guards

4 GB swapfile + `systemd-oomd` + `supabase.slice` (`MemoryMax=4G`) keep the stack from
starving the fleet worker on this shared box.

## Status / follow-ups (be honest)

- ✅ Stack comes up healthy; Postgres accepts connections; PostgREST responds.
- ⏳ **Caddy live + per-app API-gateway routing** is committed as config but not yet
  load-verified end-to-end (no migrated app consumes it yet).
- ⏳ App migrations (PRODUCT-304..309) + a live anon-key RLS parity test come with each app.
- Backups: `supabase-backup.{service,timer}` (nightly to OCI Object Storage `cuphead-backups` + CJ).