# Packaging and notarization — hub (**P5.5**)

**Purpose:** One-line entry for **universal power P5.5** without duplicating the technical signing guide.

---

## Canonical docs (read these)

| Doc | Role |
|-----|------|
| [MACOS_NOTARIZATION.md](MACOS_NOTARIZATION.md) | **Signing + `notarytool`** checklist, `codesign` examples, Gatekeeper notes |
| [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md) | OOTB phases, **unsigned CI `.app`**, what is still required for retail |
| [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md) | Building the Dock `.app` / local iteration |
| [ROADMAP.md](ROADMAP.md) | Checkbox for **notarized DMG** when prioritized |

---

## Still required for wide distribution (summary)

Apple **Developer ID** signing, **notarized** artifact (zip/DMG), stapled ticket, and a **versioned download** story. CI today produces an **unsigned** artifact (see [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md) **P3**).

---

## Changelog

| Date | Note |
|------|------|
| 2026-04-09 | Hub doc added; technical steps live in **MACOS_NOTARIZATION.md**. |
