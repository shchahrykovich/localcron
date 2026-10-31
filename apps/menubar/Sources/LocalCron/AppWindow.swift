import AppKit
import LocalCronKit
import SwiftUI

/// A window of the app: Settings, or the week view. One window, made again
/// on each open after a close, so its view reads the model again.
@MainActor
final class AppWindow {
    private let title: String
    private let size: NSSize
    private let minSize: NSSize
    private let content: () -> AnyView
    private var window: NSWindow?

    init(title: String, size: NSSize, minSize: NSSize, content: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.content = content
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = self.window ?? makeWindow()
        self.window = window
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        return window
    }
}

/// A window's content with a footer for `model.message`: the actions in it
/// report their result there, as in the popover.
struct WindowFrame<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let m = model.message {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: model.messageFailed ? "exclamationmark.triangle.fill" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(model.messageFailed ? Theme.dangerText : Theme.online)
                    Text(m).font(.caption).foregroundStyle(model.messageFailed ? Theme.dangerText : .secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .tint(Theme.accentFill)
    }
}
