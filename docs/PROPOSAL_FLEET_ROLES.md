# The Fleet: Three Agents, One Brain

A proposal for turning Chump + Mabel + a new iPhone agent into a personal operations team that does real work beyond building itself.

---

## The Problem Right Now

Your agent fleet is almost entirely self-referential. Chump builds Chump. Mabel monitors Chump. The heartbeat loops write episodes about writing episodes. The brain contains documentation about the brain. It's an impressive engineering achievement — but 95% of the compute cycles are spent on the agent infrastructure itself, and approximately 0% on things that improve your life, make you money, save you time, or give you information advantage.

You have three always-on compute nodes with internet access, persistent memory, tool use, coordination via shared brain, and a mesh network. That's not a coding project. That's a **personal operations team.**

---

## The Three Roles

### Chump (Mac) — The Forge

**What it is:** Your heavy-compute workhorse. 14B model, full dev toolchain, GPU, big disk.

**Current role:** Self-improvement coding agent.
**Expanded role:** Builder, analyst, creator. Anything that needs serious compute, long context, or complex reasoning.

**New capabilities to unlock:**

| Capability | What it does | How it works |
|---|---|---|
| **Project builder** | Build software beyond Chump itself | Same tools (edit_file, cargo, git, gh) pointed at other repos. `CHUMP_REPO` already supports this — just set it to a different project. Add a `project` tool or env that lets Chump switch context between repos. |
| **Research analyst** | Deep research on any topic, synthesized into actionable briefs | Tavily + read_url + delegate(summarize) chained in a research round. Output: markdown report in brain under `research/`. Triggered by you ("research X") or by Mabel's intel rounds flagging something. |
| **Document creator** | Write real documents — proposals, READMEs, blog posts, technical specs | Chump already writes docs for itself. Point it outward: "Write a technical spec for [project]" → markdown in brain or a file. The Chump Web PWA makes these instantly readable on your phone. |
| **Code review service** | Review PRs on any repo you maintain | `diff_review` already exists. Expand: Chump watches repos (via `gh` CLI + schedule), reviews new PRs, posts comments. A heartbeat round that checks your GitHub notifications. |
| **Data cruncher** | Analyze CSVs, logs, JSON datasets | `run_cli` with jq, xsv, nushell. Add a native `analyze_data` tool that loads a file, runs stats, produces a summary. Chump has cargo and can compile one-off analysis scripts. |
| **Automation forge** | Build iOS Shortcuts, shell scripts, automation recipes for the fleet | You describe what you want automated → Chump writes the script/shortcut/recipe → tests it → deploys via SSH or brain. |

**The key shift:** Chump stops being "the agent that builds agents" and becomes "the agent that builds whatever Jeff needs built." The infrastructure work continues as one heartbeat round type among many — not the only thing Chump does.

---

### Mabel (Pixel) — The Sentinel

**What it is:** Always-on, always-connected, always-watching. 3B/4B model on device, LTE, ADB, camera, sensors, Termux.

**Current role:** Fleet monitor + research assistant.
**Expanded role:** 24/7 operations, monitoring, and ambient intelligence.

**New capabilities to unlock:**

| Capability | What it does | How it works |
|---|---|---|
| **Fleet ops (existing, expanded)** | Monitor and heal the entire stack | Already in place. Expand: also monitor GitHub Actions, Tailscale connectivity, cert expiry, disk usage trends. |
| **Price/deal watcher** | Track prices on items you care about | New heartbeat round type: `deal_watch`. Mabel reads a list from brain (`watch/deals.md`) and checks prices via web_search + read_url. If a price drops below threshold → notify. Items: flights, gear, tech, whatever. |
| **News/topic monitor** | Morning briefing on topics you choose | Intel rounds already exist. Expand the intel topics list beyond Rust/agents to include: markets you follow, industries, competitors if you have a business, local Colorado Springs events, weather alerts. Daily digest → brain + notify. |
| **GitHub watcher** | Monitor repos, issues, releases | Mabel can SSH to Mac and run `gh` commands, or use read_url on GitHub. New round: check starred repos for new releases, check your repos for new issues/PRs/comments. Summarize → notify + task create for Chump if action needed. |
| **Uptime monitor** | Watch any URL or service | Beyond the fleet: watch your personal sites, side project deployments, APIs you depend on. Simple HTTP probe list in brain (`watch/uptime.md`). Alert on failure. |
| **Appointment/schedule reminder** | Parse your calendar and send smart reminders | If you use Google Calendar: Mabel reads it via read_url on the API (or a shared iCal URL). 30-min and 5-min reminders with context ("your meeting with X is in 30 min — here's what you discussed last time from brain"). |
| **Phone automation (ADB, future)** | Automate repetitive phone tasks | The ADB foundation exists. Closed-loop: screencap → OCR → decide → input. Recipes in brain. Use cases: auto-dismiss specific notifications, screenshot and archive something, check app state. |

