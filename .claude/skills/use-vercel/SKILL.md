---
name: use-vercel
description: Deploy doctrine for Vercel. Use whenever an agent is about to deploy, preview, promote, roll back, or configure a web app on Vercel, set Vercel env vars, or debug a Vercel build. Encodes the deploy path to follow and the footguns to avoid.
---

# use-vercel — deploy doctrine

Distributed to every agent surface (INFRA-8172, slice 2 of INFRA-8170). Canonical copy: `.claude/skills/use-vercel/SKILL.md` in the chump repo; synced to `~/Projects/.claude/skills/` and the fleet node skills path by `scripts/setup/sync-use-vercel-skill.sh`.

## Rules
1. **Preview first, production second.** Deploy with `vercel deploy` (preview), verify the preview URL, then promote with `vercel promote <url>` or merge to the production branch. Never run `vercel --prod` straight from an unreviewed working tree.
2. **Prefer git-driven deploys.** Push a branch / open a PR and let the Vercel Git integration build it. Use the CLI only when no Git integration exists.
3. **Secrets live in Vercel env, not in the repo.** Manage with `vercel env add|ls|pull`. Never commit `.env*` or `.vercel/` contents; never echo token values into logs.
4. **Pull env before building locally:** `vercel env pull .env.local`, and confirm the right environment (`development|preview|production`).
5. **Roll back, don't hot-patch.** If production is bad, `vercel rollback` (or promote the previous deployment) first, then fix forward through a PR.
6. **Link before deploying.** Confirm `vercel link` points at the intended project/scope (`vercel whoami`, `.vercel/project.json`) — a wrong link deploys to the wrong project.
7. **Non-interactive in agents.** Use `--yes` and `--token "$VERCEL_TOKEN"`; never leave a deploy waiting on a prompt.
8. **Verify after deploy:** fetch the deployment URL and check for HTTP 200 and expected content before reporting success. Build logs: `vercel logs <url>` / `vercel inspect <url>`.
