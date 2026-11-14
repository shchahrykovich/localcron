import AppKit

/// The app has no Dock icon (`.accessory`), except while one of its windows
/// is open: then it is `.regular`, so the window is in the Dock and in ⌘Tab
/// and can be found again behind other apps. The popover does not count.
@MainActor
public enum DockPresence {
    private static var observer: NSObjectProtocol?

    /// Call before a window is shown.
    public static func windowWillShow() {
        start()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// True when a titled window other than `closing` is on screen or in the Dock.
    static func needsDock(_ windows: [NSWindow], closing: NSWindow?) -> Bool {
        windows.contains { w in
            w !== closing && w.styleMask.contains(.titled) && (w.isVisible || w.isMiniaturized)
        }
    }

    private static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                if !needsDock(NSApp.windows, closing: closing), NSApp.activationPolicy() != .accessory {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