**The key shift:** Mabel stops being just a Chump babysitter and becomes your ambient intelligence layer — always watching, always gathering, always ready with "hey, you should know about this."

---

### Scout (iPhone 16 Pro) — The Interface

**What it is:** Your daily driver. Always with you. Best camera. iOS ecosystem. Shortcuts. HealthKit. HomeKit. Focus modes.

**Current role:** Inference mesh node (inferrlm). Barely used.
**Expanded role:** Your primary touchpoint with the fleet, and a sensor/capture device.

This is NOT another Chump binary running on the iPhone. The iPhone's value is that it's with you, it runs iOS, and it has native capabilities no Termux setup can match. The agent on the iPhone is **you + iOS Shortcuts + the Chump Web PWA**.

**New capabilities to unlock:**

| Capability | What it does | How it works |
|---|---|---|
| **PWA chat (Tier 2 spec)** | Talk to Chump from anywhere | The Chump Web spec. Full streaming chat, tool visibility, task management, push notifications. This IS the primary interface replacing Discord. |
| **Quick capture → brain** | Photograph or dictate something, it goes into the shared brain | iOS Shortcut: "Hey Siri, capture for Chump" → takes photo or dictation → HTTP POST to Chump Web `/api/ingest` → Chump processes (OCR, transcribe, summarize) → stores in brain. Use cases: whiteboard photos, receipts, business cards, random ideas. |
| **Morning briefing** | Wake up to a summary on your lock screen | Push notification from Mabel's morning report. Tap → opens PWA with full briefing: overnight work, market moves, weather, calendar, tasks for you. |
| **Shortcut triggers** | "Hey Siri, deploy to production" | iOS Shortcuts that POST to Chump Web API. Pre-built shortcuts for common commands: deploy, run tests, status report, create task, check on Chump, check on Mabel. |
| **Location-aware triggers** | Agent behavior changes based on where you are | iOS Shortcuts automation: when you arrive at [place], trigger an HTTP call. Chump/Mabel adjust behavior: "Jeff is at work" → suppress non-urgent notifications. "Jeff is home" → run the heavy stuff. |
| **Health data bridge (future)** | Surface health trends | iOS Shortcuts can read HealthKit data. A weekly shortcut exports sleep/steps/heart rate → POST to Chump → Chump stores and tracks trends in brain. Not medical advice — just "you slept 2 hours less this week than last." |
| **HomeKit bridge (future)** | Voice-triggered home automation via Chump | "Hey Siri, ask Chump to set up movie mode" → Shortcut → Chump Web → Chump reasons about what "movie mode" means (lights, thermostat, etc.) → returns HomeKit scene commands → Shortcut executes. |

**The key shift:** The iPhone isn't running an agent. It IS the agent — Jeff + iOS + the fleet's API surface. Every interaction starts here.

---

## Cross-Cutting Capabilities (The Team Working Together)

These only work because the three nodes coordinate.

### 1. Personal Knowledge Base

**What:** Everything you learn, decide, read, or capture goes into the shared brain and becomes searchable, recallable, and actionable.

**Flow:**
- You photograph a whiteboard (iPhone → Chump OCR → brain)
- Mabel finds a relevant article during intel (web_search → brain)
- Chump writes a technical analysis (brain)
- You ask "what do we know about X?" via PWA → Chump searches brain + memory → synthesized answer

