import AppKit
import LocalCronKit
import SwiftUI

/// The app window. Made again on each open after a close, so its view reads
/// the model again. With `frameName` it opens where and as large as the
/// user left it. `onKey` hears when it becomes or stops being the key
/// window.
@MainActor
final class AppWindow {
    private let title: String
    private let size: NSSize
    private let minSize: NSSize
    private let content: () -> AnyView
    private let frameName: String?
    private let onKey: ((Bool) -> Void)?
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(title: String, size: NSSize, minSize: NSSize, frameName: String? = nil, onKey: ((Bool) -> Void)? = nil,
         content: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.frameName = frameName
        self.onKey = onKey
        self.content = content
    }

    func show() {
        if let window, window.isVisible || window.isMiniaturized {
            bringForward(window)
            return
        }
        let window = self.window ?? makeWindow()
        self.window = window
        WindowContent.host(content(), in: window, size: size)
        // The frame saved when the user last moved or sized it, else the middle.
        if !(frameName.map { window.setFrameUsingName($0) } ?? false) { window.center() }
        DockPresence.windowWillShow()
        bringForward(window)
    }

    /// In front of every app, and key. Since macOS 14 `NSApp.activate()`
    /// only asks: the system refuses it after a click on the menu bar icon,
    /// because that click does not make this app the active one, and the
    /// window then opened behind the app in front. `ignoringOtherApps`
    /// activates this app at once; `orderFrontRegardless` puts the window on
    /// top even if the activation is still refused.
    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        if let frameName { window.setFrameAutosaveName(frameName) }
        if onKey != nil {
            let center = NotificationCenter.default
            for (name, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false),
                                (NSWindow.willCloseNotification, false)] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKey?(key) }
                })
            }
        }
        return window
    }
}

/// A window's content with a footer for `model.actionError`: an action in
/// it that fails says why there.
struct WindowFrame<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.actionError {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.dangerText)
                    Text(error).font(.caption).foregroundStyle(Theme.dangerText)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Hide", size: 20) { model.actionError = nil }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .tint(Theme.accentFill)
    }
}
