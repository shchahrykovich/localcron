import AppKit
import LocalCronKit
import SwiftUI

/// The colors of the design (the "LocalCron menu bar redesign" canvas),
/// the same system as LocalRouter with its own accent. Surfaces and lines
/// are system colors, so light and dark mode come from macOS.
enum Theme {
    static let accent = Color(light: 0x4B47C9, dark: 0x9C98FF)
    /// A fill under white text.
    static let accentFill = Color(light: 0x4B47C9, dark: 0x5853D6)
    static let accentSoft = Color(light: 0xECEBFA, dark: 0x2E2C52)
    static let accentSoftText = Color(light: 0x3A35A8, dark: 0xBDB9FF)
    static let accentRing = Color(light: 0xE2E1F7, dark: 0x3A3766)
    static let rowHover = Color(light: 0xF5F5FA, dark: 0x2D2D35)

    static let online = Color(light: 0x23A55A, dark: 0x30C46B)
    static let failed = Color(light: 0xC8372D, dark: 0xFF6B60)
    static let warning = Color(light: 0xE08A00, dark: 0xF0A030)
    static let warningText = Color(light: 0x8A4B00, dark: 0xF5B556)
    static let warningSoft = Color(light: 0xFFF4E5, dark: 0x3A2A12)
    static let warningLine = Color(light: 0xF3D7AE, dark: 0x5A4220)
    static let successText = Color(light: 0x17663A, dark: 0x7FD8A0)
    static let successSoft = Color(light: 0xE4F4EA, dark: 0x1C3B28)
    static let successLine = Color(light: 0xBFE3CC, dark: 0x2C5A3D)
    static let dangerText = Color(light: 0xA1251B, dark: 0xFF8A80)
    static let dangerSoft = Color(light: 0xFBE1DE, dark: 0x4A1E1B)
    static let dangerLine = Color(light: 0xF0B3AC, dark: 0x6A2C27)
    static let dangerRow = Color(light: 0xFDF3F2, dark: 0x3A1C1A)
    static let neutralSoft = Color(light: 0xF1F1EE, dark: 0x3A3A3E)
    static let neutralLine = Color(light: 0xDADAD5, dark: 0x4A4A4F)
    static let stopped = Color(light: 0xA1A1A6, dark: 0x8E8E93)
    static let planned = Color(light: 0xD6D5F0, dark: 0x4A4775)

    /// The window's background. Solid: the popover's own material is almost
    /// clear on macOS 26, and the page behind it showed through.
    static let ground = Color(light: 0xF4F4F2, dark: 0x1C1C1E)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let innerLine = Color(light: 0xEFEFEC, dark: 0x343438)
    static let field = Color.primary.opacity(0.06)

    static let mono = Font.system(size: 11, design: .monospaced)
}

extension Color {
    /// A color that follows the light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

extension RunMark {
    /// A dot or a bar in the strip and the month.
    var solid: Color {
        switch self {
        case .succeeded: Theme.online
        case .failed: Theme.failed
        case .timedOut: Theme.warning
        case .stopped: Theme.stopped
        case .working: Theme.accentFill
        case .planned: Theme.planned
        }
    }

    /// A block of the week view: fill, text, border.
    var soft: (fill: Color, text: Color, border: Color) {
        switch self {
        case .succeeded: (Theme.successSoft, Theme.successText, Theme.successLine)
        case .failed: (Theme.dangerSoft, Theme.dangerText, Theme.dangerLine)
        case .timedOut: (Theme.warningSoft, Theme.warningText, Theme.warningLine)
        case .stopped: (Theme.neutralSoft, .secondary, Theme.neutralLine)
        case .working: (Theme.accentSoft, Theme.accentSoftText, Theme.accentFill)
        case .planned: (Theme.card, .secondary, Theme.planned)
        }
    }
}

extension RunText.Tone {
    var color: Color {
        switch self {
        case .plain: .secondary
        case .accent: Theme.accent
        case .danger: Theme.dangerText
        case .warning: Theme.warningText
        }
    }
}

extension RunStatus {
    var color: Color {
        switch self {
        case .queued: .secondary
        case .running: Theme.accent
        case .succeeded: Theme.online
        case .failed: Theme.failed
        case .timedOut: Theme.warning
        case .canceled, .skipped: Theme.stopped
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

    var chip: Chip.Kind {
        switch self {
        case .queued, .canceled, .skipped: .neutral
        case .running: .accent
        case .succeeded: .success
        case .failed: .danger
        case .timedOut: .warning
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
}

/// A white (dark grey in dark mode) box with a thin line and round corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The line between two rows of a card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.innerLine).frame(height: 1) }
}

/// A small title above a card, with an optional text or control at the end.
struct SectionLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}

/// A short label: a job's kind, a status, "Once".
struct Chip: View {
    enum Kind { case outline, accent, success, warning, danger, neutral }
    let text: String
    var kind: Kind = .outline

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: kind == .outline ? .regular : .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if kind == .outline { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.neutralLine, lineWidth: 1) }
            }
    }