**Implementation:** Brain already exists. Missing pieces: an `/api/ingest` endpoint on Chump Web that accepts photos/text/URLs, processes them, and stores in brain. A `brain_search` tool that does RAG over the brain directory (FTS5 over markdown files, or just ripgrep + delegate(summarize)). This is the "Layer 2 wiki" from the Playbook doc, but made automatic.

### 2. Task Routing

**What:** Tasks get created by any agent and routed to the right executor.

**Flow:**
- You say "build me a landing page for [project]" via PWA
- Chump creates the task, picks it up in a work round, builds it
- Mabel notices Chump committed code, runs verify round, confirms tests pass
- Chump notifies you via push: "landing page done, PR #X open"
- You review on your phone, merge from the PWA

**Implementation:** Task queue exists. Missing: task `assignee` field (chump/mabel/jeff). Task routing logic: if it needs heavy compute → chump. If it needs monitoring → mabel. If it needs human judgment → jeff (notify + block). Mabel's report rounds surface "tasks waiting for Jeff."

### 3. Research Pipeline

**What:** Multi-stage research that goes from "I'm curious about X" to a briefing document.

**Flow:**
- You say "research the market for [thing]" via PWA
- Chump creates a research task, does initial web_search + read_url passes
- Chump delegates sub-questions to Mabel (via task create + message_peer): "find pricing data for competitors A, B, C"
- Mabel's research rounds pick these up, search, store findings in brain under `research/`
- Chump synthesizes all findings into a brief (markdown in brain)
- Push notification: "Research brief on [thing] is ready"
- You read it in the PWA, ask follow-up questions in chat

**Implementation:** The pieces exist (web_search, read_url, delegate, brain, message_peer). Missing: a `research` tool that orchestrates multi-pass research with a plan. Could be a specialized heartbeat round type on Chump, or a native tool that does: plan → search → read → synthesize → store.

### 4. Financial Awareness

**What:** Passive monitoring of financial things you care about.

**Flow:**
- You configure a watchlist in brain: `watch/finance.md` (stocks, crypto, whatever)
- Mabel checks prices during intel rounds (web_search)
- Significant moves (>5% day, new highs/lows, earnings releases) → notify
- Weekly: Chump generates a summary brief from Mabel's collected data
- You see it on your phone lock screen

**Implementation:** New Mabel round type `finance_watch`. Read watchlist from brain. web_search for current prices. Compare to stored previous values. Threshold alerts via notify. Brain stores historical data points in `watch/finance-log.md`.

### 5. Continuous Learning

**What:** The fleet learns about topics relevant to you and surfaces insights.

**Flow:**
- You're learning Rust (or anything). You tell Chump "I'm studying [topic]"
- Chump stores this in ego as a learning goal
- Mabel's research rounds periodically find new resources, tutorials, interesting patterns
- Chump's opportunity rounds create practice exercises or projects related to your learning goal
- Weekly: "Learning brief: 3 new resources on [topic], 2 practice ideas, your progress on related tasks"

**Implementation:** Ego already tracks goals. Add a `learning_goals` field to ego state. Mabel's intel round checks the learning goals list and searches for relevant content. Chump's opportunity round considers learning goals when scanning for tasks.

---

## The New Round Types

### Chump (Mac) heartbeat expansion

Add to the existing cycle:

| Round type | What | Frequency |
|---|---|---|
| **work** (existing) | Task queue, code, PRs | Every other round |
| **opportunity** (existing) | Scan codebase for improvements | 1 in 9 |
| **research** (existing) | Web search on a topic | 1 in 9 |
| **discovery** (existing) | Find and install CLI tools | 1 in 9 |
| **battle_qa** (existing) | Self-heal QA | 1 in 9 |
| **external_work** | Work on non-Chump projects (other repos) | 1 in 9 |
| **research_brief** | Synthesize research Mabel collected → brief in brain | 1 in 9 |
| **review** | Check GitHub notifications, review PRs, respond to comments | 1 in 9 |

### Mabel (Pixel) heartbeat expansion

Expand the existing cycle:

