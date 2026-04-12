# macOS: signing and notarization (Chump desktop)

Use this checklist when you move from **ad-hoc** `codesign` (fine for local testing) to **distribution** builds that strangers can open without Gatekeeper friction.

## Prerequisites

- Paid **Apple Developer** membership.
- **Developer ID Application** certificate installed in Keychain (Xcode or developer.apple.com).
- An **app-specific password** (or API key) for Apple’s notary service — used by `notarytool`.

## Build the app

1. Produce a release `.app` (see [TAURI_MACOS_DOCK.md](TAURI_MACOS_DOCK.md) and [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md)).
2. For novice installs, prefer **`CHUMP_BUNDLE_RETAIL=1 ./scripts/macos-cowork-dock-app.sh`** so `LSEnvironment` does not hard-code a dev repo path.

## Sign

- Sign the **app bundle** with your **Developer ID Application** identity (not “Apple Development”).
- Typical approach: sign inner binaries first, then the bundle with `--deep` only if you understand the implications; Apple’s current guidance favors explicit signing order over blind `--deep`.

```bash
# Example only — replace IDENTITY and APP path
codesign --force --options runtime --sign "Developer ID Application: Your Name (TEAMID)" -v "Chump.app"
```

Verify:

```bash
codesign --verify --deep --strict --verbose=2 "Chump.app"
spctl -a -vv "Chump.app"
```

## Notarize

Submit a **zip** or **dmg** of the signed app (not the loose `.app` folder alone, depending on workflow — `notarytool` accepts `.zip` of the `.app`):

```bash
ditto -c -k --keepParent "Chump.app" "Chump.zip"
xcrun notarytool submit "Chump.zip" --wait --keychain-profile "AC_NOTARY"
```

Staple the ticket to the app:

```bash
xcrun stapler staple "Chump.app"
```

## CI secrets (GitHub Actions)

Store **no** private keys or passwords in the repo. Use encrypted secrets, for example:

- `APPLE_CERT_BASE64` — exported signing cert + key (PKCS#12) or use **OIDC** + App Store Connect API key where supported.
- `APPLE_NOTARY_KEY` / profile — for `notarytool` non-interactive auth.

The repo ships an **unsigned** artifact workflow: [.github/workflows/tauri-desktop.yml](../.github/workflows/tauri-desktop.yml). Extend that job with signing and notarization steps once secrets exist.

## References

- Apple: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- Tauri: [macOS code signing](https://v2.tauri.app/distribute/sign/macos/)
