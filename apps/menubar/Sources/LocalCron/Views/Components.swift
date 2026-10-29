import AppKit
import LocalCronKit
import SwiftUI

extension RunStatus {
    var color: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .succeeded: .green
        case .failed, .timedOut: .red
        case .canceled, .skipped: .orange
        }
    }

    var symbol: String {
        switch self {
        case .queued: "hourglass"
        case .running: "play.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .timedOut: "clock.badge.xmark"
        case .canceled: "stop.circle.fill"
        case .skipped: "forward.circle.fill"
        }
    }
}

/// A run's status: a colored symbol and its name.
struct StatusLabel: View {
    let status: RunStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}

/// "claude", "codex" or "shell" in a small capsule.
struct KindBadge: View {
    let kind: JobKind

    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case .claude: .orange
        case .codex: .purple
        case .shell: .gray
        }
    }
}

extension SecretState {
    var title: String {
        switch self {
        case .ok: "Ready"
        case .missing: "No value"
        case .unreadable: "Cannot be read"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "key.fill"
        case .missing: "key.slash"
        case .unreadable: "exclamationmark.lock.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .missing, .unreadable: .orange
        }
    }
}

extension Run {
    var started: Date? { ApiDate.parse(startedAt ?? queuedAt) }

    /// Seconds from start to end, or to now while it runs.
    var seconds: TimeInterval? {
        guard let start = ApiDate.parse(startedAt) else { return nil }
        let end = ApiDate.parse(endedAt) ?? Date()
        return end.timeIntervalSince(start)
    }
}

/// Asks with a short text and long details in a scrolling field below it, so
/// the window never grows past the screen and its buttons stay in view.
@MainActor
func confirm(_ title: String, _ detail: String, details: String, button: String) -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    if let text = scroll.documentView as? NSTextView {
        text.string = details
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
    }
    alert.accessoryView = scroll
    // Cancel is the safe answer for Return.
    alert.buttons[0].keyEquivalent = ""
    alert.buttons[1].keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
}

/// Asks before something that cannot be undone. True when confirmed.
@MainActor
func confirm(_ title: String, _ detail: String, button: String, destructive: Bool = true) -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = destructive
    return alert.runModal() == .alertFirstButtonReturn
}