| Round type | What | Frequency |
|---|---|---|
| **patrol** (existing) | Fleet health check | Every other round |
| **research** (existing) | Topic research for Chump | 1 in 12 |
| **report** (existing) | Unified fleet report to Jeff | 1 in 12 |
| **intel** (existing) | Project-relevant intelligence | 1 in 12 |
| **verify** (existing) | QA Chump's last code change | 1 in 12 |
| **peer_sync** (existing) | Coordinate with Chump | 1 in 12 |
| **deal_watch** | Check price watchlist | 1 in 12 |
| **finance_watch** | Check financial watchlist | 1 in 12 |
| **github_watch** | Check repos, issues, releases, PRs | 1 in 12 |
| **news_brief** | Morning/evening news digest on configured topics | 1 in 12 |

---

## What Creates the Most Value (Ranked)

Ranked by "how much does this actually improve Jeff's life" × "how hard is it to build":

### Tier 1 — Ship these first (highest ROI)

1. **Chump Web PWA** (the Tier 2 spec) — This is the gateway to everything else. Without a good interface, no capability matters. 12 days, already specced.

2. **Research pipeline** — "Research X for me" and get a brief. This is the first thing that makes the fleet do real work for you, not just self-improvement. Chump already has web_search + read_url + delegate. Need: a research orchestration round + brain storage. 2-3 days.

3. **Quick capture (iPhone → brain)** — Photograph/dictate → brain. Makes the brain actually useful as a personal knowledge base instead of just agent documentation. Need: `/api/ingest` endpoint on Chump Web + iOS Shortcut. 1 day after Chump Web exists.

4. **External project work** — Point Chump at a different repo and have it do real work. The infrastructure already supports this. Need: a `project` command or env switch, updated heartbeat round that reads from a projects list. 1 day.

### Tier 2 — Ship next (high value, medium effort)

5. **GitHub watcher** — Mabel monitors your repos, surfaces new issues/PRs/comments, tracks releases on repos you care about. Immediate feedback loop on your open-source or work projects. 1 day (new Mabel round type + brain watchlist).

6. **Deal/price watcher** — "Watch this item and tell me when it drops below $X." Mabel checks periodically, notifies on match. Surprisingly high daily-life value. 1 day.

7. **Morning briefing** — Wake up to: overnight work summary, weather, calendar, news on your topics, task queue for you. Mabel generates, push notification on iPhone. 1 day (synthesis of existing report round + expanded topics).

8. **iOS Shortcut triggers** — "Hey Siri, deploy" / "Hey Siri, status report" / "Hey Siri, create a task." Makes the fleet voice-accessible. 0.5 day per shortcut (just HTTP POSTs to Chump Web).

### Tier 3 — Build when the foundation is solid

9. **Task routing with assignee** — Tasks auto-route to the right agent or to Jeff for human judgment. 1 day.

10. **Financial awareness** — Passive watchlist monitoring + weekly brief. 1-2 days.

11. **Calendar integration** — Smart reminders with context from brain. Requires Google Calendar API access or shared iCal URL. 2 days.

12. **Learning assistant** — Track your learning goals, surface resources, create practice tasks. 1 day (mostly prompt changes + ego state).

### Tier 4 — Long-term

13. **Phone automation recipes** — ADB closed-loop control on the Pixel. High cool factor, medium practical value until you identify specific repetitive tasks worth automating.

14. **HomeKit bridge** — Voice → Chump → home control. Fun but niche.

15. **Health data trends** — HealthKit export → Chump analysis. Interesting but the value is marginal compared to Apple Health's built-in trends.

---

## What Changes in the Architecture

### Brain structure expands

