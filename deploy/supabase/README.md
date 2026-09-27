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

## Separate user bases (one stack per app)

Decision (Jeff, 2026-09-26): each app keeps its **own** user base and its own "Sign in with Google"
client. So there is one Postgres *cluster* but **one database per app** (own `auth.users`, own
`storage` schema), and each app has its own GoTrue + PostgREST + Storage containers and its **own
JWT secret and keys**. A token or user from one app is rejected by every other app
(`smoke-test.sh` checks this). Apps are listed in `apps.conf`; `scripts/render.py` generates
`docker-compose.yml` and `Caddyfile` from it (edit `apps.conf`, never the generated files).
Each app can later move to hosted Supabase alone by swapping URL + keys.

| App (database) | Public API host | Loopback ports rest / auth / storage |
|---|---|---|
| smuggler | api.playsmuggler.com | 54331 / 9991 / 5001 |
| postsub | api.postsub.io | 54332 / 9992 / 5002 |
| trove_web | api.mytrove.app | 54333 / 9993 / 5003 |
| pov_video | api.sendpov.xyz | 54334 / 9994 / 5004 |

## Deploy on a fresh cuphead

```bash
# prereqs (see workspace-docs GCP_EXIT.md): 50GB volume at /srv/supabase-data, 4GB swapfile,
# ports 80/443 open (VCN + host iptables), api.* DNS -> cuphead, docker + compose plugin,
# earlyoom, and Caddy from the official apt repo (arm64! an amd64 /usr/bin/caddy was the
# reason HTTPS silently never came up the first time).
sudo rsync -a deploy/supabase/ /opt/supabase/        # stable path, NOT a worktree (reapers)
bash /opt/supabase/scripts/gen-secrets.sh            # /srv/supabase-data/.env (chmod 600): postgres pw
bash /opt/supabase/scripts/gen-app-secrets.sh        # + per-app JWT secret / anon / service keys
sudo mkdir -p /srv/supabase-data/storage/{smuggler,postsub,trove_web,pov_video} && sudo chown -R 1000:1000 /srv/supabase-data/storage
sudo cp /opt/supabase/systemd/* /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl enable --now supabase-stack caddy-supabase supabase-backup.timer
for h in api.playsmuggler.com api.postsub.io api.mytrove.app api.sendpov.xyz; do /opt/supabase/scripts/smoke-test.sh $h; done
sudo systemctl start supabase-backup && /opt/supabase/scripts/restore-test.sh
```

Google sign-in per app: put that app's own OAuth client in `GOOGLE_CLIENT_ID_<APP>` /
`GOOGLE_CLIENT_SECRET_<APP>`, set `GOOGLE_ENABLED_<APP>=true`, redirect URI
`https://<api host>/auth/v1/callback`, then `systemctl restart supabase-stack`.

## What runs

| Unit / service | Where | Notes |
|---|---|---|
| `supabase.slice` | MemoryHigh 3.5G, **MemoryMax 4G**, swap max 1G | containers join via `cgroup_parent` (systemd-run around compose does NOT move containers). ~1.3 GB with 4 apps |
| `supabase-stack.service` | `docker compose up -d` from `/opt/supabase` | secrets from `/srv/supabase-data/.env` |
| Postgres | 127.0.0.1:54322, data `/srv/supabase-data/postgres`, `oom_score_adj -800` | never public; `postgres` DB is the pristine template the app DBs are cloned from at init |
| GoTrue ×4 | DB URL needs `search_path=auth`, or it migrates into `public` and breaks `auth` | |
| PostgREST ×4 | logs in as `authenticator` | |
| Storage ×4 | logs in as `supabase_storage_admin`, files `/srv/supabase-data/storage/<app>` | |
| Studio + pg-meta | **tailnet IP**:8000 | never public |
| `caddy-supabase.service` | :80/:443, Let's Encrypt | each host routes to its app's services; REST/Storage refuse requests with no apikey (Kong parity) |
| `supabase-backup.timer` | 09:30 UTC nightly | `scripts/backup.sh`: pg_dump of every DB as `supabase_admin` + storage tar + canary; OCI via write-only PAR, CJ via scp (targets in `/srv/supabase-data/backup.env`) |
| `earlyoom` | host | prefers killing cargo/rustc/node, avoids postgres/dockerd/sshd |
