# Desktop / PWA Parity Checklist

Feature parity matrix between the browser PWA (`--web`) and the desktop Tauri app (`--desktop`). See [ADR-003](ADR-003-pwa-dashboard-fe-gate.md) and [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md).

## Parity matrix

| Feature | Browser PWA | Tauri Desktop | Notes |
|---------|------------|----------------|-------|
| Chat with SSE streaming | ✓ | ✓ | Both use `/api/chat` |
| Tool approval (Allow once / Deny / Allow always) | ✓ | ✓ | Both use `POST /api/approve` |
| Task panel | ✓ | ✓ | |
| Dashboard (health, episodes) | ✓ | ✓ | |
| PWA installability (manifest) | ✓ | N/A | Tauri is native |
| Push notifications (VAPID) | ✓ | ✓ via IPC | Tauri uses `health_snapshot` IPC |
| Settings panel | ✓ | ✓ | |
| OOTB wizard | ✓ | ✓ | |
| Dark mode | ✓ | ✓ | |
| Single-instance enforcement | N/A | ✓ | New launch focuses existing window |
| Native Dock icon | N/A | ✓ | `macos-cowork-dock-app.sh` |
| Offline mode | Planned | Planned | Service worker intercept (P4) |
| Permissions panel | Planned | Planned | Tier 2 |
| Mode switcher | Planned | Planned | Tier 2 |

## Testing parity

```bash
# Browser PWA tests
node scripts/run-web-ui-selftests.cjs
bash scripts/run-ui-e2e.sh

# Tauri E2E
bash scripts/run-tauri-e2e.sh    # Linux CI / local WebDriver

# Parity check (manual): open both, confirm same chat + approval flow
```

## Known parity gaps

1. **Offline queue** — Not implemented in either (P4)
2. **Memory search UI** — Not in either (Tier 2)
3. **Pilot summary panel** — Not in either (Tier 2)

## See Also

- [ADR-003](ADR-003-pwa-dashboard-fe-gate.md) — FE architecture gate
- [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) — Tier 2 feature spec
- [PACKAGING_AND_NOTARIZATION.md](PACKAGING_AND_NOTARIZATION.md) — Tauri build + signing
- [OPERATIONS.md](OPERATIONS.md) — Desktop (Tauri) section
