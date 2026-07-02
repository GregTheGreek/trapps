import AppKit
import ApplicationServices

enum Permissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Fires the system Accessibility prompt if the app is not yet trusted.
    static func promptIfNeeded() {
        guard !isTrusted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
