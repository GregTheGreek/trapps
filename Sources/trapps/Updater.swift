// In-app updates via Sparkle. Sparkle is linked only by the Makefile build
// (which passes `-F third_party/Sparkle -framework Sparkle`); the SwiftPM/test
// build has no such search path, so `canImport(Sparkle)` is false there and the
// stub below compiles instead. This keeps `swift test` free of the vendored
// binary framework while the shipped app gets the real updater.
//
// Feed URL and public EdDSA key are read from Info.plist (SUFeedURL /
// SUPublicEDKey); see the Makefile's `appcast` target and packaging/README.md.

#if canImport(Sparkle)
import Sparkle

@MainActor
final class Updater {
    // startingUpdater: true kicks off the scheduled background checker at launch.
    // No delegates: the standard user driver handles the whole check/download/
    // install/relaunch UI on its own.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Whether Sparkle is actually linked into this build (true here).
    let isAvailable = true

    /// False while a check is already in flight, so the menu item can disable itself.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

#else

/// No-op stand-in for builds without Sparkle linked (SwiftPM/tests, bare binary).
/// `isAvailable` is false so the update menu items hide themselves.
@MainActor
final class Updater {
    let isAvailable = false
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}

#endif
