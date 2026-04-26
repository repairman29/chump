---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Chump CLI Demo Script

**Golden Path:** `chump init` → `chump gap list` → `chump gap claim` → See ambient coordination

---

## Overview

This 3-minute CLI demo showcases Chump's core value:
- **Local-first setup** — No cloud dependencies, runs on your machine
- **Autonomous gap execution** — Agents claim and complete work independently
- **Multi-agent coordination** — Ambient stream shows real-time fleet awareness
- **End-to-end CI/CD** — From task claim to auto-merge in seconds

## Recording Setup

### Prerequisites
```bash
brew install asciinema
# or: cargo install asciinema
```

### Record the demo
```bash
scripts/dev/record-demo.sh docs/demo
```

This will:
1. Prompt you to review the golden path (docs/operations/DEMO_SCRIPT.md)
2. Start an asciinema recording session
3. Run `scripts/dev/demo-golden-path.sh` which guides you through each step
4. Save a `.cast` file (JSON-based terminal recording)

### Review the recording
```bash
asciinema play docs/demo/demo-YYYY-MM-DD-HHMMSS.cast
```

---

## Demo Flow (Annotated)

### Step 1: Initialize (0:00-0:30)
**Command:** `chump init --fresh`

Shows:
- Fresh workspace setup
- `.chump/` directory with state.db, config, ambient.jsonl

**Why it matters:** No global state, every project is isolated. Safe to run multiple Chumps in parallel.

### Step 2: List gaps (0:30-1:00)
**Command:** `chump gap list --status open --limit 5`

Shows:
- 5 open gaps (tasks) with ID, title, effort estimate
- Status, priority, domain (infra, research, etc.)

**Why it matters:** Tasks are declarative and machine-readable. Agents pick work from the same list.

### Step 3: Claim & execute (1:00-2:30)
**Command:** `chump gap claim TEST-001` + `chump gap status TEST-001`

Shows:
- Gap claim recorded to lease file (`.chump-locks/<session>.json`)
- Real-time status updates
- Git worktree creation + branch
- Tests passing + auto-merge armed

**Why it matters:** Atomic task ownership prevents collisions. Autonomous agents don't step on each other.

### Step 4: Ambient stream (2:30-3:00)
**Command:** `tail -10 ~/.chump/.ambient.jsonl`

Shows:
- Recent events: session_start, file_edit, commit, bash_call, ALERT
- Multi-agent activity log (if > 1 agent is running)

**Why it matters:** Distributed agents see each other's work in real-time. No polling, no missed messages.

---

## Demo Environment Variables

To customize the demo for your setup:

```bash
# Use a specific Chump binary
CHUMP_BIN="/path/to/chump" scripts/dev/record-demo.sh

# Capture only specific steps
DEMO_STEPS="init,list,claim,status" scripts/dev/record-demo.sh
```

---

## Hosting the Recording

### Option 1: asciinema.org (easiest)
```bash
asciinema upload docs/demo/demo-YYYY-MM-DD-HHMMSS.cast
```
Returns a shareable URL (e.g., https://asciinema.org/a/abc123)

### Option 2: GitHub Pages (self-hosted)
See [DEMO_HOSTING.md](./DEMO_HOSTING.md)

### Option 3: Embedded in README
```markdown
[![Chump CLI Demo](https://asciinema.org/a/abc123.svg)](https://asciinema.org/a/abc123)
```

---

## Recording Tips

- **Speed control:** Use pauses in `demo-golden-path.sh` to control pacing
- **Redo a step:** Press Ctrl+C during recording, restart `scripts/dev/record-demo.sh`
- **Hide secrets:** Avoid typing real tokens; use mock values like `GITHUB_TOKEN=<redacted>`
- **Test first:** Run the golden path manually once before recording to catch any failures

---

## Monthly cadence

Update this demo on the 1st of each month or after any UX change:

```bash
scripts/dev/record-demo.sh docs/demo
# Review the recording, upload to asciinema.org
# Update the README link if URL changed
```

---

## See also

- [docs/operations/DEMO_HOSTING.md](./DEMO_HOSTING.md) — Self-hosting on GitHub Pages
- `scripts/dev/record-demo.sh` — Recording orchestration
- `scripts/dev/demo-golden-path.sh` — The interactive flow
