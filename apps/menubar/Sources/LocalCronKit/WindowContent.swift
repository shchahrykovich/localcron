import AppKit
import SwiftUI

/// Puts a SwiftUI view in a window.
@MainActor
public enum WindowContent {
    /// The window keeps `size` (made smaller to fit on the screen) and its own
    /// `contentMinSize`; the view does not size the window. By default
    /// `NSHostingController` makes the view's smallest size the window's
    /// smallest size, and a text with `fixedSize(vertical:)` beside buttons
    /// is very tall at its smallest width: the window grew past the bottom of
    /// the screen, and its buttons with it.
    public static func host<V: View>(_ view: V, in window: NSWindow, size: NSSize) {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(fitted(size, for: window, on: window.screen ?? NSScreen.main))
    }

    static func fitted(_ size: NSSize, for window: NSWindow, on screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else { return size }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let chrome = NSSize(width: frame.width - size.width, height: frame.height - size.height)
        return NSSize(width: min(size.width, visible.width - chrome.width),
                      height: min(size.height, visible.height - chrome.height))
    }
}
