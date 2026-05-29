# Fleet Scrubber

A single-page gantt timeline for visualizing Chump fleet activity.
Part of the fleet visualization umbrella INFRA-2164.

## Quick start

### Fixture mode (no server needed)

```bash
# Generate fixture data
python3 web/fleet-scrubber/fixtures/gen.py

# Open in browser with fixture data
bash scripts/dev/chump-fleet-view.sh --fixtures
# or open directly:
open "web/fleet-scrubber/index.html?fixtures=1"
```

### Live mode (requires chump-fleet-server INFRA-2175)

```bash
# Start the fleet server (INFRA-2175)
chump fleet server start   # or however INFRA-2175 exposes this

# Open the scrubber
chump fleet view
# equivalent to: open http://localhost:7070/scrubber
```

The server (INFRA-2175) must mount a static-file route at `/scrubber/*` serving
from `web/fleet-scrubber/`. See INFRA-2176 AC interpretations for details.

## UI overview

```
+------------------------------------------------------------+--------+
| Fleet Scrubber  [LIVE] [REPLAY] [1x] [+][-]  window label | legend |
+------------------------------------------------------------+--------+
| session-id-abc1   |==[edit]============[push]==[merge]=   |        |
| session-id-def2   |=[claim]==[edit]==================[bl]  | detail |
| session-id-ghi3   |[idle]===[edit]=====[edit]=========     | panel  |
+--------------------+--------------------------------------+---------+
|                [    timeline scrub bar / brush            ]         |
+--------------------------------------------------------------------+
```

- **Lanes area**: one row per session_id visible in the window; label left, gantt segments right.
- **Timeline scrub bar**: shows the full data range with a draggable brush for the visible window.
- **Side panel**: opens on segment click; shows metadata and underlying events. Click an event to expand its payload.
- **LIVE toggle**: snaps view to now, opens WebSocket to `/api/live`, prepends incoming segments.
- **REPLAY**: animates a cursor across the visible window at 1x/10x/60x speed; segments flash as the cursor passes.
- **Zoom**: `+`/`-` buttons or scroll wheel; range 5 min to 24 h.

## Activity colors

| Activity | Color   | Hex       |
|----------|---------|-----------|
| claim    | orange  | `#f59e0b` |
| edit     | blue    | `#3b82f6` |
| push     | green   | `#10b981` |
| merge    | purple  | `#8b5cf6` |
| blocked  | red     | `#ef4444` |
| idle     | gray    | `#9ca3af` |

## API endpoints (read from chump-fleet-server INFRA-2175)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/segments?from=&to=` | Gantt segments for time range |
| GET | `/api/events?from=&to=` | Events for time range |
| GET | `/api/sessions/active` | Active session IDs (highlighted in labels) |
| WS  | `/api/live` | Live tail; server pushes `{type:"segment"|"event", data:{...}}` |

Query param `?fixtures=1` bypasses the server and reads from `fixtures/segments.json`
and `fixtures/events.json` for dev/demo without a running server.

## Fixtures

```bash
cd web/fleet-scrubber/fixtures
python3 gen.py
# => segments.json (56 segments across 3 sessions, 2h window)
# => events.json   (181 events)
```

`gen.py` uses a fixed random seed (42) for reproducible output. Re-run after
editing to regenerate.

## Screenshot

```
+--------------------------------------------------------------+---------+
| Fleet Scrubber  LIVE  ▶ REPLAY  10x  +  -  13:00→15:00 (2h) |legend   |
+--------------------------------------------------------------+---------+
| opus-shepherd-abc12  |▓▓▓▓▓▓▓(edit)▓▓▓▓▓▓|░░(push)|▓▓(merge)|        |
| sonnet-worker-def34  |▒(claim)|▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓(edit)▓▓▓▓▓▓| detail  |
| sonnet-worker-ghi56  |░░░(idle)░░|▓▓▓▓▓▓(edit)▓▓|██(blocked)| panel  |
+----------------------+------------------------------------------+------+
|    [                  ████████ scrub brush ██████              ]        |
+-----------------------------------------------------------------------+
```

Note: actual screenshot not committed (browser capture unavailable in CI
environment). The above is a text-art preview. See INFRA-2176 for follow-up.

## CI smoke test

```bash
bash scripts/ci/test-fleet-scrubber.sh
```

Asserts: D3 v7 CDN tag, required element IDs, CSS variables, fixture JSON validity,
generator script presence, bash view script, README.

## Files

```
web/fleet-scrubber/
  index.html            Single-page app (vanilla JS + D3 v7, no build step)
  README.md             This file
  fixtures/
    gen.py              Fixture generator (python3, no deps)
    segments.json       Pre-generated segments (56 entries, 3 sessions, 2h)
    events.json         Pre-generated events (181 entries)
  screenshots/
    scrubber-fixtures.png  (placeholder — see README note above)
scripts/dev/
  chump-fleet-view.sh   Opens http://localhost:7070/scrubber (or fixture mode)
scripts/ci/
  test-fleet-scrubber.sh  Smoke test
```