```
chump-brain/
  ego/                    # (existing)
  tools/                  # (existing)
  intel/                  # (existing)
  wiki/                   # (existing)
  research/               # NEW: research briefs
    2026-03-13-market-for-X.md
    2026-03-15-rust-async-patterns.md
  watch/                  # NEW: watchlists
    deals.md              # Items + threshold prices
    finance.md            # Stocks/crypto watchlist
    github.md             # Repos to monitor
    uptime.md             # URLs to probe
    news-topics.md        # Topics for morning brief
    learning-goals.md     # What Jeff is studying
  capture/                # NEW: quick captures from iPhone
    2026-03-13-whiteboard.md
    2026-03-14-receipt.md
  projects/               # NEW: external projects Chump works on
    project-a/
      brief.md            # What it is, repo URL, goals
      log.md              # What Chump has done
    project-b/
      brief.md
      log.md
  reports/                # NEW: generated briefs
    morning/
      2026-03-13.md
    weekly/
      2026-w11.md
```

### Task queue gets an assignee

```sql
ALTER TABLE chump_tasks ADD COLUMN assignee TEXT DEFAULT 'chump';
-- values: chump, mabel, jeff, any
```

Mabel can create tasks assigned to Chump. Chump can create tasks assigned to Jeff (surfaced in PWA sidebar). "Tasks for Jeff" becomes a prominent section in the morning briefing.

### Chump Web gets new endpoints

```
POST /api/ingest          # Quick capture: photo/text/URL → brain
GET  /api/briefing        # Today's morning briefing
GET  /api/research/:topic # Research brief for a topic
POST /api/research        # Trigger a new research pipeline
GET  /api/watch           # All watchlists and their status
POST /api/watch           # Add item to a watchlist
GET  /api/projects        # External projects Chump is working on
```

### Notify tool gets routing

```rust
// notify decides where to send based on priority and context:
// - Push notification (PWA) for everything
// - Discord DM as fallback
// - Silent push for FYI items
// - Alert push (with sound) for urgent items
```

---

## Implementation Priority

| # | What | Effort | Depends on | Unlocks |
|---|------|--------|-----------|---------|
| 1 | Chump Web PWA (full Tier 2 spec) | 12 days | Nothing | Everything below |
| 2 | Research pipeline (Chump round + brain storage) | 2 days | #1 (for triggering/viewing) | Briefs, competitive analysis, learning |
| 3 | Brain watchlists + Mabel watch rounds (deals, finance, github) | 2 days | Nothing (works via Discord notify today) | Passive monitoring |
| 4 | Morning briefing (Mabel synthesis round) | 1 day | #1 (for push), #3 (for watchlist data) | Daily value delivery |
| 5 | Quick capture (iPhone → Chump Web → brain) | 1 day | #1 | Personal knowledge base |
| 6 | External project work (Chump multi-repo) | 1 day | Nothing | Chump does real work for you |
| 7 | iOS Shortcuts (deploy, status, create task, capture) | 0.5 day each | #1 | Voice-driven fleet control |
| 8 | Task routing with assignee | 1 day | Nothing | Multi-agent coordination |
| 9 | Calendar integration | 2 days | #1 (for push) | Smart reminders |
| 10 | Learning assistant | 1 day | #2 (research pipeline) | Skill development |

**Total to "the fleet does real work for Jeff": ~23 days.** The Chump Web PWA is the critical path — everything else layers on top of it.

---

## What to Skip

- **Running a full agent on the iPhone.** iOS doesn't support background processes the way Termux does. The iPhone's value is as a sensor, capture device, and UI — not as a headless agent. Shortcuts + PWA is the right architecture.
- **Cloud VPS.** Adds complexity, cost, and latency. Your Mac + Pixel + iPhone on Tailscale is already more compute than most people have in their homelab. Add cloud only if you need 24/7 uptime when your Mac sleeps.
- **Multi-user.** This is a personal operations team. Auth is a single bearer token. Don't build user management.
- **Complex workflow engines.** No BPMN, no DAGs, no Airflow-at-home. The heartbeat loop + task queue + brain is your workflow engine. It's simple and it works.
- **Voice AI (Whisper, TTS).** Cool but the ROI is low when Siri + Shortcuts already handles voice input and the PWA handles text. Add this much later if at all.

---

## The Vision

Today: you have a coding bot that builds itself and a phone that watches the coding bot.

After this: you have a personal operations team. One builds things. One watches everything. One is always in your pocket. They share a brain, coordinate via tasks, and deliver value to your lock screen while you sleep.

The agents stop being the product and start being the platform.
