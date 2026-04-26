---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Product Roadmap: Chief of Staff

Vision, user stories, and phased waves for Chump as a personal Chief of Staff. See [ROADMAP.md](ROADMAP.md) for the operational near-term backlog.

## Vision

Chump as a tireless, proactive Chief of Staff that:
- **Instruments** your work (captures tasks, decisions, context automatically)
- **Closes the loop** (follows up, synthesizes, surfaces what matters)
- **Runs the discovery factory** (monitors competitive landscape, research, opportunities)
- **Bootstraps adjacent products** (applies learnings to new projects)

## User stories (60 total — 15 per wave)

### Wave 1 — Instrument

1. "When I mention a task in conversation, Chump creates it in my task queue without me asking"
2. "I can see what Chump did while I was away in a 30-second brief"
3. "Chump captures my decisions and the rationale automatically"
4. "My COS weekly snapshot shows tasks completed, decisions made, and key context from the week"
5. "Chump flags when a task I care about has been sitting idle for 3+ days"
6. "I can ask 'what did we decide about X?' and get a summary with context"
7. "Chump tracks what I said I'd do and reminds me before it's due"
8. "When I push a PR, Chump notes it in my weekly summary"
9. "I can see which projects I've been working on most this week"
10. "Chump knows my working hours and doesn't alert me outside them unless urgent"
11. "My episodes are searchable — I can find 'when did we debug the auth issue?'"
12. "Chump can tell me what gaps I worked on this week without reading git log"
13. "The COS weekly snapshot is in Discord every Monday morning, no action required"
14. "I can ask Chump 'what's the context on gap X?' and get a complete answer"
15. "Chump captures incoming interrupts and tells me which are worth acting on"

### Wave 2 — Close the loop

16. "Chump follows up on tasks I delegated and reports back"
17. "When CI fails on my PR, Chump tells me what failed and suggests the fix"
18. "Chump synthesizes the week's work into a 3-bullet executive summary"
19. "When I make a key product decision, Chump logs it with rationale to the decision log"
20. "The weekly COS heartbeat runs autonomously every Monday and posts the snapshot"
21. "High-priority interrupts notify me immediately; routine ones wait for the brief"
22. "Chump flags when two decisions I made seem to contradict each other"
23. "I can say 'Chump, go figure out why the tests are failing' and it investigates autonomously"
24. "Chump tracks the outcome of decisions I made last month and shows me what worked"
25. "The decision log is searchable by topic: 'what decisions did we make about inference?'"
26. "Chump suggests when a gap has been open too long relative to its priority"
27. "After each autonomy session, Chump writes a synthesis of what it did and why"
28. "I can export a quarterly memo of all key decisions, shipped work, and open questions"
29. "Chump tracks my sprint goals and shows me weekly progress toward them"
30. "When Mabel reports something unusual, Chump escalates it appropriately"

### Wave 3 — Discovery factory

31. "Chump monitors the competitive landscape and tells me what changed this week"
32. "I get a morning brief with 3 things worth knowing from research + news"
33. "Chump watches my GitHub watchlist and tells me when relevant issues open"
34. "When a paper is published that's relevant to my work, Chump summarizes it"
35. "Chump tracks my deal flow watchlist and flags opportunities"
36. "I can say 'keep an eye on AutoGen' and Chump adds it to the watch list"
37. "Chump generates a competitive comparison table when I ask"
38. "The market evaluation stays fresh — Chump updates it monthly from research"
39. "When I read a doc and say 'this is important,' Chump adds it to research/"
40. "I can ask 'what have we learned about prompt engineering this month?'"
41. "Chump mines my own sessions for reusable patterns and proposes them as skills"
42. "The research pipeline runs autonomously and deposits summaries in brain/research/"
43. "Chump flags when a gap I filed is addressed by something in the research stream"
44. "I can say 'what are people doing differently than us in memory retrieval?'"
45. "The morning brief includes one 'wild card' finding from outside my usual domains"

### Wave 4 — Adjacent products

46. "I can point Chump at a new repo and it onboards, understands the context, and starts working"
47. "Chump runs a sprint for a side project autonomously given a goal and constraints"
48. "The COS portfolio tracker shows all projects and their health at a glance"
49. "I can scaffold a new side repo with one command and have Chump set it up"
50. "Best practices from successful Chump sessions are extracted and applied to new projects"
51. "I can share a skill I created with others and Chump installs it from the registry"
52. "The quarterly COS memo covers all projects, not just the main one"
53. "Chump helps me prioritize across projects when I'm context-switching"
54. "I can delegate an entire project workstream to Chump for a week"
55. "Chump tracks cross-project dependencies and warns when one blocks another"
56. "I can ask 'what did we learn in Project X that applies to Project Y?'"
57. "Skills built for one project are discoverable and reusable in others"
58. "The COS decision log spans all projects with tagging for easy filtering"
59. "Chump can generate a project status update for any of my repos on demand"
60. "The full COS portfolio is queryable: 'what's my biggest bottleneck across all projects?'"

---

## Wave status

| Wave | Status | Key scripts |
|------|--------|-------------|
| Wave 1 — Instrument | ✓ Done | `generate-cos-weekly-snapshot.sh`, COS context injection |
| Wave 2 — Close the loop | ✓ Done | `heartbeat-self-improve.sh`, `CHUMP_INTERRUPT_NOTIFY_POLICY`, decision log |
| Wave 3 — Discovery factory | ✓ Scripts landed | `github-triage-snapshot.sh`, `ci-failure-digest.sh`, `repo-health-sweep.sh`, `golden-path-timing.sh` |
| Wave 4 — Adjacent products | ✓ Scaffold landed | `scaffold-side-repo.sh`, `quarterly-cos-memo.sh`, `templates/cos-portfolio.md` |

---

## See Also

- [COS_DECISION_LOG.md](COS_DECISION_LOG.md) — decision log format and brain integration
- [ROADMAP.md](ROADMAP.md) — near-term operational backlog
- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — market positioning
- [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) — COS scripts section
