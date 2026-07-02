# Trapps

A single macOS menu bar icon that reveals every menu bar item ("tray app") from all running apps - including the ones hidden behind the MacBook notch - and lets you activate any of them from a native dropdown.

## Install

Download the latest `Trapps-x.y.z.zip` from [Releases](https://github.com/GregTheGreek/trapps/releases), unzip, and drag `Trapps.app` to `/Applications`. Releases are universal (Apple Silicon + Intel), Developer ID-signed, and notarized. Requires macOS 13+.

Or build from source - see below.

## How it works

Trapps uses the macOS Accessibility API to enumerate each running app's menu bar extras (`AXExtrasMenuBar`) and triggers them with `AXPress`, which works even when the item is occluded by the notch. The list comes from a background scan cache (refreshed at launch, on app launch/quit, and on every menu open), so the dropdown opens instantly.

## Usage

- On a notched Mac, the dropdown splits into "Behind the Notch" and "Visible" sections, sorted left-to-right like the real menu bar.
- **⌃⌥Space** opens the dropdown from anywhere (Carbon global hotkey - no event taps or input monitoring). With the menu open, type an app's name to jump to it (NSMenu built-in) or press **1-9** to trigger the first nine items directly.
- **Click** an entry to open it (its normal left-click action).
- **Option-click** to open its right-click/context menu via the AXShowMenu accessibility action. Only some apps implement it; trapps beeps when one doesn't.
- **No simulated input, by design**: trapps never synthesizes mouse or keyboard events and never moves your cursor. Everything goes through Accessibility API calls (inter-process messages to the target app). To physically rearrange icons, hold Cmd and drag them in the menu bar yourself - that's built into macOS.
- **Launch at Login** toggle in the menu registers via `SMAppService`.
- The trapps icon pins itself to the right-most third-party slot on every launch.
- Reordering visible icons needs no app at all: hold Cmd and drag them directly in the menu bar (built into macOS).

## Build and run

```sh
make run        # builds, assembles build/Trapps.app, codesigns, launches
```

Requires Swift 5.9+ (no Xcode project needed). Always launch via `open build/Trapps.app` (which `make run` does) - running the bare binary directly creates a separate permission identity.

## Accessibility permission

On first launch, macOS prompts to grant Trapps Accessibility access (System Settings > Privacy & Security > Accessibility). Until granted, the menu shows a "Grant Accessibility Access…" shortcut. You may need to quit and reopen Trapps after granting.

### Rebuilds and ad-hoc signing

The Makefile signs with your Apple Development / Developer ID certificate if one is in your keychain, so the permission grant survives rebuilds. If no certificate is found it falls back to ad-hoc signing, whose code hash changes on every rebuild - macOS then silently distrusts the app even though the toggle still shows ON. To recover:

- Toggle Trapps off and back on in System Settings > Accessibility, or
- `make reset-ax` (runs `tccutil reset Accessibility com.gregthegreek.trapps`), relaunch, and re-grant.

## Releasing

Releases are built by CI (`.github/workflows/release.yml`): bump `CFBundleShortVersionString` in `Support/Info.plist`, then push a matching tag (`git tag v0.2.0 && git push origin v0.2.0`). The workflow builds a universal binary, signs with hardened runtime, notarizes, staples, and attaches the zip to a draft GitHub release.

Required repository secrets:

- `MACOS_CERTIFICATE` - base64 of the Developer ID Application certificate exported as .p12 (`base64 -i cert.p12 | pbcopy`)
- `MACOS_CERTIFICATE_PWD` - the .p12 export password
- `NOTARY_KEY` - base64 of an App Store Connect API key (.p8)
- `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` - the API key's ID and issuer UUID

Local equivalent: `make release && make notarize` (needs a Developer ID Application identity in the keychain and a one-time `xcrun notarytool store-credentials trapps-notary ...`).

Not distributable via the Mac App Store: driving other apps' menu bar items through the Accessibility API is incompatible with the App Store sandbox.

## Known limitations

- System items (Control Center, Wi-Fi, battery, clock) are intentionally filtered out - they are pinned right of the notch and never hidden.
- Some Electron tray apps only respond to raw mouse events and ignore the Accessibility press; Trapps falls back to activating the app and beeps if the item could not be triggered.
