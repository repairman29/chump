# Pixel node — Helsinki→Pixel migration artifacts (RESILIENT-349, SOVEREIGN)

Live copies pulled from the pixel (`pixel-8-pro`, u0_a314) 2026-08-16.
This is the STANDBY-PATIENT organ port: Helsinki's systemd coordination organs
ported to Termux. NOT yet integrated into the deploy scripts — see the
integration gap. Source of truth is the device until integrated.

- `organ-runner.sh` → `~/organs/runner.sh` — Termux cadence scheduler
- `organ-manifest.txt` → `~/organs/manifest` — Helsinki organ commands, pixel-pathed
- `witness-probe.py` → `~/witness/probe.py` — the black-box witness (RESILIENT-348)
- `pixel-node-supervisor.sh` → `~/pixel-node-supervisor.sh` — patched with start_organs
- `termux-boot-00-node.sh` → `~/.termux/boot/00-node.sh` — boot: sshd + supervisor

Promote to ACTIVE patient: `touch ~/organs/ACTIVE && echo 1 > ~/.chump/AUTONOMY_LEVEL`.
Standby by default (mutating organs gated). Cutover to retire Helsinki: RESILIENT-354.
