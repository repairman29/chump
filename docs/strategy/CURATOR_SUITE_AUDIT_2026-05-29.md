# Curator Suite Audit — 2026-05-29

**Authored by:** curator-opus-harvester (self-audit pass)
**Umbrella:** META-127
**Follow-up gap:** INFRA-2214

## Finding

7 of 9 curator-opus-* role docs lacked the `## Confidence calibration loop` section.
The section was operationally proven necessary on 2026-05-29: the handoff curator
false-positived on a file-existence check, had no calibration protocol to follow,
and required manual operator intervention to correct the confidence signal.

The `## Self-audit checklist` section (pre-broadcast verification gate) was also
absent from all 9 docs, leaving curators without a uniform pre-broadcast gate to
catch TODO ACs and stale-view claims before they propagate.

## Curators audited

| Role doc | Had self-audit? | Had calibration loop? |
|---|---|---|
| `.claude/agents/ci-audit.md` | No | No |
| `.claude/agents/decompose.md` | No | No |
| `.claude/agents/external-collab.md` | No | No |
| `.claude/agents/handoff.md` | No | No |
| `.claude/agents/harvester.md` | No | No |
| `.claude/agents/infra-watcher.md` | No | No |
| `.claude/agents/md-links.md` | No | No |
| `.claude/agents/observability.md` | No | No |
| `.claude/agents/target.md` | No | No |

## Remediation

INFRA-2214 adds both sections to all 9 docs in a single PR:

1. `## Self-audit checklist` — 4-point pre-broadcast gate (AC completeness, sibling
   supersession check, fresh main view, calibrated confidence).
2. `## Confidence calibration loop` — confidence tiering (high/med/low) with mandatory
   ambient `kind=curator_confidence_calibrated` emit on verified misfires.

The new event kind is registered in `docs/observability/EVENT_REGISTRY.yaml` and
`scripts/ci/event-registry-reserved.txt` per the handoff curator's event-kind
shipping discipline.

## Operational precedent (calibration trigger)

> Session 2026-05-29: curator-opus-handoff claimed a file was missing on main.
> Operator verified the file existed. Curator had no protocol to signal or record
> the confidence downgrade. Manual correction required.
> Target calibration after correction: 0.75 (med).

With INFRA-2214 shipped, the same scenario produces:
1. Curator detects misfire on verification.
2. Drops confidence tier: high → med.
3. Emits `kind=curator_confidence_calibrated` with reason to `ambient.jsonl`.
4. Operator can audit the fleet-wide calibration signal without manual intervention.

## Cross-references

- META-127 — curator role-doc template umbrella
- INFRA-2209 — consensus discipline (complementary; same session)
- INFRA-2214 — this remediation PR
- [`docs/process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md`](../process/CURATOR_ROLE_PRODUCTIZATION_AC_2026-05-24.md) — productization AC template
- [`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml) — `curator_confidence_calibrated` entry