    private var foreground: Color {
        switch kind {
        case .outline: .secondary
        case .accent: Theme.accentSoftText
        case .success: Theme.successText
        case .warning: Theme.warningText
        case .danger: Theme.dangerText
        case .neutral: .primary
        }
    }

    private var background: Color {
        switch kind {
        case .outline: .clear
        case .accent: Theme.accentSoft
        case .success: Theme.successSoft
        case .warning: Theme.warningSoft
        case .danger: Theme.dangerSoft
        case .neutral: Theme.neutralSoft
        }
    }
}

/// A borderless icon button that shows a light square under the pointer.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.48))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(hovering ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small white button with a thin border: Stop, Terminal.
struct SmallButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: prominent ? .medium : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(prominent ? Color.white : .primary)
                .background(prominent ? Theme.accentFill : Theme.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if !prominent { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.neutralLine, lineWidth: 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A text button in the accent color, as a link on a web page.
struct LinkButton: View {
    let title: String
    var color: Color = Theme.accent
    let action: () -> Void

    init(_ title: String, color: Color = Theme.accent, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .pointingHandCursor()
    }
}

/// A command or a value to copy, in a monospaced box with a copy button.
struct CopyLine: View {
    @Environment(AppModel.self) private var model
    let text: String
    /// Shown before the text, for example `$` before a shell command.
    var prompt: String?

    var body: some View {
        HStack(spacing: 8) {
            if let prompt { Text(prompt).font(Theme.mono).foregroundStyle(.secondary) }
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "doc.on.doc", help: "Copy", size: 22) { model.copy(text) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Theme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// Segments: the window tabs (fill the width) and the small filters.
struct Segments<Item: Hashable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    var fill = true
    @ViewBuilder let label: (Item, Bool) -> Label

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    label(item, selected)
                        .font(.system(size: fill ? 12 : 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .padding(.horizontal, fill ? 0 : 9)
                        .padding(.vertical, fill ? 5 : 3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: fill ? 6 : 5).fill(Theme.card)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: fill ? 8 : 7))
    }
}

/// The app's mark: a clock, white on the accent color, grey while the
/// daemon is not running.
struct AppMark: View {
    var active = true
    var body: some View {
        Image(systemName: "clock")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(active ? Theme.accentFill : Color.gray, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// A search field in a rounded box.
struct FilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// An SVG icon as an image. Made once for each drawing.
@MainActor
enum SVGImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ svg: String) -> NSImage? {
        if let hit = cache[svg] { return hit }
        guard let image = NSImage(data: Data(svg.utf8)), image.size.width > 0 else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[svg] = image
        return image
    }
}

/// A job's icon: its own SVG, or the default of its kind, on a small tile.
struct JobGlyph: View {
    let job: Job
    var size: CGFloat = 14

    var body: some View {
        if let svg = job.icon, let image = SVGImage.image(svg) {
            if job.iconColors {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit).frame(width: size, height: size)
            }
        } else {
            Image(systemName: Self.symbol(job.kind)).font(.system(size: size * 0.82, weight: .medium))
                .frame(width: size, height: size)
        }
    }

    static func symbol(_ kind: JobKind) -> String {
        switch kind {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .shell: "terminal"
        }
    }
}

/// What the status dot on a job's icon says.
enum JobDot {
    case running, on, failed, waiting, off

    init(_ job: JobView) {
        if job.activeRun != nil { self = .running }
        else if job.secretsAllowed == false { self = .waiting }
        else if job.lastRun?.status.isFailure == true { self = .failed }
        else if job.job.enabled { self = .on }
        else { self = .off }
    }

    var color: Color {
        switch self {
        case .running: Theme.accentFill
        case .on: Theme.online
        case .failed: Theme.failed
        case .waiting: Theme.warning
        case .off: Theme.stopped
        }
    }

    var title: String {
        switch self {
        case .running: "Running"
        case .on: "On"
        case .failed: "On, its last run failed"
        case .waiting: "Waits for your OK to read its secrets"
        case .off: "Off"
        }
    }
}

/// The 24-point tile of a job in a list, with its status dot.
struct JobTile: View {
    let job: JobView
    /// The color behind the tile, for the ring around the dot.
    var ground: Color = Theme.card
    var showDot = true

    var body: some View {
        let dot = JobDot(job)
        JobGlyph(job: job.job)
            .foregroundStyle(dot == .running ? Theme.accentSoftText : dot == .off ? Color.secondary : Color.primary.opacity(0.78))
            .frame(width: 24, height: 24)
            .background(dot == .running ? Theme.accentSoft : Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                if showDot {
                    Circle().fill(dot.color).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(ground, lineWidth: 2).padding(-2))
                        .offset(x: 3, y: 3)
                }
            }
            .help(dot.title)
            .accessibilityLabel("\(job.id), \(dot.title)")
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

extension View {
    /// The hand cursor over a link, as in a browser. `.pointerStyle(.link)`
    /// needs macOS 15; the app supports 14.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
