# Teaching Chump what we’re building

How does Chump learn the roadmaps and the plan? **Most of it happens as we execute** (he sees the docs we change and stores from heartbeat or read_file). We can also **explicitly teach** him by keeping a single “project brief” updated and having him read or store it. This doc explains both and gives concrete flows.

**See also:** [CHUMP_PROJECT_BRIEF](CHUMP_PROJECT_BRIEF.md) is the one-pager we keep updated; Chump learns from it and from the key roadmap docs.

---

## Will it happen as we execute the roadmap?

**Yes, partly.** As we execute:

- **We change the docs** — ROADMAP, BULLETPROOF_CHASSIS, FULLY_ARMORED_VEHICLE, DOGFOOD, PARALLEL_AGENTS. Those files are on disk. Once Chump has **read_file** (dogfood Phase 1), he can read them when we ask (“what’s in the roadmap?”) or when a self-improve round runs (“read ROADMAP and FULLY_ARMORED_VEHICLE, summarize what’s next, store in memory”).
- **Heartbeat and memory** — The dogfood doc already has “Chump knowledge” and “self-model”: Chump stores facts about himself (e.g. “my memory is in sessions/chump_memory.db”) with source like `chump_self`. If we add a **self-model round** to heartbeat (e.g. “read CHUMP_PROJECT_BRIEF and ROADMAP; store a short summary of current focus in memory”), then over time his recall will surface “what we’re building” when the user asks about priorities or next steps.
- **Conversation** — When we talk to Chump in Discord or CLI and say “we’re doing bulletproof chassis then FAV-1 resilience,” he can store that in memory (memory tool). So **teaching can be conversational** as we execute.

So **a lot of learning is implicit**: we execute, we update docs, we tell him in chat or he reads the brief in heartbeat. To make it **reliable and up to date**, we do three things: (1) maintain a single **project brief**, (2) periodically **sync** that into his memory or context, (3) once read_file exists, **point him at the right docs** when we want him to act on the plan.

---

## What we maintain: the project brief

**[CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md)** is the one-pager that says:

- What Chump is (one Chump many chimps, local-first, dogfood goal).
- **Current focus** (e.g. “bulletproof chassis Phase A–B, then FAV-1 resilience, then parallel workers”).
- Pointers to the key docs (ROADMAP, BULLETPROOF_CHASSIS, FULLY_ARMORED_VEHICLE, DOGFOOD, PARALLEL_AGENTS).

**We update the brief** when we change priorities or finish a phase. That way Chump (and humans) have one place to look. He doesn’t need to re-read five long docs every time; he can read the brief and, if needed, one or two full docs.

---

## How we teach him (concrete flows)

### Today (no read_file yet)

- **Manual:** Paste the “Current focus” section of CHUMP_PROJECT_BRIEF (or a short summary) into Discord and say “store this as what we’re building right now.” He uses the memory tool; later when someone asks “what’s the plan?” recall will surface it.
- **Heartbeat:** Add a line to the heartbeat prompt (or a separate occasional “self-model” prompt): “Your current project focus is: [paste 2–3 sentences from CHUMP_PROJECT_BRIEF]. Store that in memory under chump_self so you can recall what we’re building.” Run heartbeat as usual; he’ll store it. Update the paste when we change the brief.

### Once we have read_file (dogfood Phase 1)

- **On demand:** User says “read docs/CHUMP_PROJECT_BRIEF.md and tell me what we’re focused on.” Chump reads the file and answers (and can optionally store a one-sentence summary in memory).
- **Sync round:** User says “sync on the plan: read CHUMP_PROJECT_BRIEF and ROADMAP, then store a short summary of current phase and next three priorities in memory.” Chump does read_file twice, summarizes, stores. We can run this when we’ve updated the brief.
- **Heartbeat self-model:** In heartbeat-learn (or a dedicated script), add a step: “Read docs/CHUMP_PROJECT_BRIEF.md. In one sentence, what is the current focus? Store that in memory.” So every heartbeat run (or every N rounds) refreshes his “what we’re building” fact.

### Once we have write_file and self-improve (dogfood Phase 2+)

- **Self-improve round:** The self-improve flow (read BULLETPROOF_CHASSIS or FULLY_ARMORED_VEHICLE → pick one task → implement) already implies he’s reading the roadmap. We can make it explicit: “Start each self-improve round by reading CHUMP_PROJECT_BRIEF; then read [BULLETPROOF_CHASSIS or FULLY_ARMORED_VEHICLE]; pick one item from the current phase and do it.”

---

## Summary

| Question                                            | Answer                                                                                                                                                                                                       |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Will Chump learn what we’re building as we execute? | **Yes.** He’ll see updated docs when he reads them (read_file or we paste); heartbeat and conversation can store “current focus” in memory; self-improve will use the roadmaps.                              |
| Do we need to explicitly teach him?                 | **Helpful.** Keep [CHUMP_PROJECT_BRIEF](CHUMP_PROJECT_BRIEF.md) updated and periodically have him read it (or store a summary) so his “what we’re building” stays current without re-reading every long doc. |
| When do we update the brief?                        | When we change priorities or complete a phase. Then run a “sync” (paste into chat, or heartbeat self-model round, or “read PROJECT_BRIEF and store summary”) so Chump’s memory matches.                      |

**Bottom line:** Execute the roadmap and **keep CHUMP_PROJECT_BRIEF updated**; teach him by **having him read the brief** (or storing a short summary) in conversation or heartbeat. Once read_file exists, a standard “sync” is: Chump reads PROJECT_BRIEF and optionally ROADMAP/FULLY_ARMORED_VEHICLE and stores “current focus: …” in memory. That way he knows what we’re building and it happens as we execute, with one place (the brief) that we maintain.
