<p align="center">
  <img src="Assets/png/traps-mark-color-512.png" alt="Trapps" width="128" height="128">
</p>

# Trapps

A single macOS menu bar icon that reveals every menu bar item ("tray app") from all running apps - including the ones hidden behind the MacBook notch - and lets you activate any of them from a native dropdown.

## Install

Download the latest `Trapps-x.y.z.dmg` from [Releases](https://github.com/GregTheGreek/trapps/releases), open it, and drag `Trapps.app` to `/Applications`. Releases are universal (Apple Silicon + Intel), Developer ID-signed, and notarized. Requires macOS 13+.

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
- **Updates**: the menu has "Check for Updates…" and an "Automatically check for updates" toggle, powered by [Sparkle](https://sparkle-project.org). Updates are EdDSA-signed and downloaded from GitHub Releases.
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

Versioning is automated with [release-please](https://github.com/googleapis/release-please) (`.github/workflows/release-please.yml`); signing and notarization are done locally so the Developer ID private key never leaves the machine.

1. Conventional commits merged to `main` accumulate into an auto-maintained release PR. Merging it bumps the version in `Support/Info.plist` (via the `x-release-please-version` markers) and `CHANGELOG.md`, tags `vX.Y.Z`, and publishes the GitHub release (without assets).
2. Locally, on `main` at that tag, build the signed + notarized dmg, attach it (the exact versioned file, not a glob - a wildcard picks up stale artifacts from earlier builds), then refresh the Sparkle appcast so existing installs see the update:

   ```sh
   git pull
   V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
   make release && make notarize
   gh release upload "v$V" "build/Trapps-$V.dmg"

   make appcast                                   # writes build/appcast.xml (signed)
   gh release upload appcast build/appcast.xml --clobber
   ```

Requires a Developer ID Application identity in the keychain and a one-time notarytool profile: `xcrun notarytool store-credentials trapps-notary --key <p8> --key-id <id> --issuer <uuid>`.

### Auto-updates (Sparkle)

Trapps updates itself via [Sparkle](https://sparkle-project.org). The feed (`appcast.xml`) is parked on a pinned GitHub release tagged `appcast` (a stable URL that is never re-tagged); `SUFeedURL` in `Support/Info.plist` points at it, and each item's enclosure points at that version's own `vX.Y.Z` release. `make appcast` pulls the current feed, appends the new version, and re-signs it.

One-time setup:

- `make sparkle-keys` creates the EdDSA signing key in your login keychain and prints the `SUPublicEDKey`. Paste that value into `Support/Info.plist` (the private half never leaves the keychain). Back it up: losing it means clients on the old key can't verify future updates.
- Create the pinned feed release once: `gh release create appcast --title "Sparkle appcast" --notes "Update feed" --latest=false`.

Sparkle is vendored on demand: `make sparkle` fetches a pinned, checksum-verified `Sparkle.framework` into gitignored `third_party/` (any compile target pulls it in automatically).

Not distributable via the Mac App Store: driving other apps' menu bar items through the Accessibility API is incompatible with the App Store sandbox.

## Known limitations

- System items (Control Center, Wi-Fi, battery, clock) are intentionally filtered out - they are pinned right of the notch and never hidden.
- Some Electron tray apps only respond to raw mouse events and ignore the Accessibility press; Trapps falls back to activating the app and beeps if the item could not be triggered.

## License

MIT - see [LICENSE](LICENSE).
