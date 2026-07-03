import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let scanner = MenuBarScanner()
    private var isMenuOpen = false
    private var hotKey: HotKey?

    private static let autosaveName = "trapps"
    private static let entryToolTip =
        "Click or press its number to open · ⌥-click for its right-click menu (only some apps support this)"

    override init() {
        // Pin the item to the right end of the third-party status area
        // (0 pt from the right edge). Written before creation and on every
        // launch, so it snaps back even if it was dragged elsewhere.
        UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName
        super.init()

        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Keep the cache warm so the menu opens instantly.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCache() }
            }
        }
        refreshCache()

        // ⌃⌥Space pops the dropdown; NSMenu's built-in type-to-select and the
        // 1-9 shortcuts take it from there. performClick is a direct call on
        // our own button, not a synthesized event.
        hotKey = HotKey(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            DispatchQueue.main.async { self?.statusItem.button?.performClick(nil) }
        }
    }

    private func refreshCache(completion: (() -> Void)? = nil) {
        guard Permissions.isTrusted else { return }
        scanner.refresh(completion: completion)
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    // Called synchronously every time the menu is about to open: populate
    // instantly from the cache, then rescan in the background and live-update
    // the open menu only if its contents actually changed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)

        guard Permissions.isTrusted else { return }
        let shown = fingerprint(of: scanner.cachedEntries)
        refreshCache { [weak self] in
            guard let self, self.isMenuOpen else { return }
            if self.fingerprint(of: self.scanner.cachedEntries) != shown {
                self.populate(menu)
            }
        }
    }

    private func fingerprint(of entries: [MenuBarEntry]) -> [String] {
        entries.map { "\($0.isHidden ? "h" : "v"):\($0.title)" }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        if Permissions.isTrusted {
            buildEntriesMenu(menu)
        } else {
            buildPermissionMenu(menu)
        }

        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)

        let quit = NSMenuItem(title: "Quit Trapps", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildEntriesMenu(_ menu: NSMenu) {
        let entries = scanner.cachedEntries
        guard !entries.isEmpty else {
            menu.addItem(disabledItem(scanner.hasScanned
                ? "No menu bar items found"
                : "Scanning menu bar items…"))
            return
        }

        let hidden = entries.filter(\.isHidden)
        let visible = entries.filter { !$0.isHidden }

        var nextNumber = 1
        func add(_ entry: MenuBarEntry) {
            menu.addItem(entryItem(entry, number: nextNumber <= 9 ? nextNumber : nil))
            nextNumber += 1
        }

        if !hidden.isEmpty {
            menu.addItem(disabledItem("Behind the Notch"))
            hidden.forEach(add)
            if !visible.isEmpty {
                menu.addItem(.separator())
                menu.addItem(disabledItem("Visible"))
            }
        }
        visible.forEach(add)
    }

    private func entryItem(_ entry: MenuBarEntry, number: Int?) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(entryClicked(_:)), keyEquivalent: "")
        item.target = self
        item.image = entry.icon
        item.representedObject = entry
        item.toolTip = Self.entryToolTip
        if let number {
            item.keyEquivalent = String(number)
            item.keyEquivalentModifierMask = []
        }
        return item
    }

    private func buildPermissionMenu(_ menu: NSMenu) {
        menu.addItem(disabledItem("Trapps needs Accessibility permission to list menu bar items"))
        let grant = NSMenuItem(
            title: "Grant Accessibility Access…",
            action: #selector(grantAccess),
            keyEquivalent: ""
        )
        grant.target = self
        menu.addItem(grant)
        menu.addItem(disabledItem("You may need to quit and reopen Trapps after granting"))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // The bundled glyph, loaded as a template image so macOS tints it to match
    // the light/dark menu bar. Falls back to an SF Symbol if the resource is
    // missing (e.g. running the bare binary instead of the assembled bundle).
    private static func menuBarIcon() -> NSImage? {
        let glyph = NSImage(named: "trapps-glyph")
            ?? Bundle.main.url(forResource: "trapps-glyph", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        if let glyph {
            glyph.isTemplate = true
            glyph.size = NSSize(width: 18, height: 18)
            return glyph
        }
        return NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Trapps")
    }

    @objc private func entryClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuBarEntry else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []

        if modifiers.contains(.option) {
            // AX-only context menu; no synthetic input. Beeps when the app
            // doesn't implement AXShowMenu.
            if !scanner.showMenu(entry) { NSSound.beep() }
        } else {
            if !scanner.press(entry) { NSSound.beep() }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func grantAccess() {
        Permissions.promptIfNeeded()
        Permissions.openSystemSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
