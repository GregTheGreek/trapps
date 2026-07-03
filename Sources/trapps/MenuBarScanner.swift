import AppKit
import ApplicationServices
import os

struct MenuBarEntry {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let frame: CGRect
    let isHidden: Bool
}

final class MenuBarScanner {
    // These processes own the system status items (Wi-Fi, battery, clock, ...)
    // which are pinned right of the notch and never hidden by it.
    private static let deniedBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
    ]

    private static let axTimeoutSeconds: Float = 0.25
    private static let logger = Logger(subsystem: "com.gregthegreek.trapps", category: "scanner")
    private static let unknownFrame = CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 0, height: 0)

    // Cache state; read and written on the main thread only.
    private(set) var cachedEntries: [MenuBarEntry] = []
    private(set) var hasScanned = false
    private var refreshInFlight = false
    private var pendingCompletions: [() -> Void] = []

    private let scanQueue = DispatchQueue(label: "com.gregthegreek.trapps.scan", qos: .userInitiated)

    /// Rescans all apps on a background queue and updates the cache on the
    /// main thread, so opening the menu never blocks on AX round trips.
    func refresh(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let completion {
            pendingCompletions.append(completion)
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let apps = NSWorkspace.shared.runningApplications
        let notch = Notch.detect()
        scanQueue.async { [weak self] in
            guard let self else { return }
            let start = Date()
            let entries = self.scan(apps: apps, notch: notch)
            let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
            Self.logger.info("scanned \(apps.count) apps, found \(entries.count) items in \(elapsedMS)ms")
            DispatchQueue.main.async {
                self.cachedEntries = entries
                self.hasScanned = true
                self.refreshInFlight = false
                let completions = self.pendingCompletions
                self.pendingCompletions = []
                completions.forEach { $0() }
            }
        }
    }

    private func scan(apps: [NSRunningApplication], notch: Notch?) -> [MenuBarEntry] {
        let ownPID = getpid()
        let candidates = apps.filter { app in
            guard app.processIdentifier != ownPID, !app.isTerminated else { return false }
            if let bundleID = app.bundleIdentifier, Self.deniedBundleIDs.contains(bundleID) { return false }
            return true
        }

        // Each app query is an independent synchronous mach IPC round trip;
        // fanning out across lanes keeps slow/hung apps from serializing.
        var perApp = [[MenuBarEntry]](repeating: [], count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let found = scanApp(candidates[index], notch: notch)
            guard !found.isEmpty else { return }
            lock.lock()
            perApp[index] = found
            lock.unlock()
        }

        var entries = perApp.flatMap { $0 }
        entries.sort { $0.frame.minX < $1.frame.minX }
        return disambiguated(entries)
    }

    private func scanApp(_ app: NSRunningApplication, notch: Notch?) -> [MenuBarEntry] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeoutSeconds)

        guard let extrasBar = copyAttribute(appElement, "AXExtrasMenuBar") as CFTypeRef?,
              CFGetTypeID(extrasBar) == AXUIElementGetTypeID() else { return [] }
        let barElement = extrasBar as! AXUIElement

        guard let children = copyAttribute(barElement, kAXChildrenAttribute) as? [AXUIElement],
              !children.isEmpty else { return [] }

        let appName = app.localizedName ?? "Unknown"
        let icon = resizedIcon(app.icon)

        return children.map { item in
            let frame = Self.frame(of: item) ?? Self.unknownFrame
            return MenuBarEntry(
                element: item,
                pid: app.processIdentifier,
                appName: appName,
                icon: icon,
                title: resolveTitle(of: item, appName: appName),
                frame: frame,
                isHidden: notch?.hides(frame) ?? false
            )
        }
    }

    // MARK: - Actions

    /// Presses the item (its left-click action). Falls back to activating the
    /// owning app so a failed press still surfaces something.
    @discardableResult
    func press(_ entry: MenuBarEntry) -> Bool {
        if perform(entry, action: kAXPressAction as String) { return true }
        if let app = NSRunningApplication(processIdentifier: entry.pid) {
            app.activate(options: [])
        }
        return false
    }

    /// Opens the item's context menu via the AX action. Many items don't
    /// implement it - callers should fall back to a synthetic right-click.
    @discardableResult
    func showMenu(_ entry: MenuBarEntry) -> Bool {
        perform(entry, action: kAXShowMenuAction as String)
    }

    /// Performs an AX action, retrying once against a fresh scan of the
    /// owning app in case the cached element went stale.
    private func perform(_ entry: MenuBarEntry, action: String) -> Bool {
        if AXUIElementPerformAction(entry.element, action as CFString) == .success {
            return true
        }

        Self.logger.warning("\(action, privacy: .public) failed for \(entry.title, privacy: .public); rescanning pid \(entry.pid)")
        guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return false }
        let fresh = scanApp(app, notch: nil)
        let retry = fresh.first { $0.title == entry.title } ?? fresh.first
        guard let retry else { return false }
        return AXUIElementPerformAction(retry.element, action as CFString) == .success
    }

    // MARK: - Attribute helpers

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private func resolveTitle(of item: AXUIElement, appName: String) -> String {
        if let title = stringAttribute(item, kAXTitleAttribute) { return title }
        if let description = stringAttribute(item, kAXDescriptionAttribute) { return description }

        // Some items nest an AXButton that carries the label.
        if let children = copyAttribute(item, kAXChildrenAttribute) as? [AXUIElement],
           let child = children.first {
            if let title = stringAttribute(child, kAXTitleAttribute) { return title }
            if let description = stringAttribute(child, kAXDescriptionAttribute) { return description }
        }
        return appName
    }

    private func resizedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    /// Suffixes duplicate titles with (2), (3), ... so multi-item apps stay distinguishable.
    func disambiguated(_ entries: [MenuBarEntry]) -> [MenuBarEntry] {
        var counts: [String: Int] = [:]
        return entries.map { entry in
            let seen = counts[entry.title, default: 0] + 1
            counts[entry.title] = seen
            guard seen > 1 else { return entry }
            return MenuBarEntry(
                element: entry.element,
                pid: entry.pid,
                appName: entry.appName,
                icon: entry.icon,
                title: "\(entry.title) (\(seen))",
                frame: entry.frame,
                isHidden: entry.isHidden
            )
        }
    }
}
