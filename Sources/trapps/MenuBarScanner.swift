import AppKit
import ApplicationServices
import os

// MenuBarEntry is built on the scan queue and handed back to the main actor.
// AXUIElement is a CoreFoundation handle that is safe to pass between threads
// (AX calls may be made from any thread), and `icon` is a private resized copy
// that is never mutated after construction, so the value is effectively
// immutable once created. Hence @unchecked Sendable.
struct MenuBarEntry: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let frame: CGRect
    let isHidden: Bool
}

@MainActor
final class MenuBarScanner {
    // A main-thread snapshot of the NSRunningApplication data the scan needs.
    // NSRunningApplication is not Sendable, so we read its properties (and
    // resize the icon) on the main actor and carry only this immutable snapshot
    // onto the scan queue. The NSImage is a resized copy that is never mutated
    // again. Hence @unchecked Sendable.
    private struct AppInfo: @unchecked Sendable {
        let pid: pid_t
        let name: String
        let icon: NSImage?
    }

    // Collects per-app results from concurrentPerform. A reference type with an
    // internal lock so the concurrent closure captures a Sendable handle rather
    // than a mutable local `var` (which strict concurrency forbids).
    private final class ResultsBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[MenuBarEntry]]
        init(count: Int) { storage = Array(repeating: [], count: count) }
        func set(_ value: [MenuBarEntry], at index: Int) {
            lock.lock()
            storage[index] = value
            lock.unlock()
        }
        var flattened: [MenuBarEntry] { storage.flatMap { $0 } }
    }

    // These processes own the system status items (Wi-Fi, battery, clock, ...)
    // which are pinned right of the notch and never hidden by it.
    private static let deniedBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
    ]

    // Immutable constants read from the nonisolated scan helpers, so nonisolated.
    private nonisolated static let axTimeoutSeconds: Float = 0.25
    private nonisolated static let logger = Logger(subsystem: "com.gregthegreek.trapps", category: "scanner")
    private nonisolated static let unknownFrame = CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 0, height: 0)

    // Cache state; read and written on the main actor only.
    private(set) var cachedEntries: [MenuBarEntry] = []
    private(set) var hasScanned = false
    private var refreshInFlight = false
    private var needsRescan = false
    private var pendingCompletions: [() -> Void] = []

    private let scanQueue = DispatchQueue(label: "com.gregthegreek.trapps.scan", qos: .userInitiated)

    /// Rescans all apps on a background queue and updates the cache on the main
    /// actor, so opening the menu never blocks on AX round trips. A rescan
    /// requested while one is in flight is coalesced but not dropped: the
    /// in-flight scan reruns before completions fire, so callers always see
    /// data no older than their request.
    func refresh(completion: (() -> Void)? = nil) {
        if let completion {
            pendingCompletions.append(completion)
        }
        guard !refreshInFlight else {
            needsRescan = true
            return
        }
        startScan()
    }

    private func startScan() {
        refreshInFlight = true
        needsRescan = false

        // NSRunningApplication is not Sendable, so snapshot the data we need on
        // the main actor before handing off to the scan queue.
        let ownPID = getpid()
        let candidates: [AppInfo] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ownPID, !app.isTerminated else { return nil }
            if let bundleID = app.bundleIdentifier, Self.deniedBundleIDs.contains(bundleID) { return nil }
            return AppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                icon: Self.resizedIcon(app.icon)
            )
        }
        let notch = Notch.detect()

        scanQueue.async {
            let start = Date()
            let entries = Self.scan(candidates: candidates, notch: notch)
            let elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
            Self.logger.info("scanned \(candidates.count) apps, found \(entries.count) items in \(elapsedMS)ms")
            Task { @MainActor [weak self] in
                self?.finishScan(with: entries)
            }
        }
    }

    private func finishScan(with entries: [MenuBarEntry]) {
        cachedEntries = entries
        hasScanned = true

        // An app launched or terminated mid-scan; rescan before signalling
        // completion so a queued completion never fires with pre-request data.
        // refreshInFlight stays true and completions stay queued.
        if needsRescan {
            startScan()
            return
        }

        refreshInFlight = false
        let completions = pendingCompletions
        pendingCompletions = []
        completions.forEach { $0() }
    }

    private nonisolated static func scan(candidates: [AppInfo], notch: Notch?) -> [MenuBarEntry] {
        guard !candidates.isEmpty else { return [] }

        // Each app query is an independent synchronous mach IPC round trip;
        // fanning out across lanes keeps slow/hung apps from serializing.
        let buffer = ResultsBuffer(count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let found = scanApp(candidates[index], notch: notch)
            guard !found.isEmpty else { return }
            buffer.set(found, at: index)
        }

        var entries = buffer.flattened
        entries.sort { $0.frame.minX < $1.frame.minX }
        return disambiguated(entries)
    }

    private nonisolated static func scanApp(_ app: AppInfo, notch: Notch?) -> [MenuBarEntry] {
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeoutSeconds)

        guard let extrasBar = copyAttribute(appElement, "AXExtrasMenuBar") as CFTypeRef?,
              CFGetTypeID(extrasBar) == AXUIElementGetTypeID() else { return [] }
        let barElement = extrasBar as! AXUIElement

        guard let children = copyAttribute(barElement, kAXChildrenAttribute) as? [AXUIElement],
              !children.isEmpty else { return [] }

        return children.map { item in
            let frame = Self.frame(of: item) ?? Self.unknownFrame
            return MenuBarEntry(
                element: item,
                pid: app.pid,
                appName: app.name,
                icon: app.icon,
                title: resolveTitle(of: item, appName: app.name),
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

    /// Performs an AX action, retrying once against a fresh scan of the owning
    /// app in case the cached element went stale. Runs on the main actor, so it
    /// bounds every AX round trip with a messaging timeout - otherwise a hung
    /// target app would wedge the UI (the scan-time timeout does not cover
    /// these long-lived child elements).
    private func perform(_ entry: MenuBarEntry, action: String) -> Bool {
        AXUIElementSetMessagingTimeout(entry.element, Self.axTimeoutSeconds)
        if AXUIElementPerformAction(entry.element, action as CFString) == .success {
            return true
        }

        Self.logger.warning("\(action, privacy: .public) failed for \(entry.title, privacy: .public); rescanning pid \(entry.pid)")
        let info = AppInfo(pid: entry.pid, name: entry.appName, icon: entry.icon)
        let fresh = Self.scanApp(info, notch: nil)
        let retry = fresh.first { $0.title == entry.title } ?? fresh.first
        guard let retry else { return false }
        AXUIElementSetMessagingTimeout(retry.element, Self.axTimeoutSeconds)
        return AXUIElementPerformAction(retry.element, action as CFString) == .success
    }

    // MARK: - Attribute helpers

    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
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

    private nonisolated static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private nonisolated static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private nonisolated static func resolveTitle(of item: AXUIElement, appName: String) -> String {
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

    private nonisolated static func resizedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    /// Suffixes duplicate titles with (2), (3), ... so multi-item apps stay distinguishable.
    nonisolated static func disambiguated(_ entries: [MenuBarEntry]) -> [MenuBarEntry] {
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
