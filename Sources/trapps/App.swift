import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate is weak: this local is what keeps the delegate
        // (and, through it, the status item and global hot key) alive for the
        // life of the process while app.run() blocks. Don't inline it away.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
        Permissions.promptIfNeeded()
    }
}
