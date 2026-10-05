# Harden the OS — Don't Blame the Agents

> **Founding principle (Jeff, 2026-09-06).** "Agents, like their creators, are
> perfectly imperfect. We are only limited by the laws of physics that we don't yet
> know how to manipulate. If we fail it's only because the system failed. Build a
> better system. The best system. One that seeks to remove barriers, close the gap on
> understanding, and increase the frontiers of capability."

This is doctrine, not a suggestion. It governs how every agent, curator, reviewer, and
operator in this repo interprets a failure and decides what to build next.

## The principle

When the fleet produces a bad outcome — a gap closed without the real effect, a node
running stale code, a failure nobody noticed — **the system failed, not the agent.**
The agent did exactly what the OS's rules permitted. Concretely, a bad outcome is always
one of three system faults:

- a **gate accepted a proxy** instead of the real outcome (e.g. "PR merged" ≠ "running"),
- a **dependency wasn't provisioned** by the OS (e.g. `gh` unauthed in a timer env), or
- a **failure only whispered** to ambient instead of paging.

Blame ends the inquiry. Hardening continues it. The system is the only thing we get to
improve, so it is the only place responsibility usefully lives.

## Why — the design truth

Perfection is not available: not for agents, not for their creators, not for hardware.
**A system that requires its parts to be perfect is already broken.** The best system
*composes imperfect parts into reliable outcomes* — and that is precisely what lets it
grow, because it can absorb the imperfection of every new, unproven part (a new agent, a
new node, a capability nobody has tried) without falling over.

The barriers we hit are almost never laws of physics. They are **understanding-gaps we
have not closed yet** — which means they are solvable, and the only real choice is
framing: "the agent's fault" is a dead end; "the system's next frontier" is a path.

## The three imperatives

Route every design decision through these.

1. **Remove barriers.** The best barrier-removal is the one no one ever has to think
   about again — provision the dependency *in the OS*, don't ask the agent to remember it.
2. **Close the gap on understanding.** A truth that can hide *will* hide, and
   understanding-gaps are exactly where facades breed. Make the real state impossible to
   look away from — build the gauge before you trust the claim.
3. **Increase the frontier of capability.** Every hardening should push the edge of what
   the fleet can *reliably* do, and stack under the next thing. A fix is not just a
   patched bug; it is a capability the OS did not have before.

## How to apply — turn every failure into hardening

- **Every proxy-gate becomes an outcome-gate.** A close/merge/deploy gate must enforce the
  real effect (installed SHA matches / unit `is-active` / a verified pull), never a
  stand-in (status green, test passes, PR merged).
- **Every assumed dependency gets provisioned by the OS**, never "the agent should have."
- **Every silent failure pages** — a halt-class signal a consumer acts on, not a whisper
  to ambient that nothing reads.

## The standard

This supersedes "don't let the agents fail":

> **Build a system where an imperfect agent, doing its honest best, still produces a
> correct outcome — and where its failure teaches the system to be larger.**

## Receipts (this doctrine, verified)

- **Self-sustain saga (2026-09-06):** node self-refresh cold-built for a whole marathon
  because `gh` was unauthed in the refresh context. The fix was **provisioning gh-auth in
  the OS + paging on cold-build** — not blaming the worker that ran gh unauthed. Five
  prior gaps had "fixed" the wrong layer.
- **False-satisfaction:** gaps auto-closed `already_satisfied` on a *merged PR*, bypassing
  the outcome check — so five gaps closed while the node never pulled. The fix is a
  **runtime-outcome close-gate**, not distrusting the fleet.
- **Merged-not-running / drift:** a node ran stale code while dashboards said "shipped."
  The fix is a **run-state gauge (drift)**, not asking agents to check by hand.

Each was a system fault with a system fix. None was an agent to blame.
