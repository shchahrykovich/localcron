import AppKit
import LocalCronKit
import SwiftUI

/// The search palette, as Spotlight: ⌘F on any page of the app window
/// opens it over the page. It finds jobs, runs, secrets, messages and pages
/// (QuickSearch); ↑ and ↓ choose, Return opens, ⌘Return opens the chat of a
/// job or a run, Esc closes.
struct SearchPalette: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let items = model.paletteResults
        let selected = items.isEmpty ? nil : min(max(model.paletteIndex, 0), items.count - 1)
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { model.paletteShown = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Search jobs, runs, secrets, messages and pages", text: $model.paletteQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                    Text("esc").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.neutralLine, lineWidth: 1))
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                Rectangle().fill(Theme.line).frame(height: 0.5)
                if items.isEmpty {
                    Text("Nothing has “\(model.paletteQuery.trimmingCharacters(in: .whitespaces))”")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    results(items, selected: selected)
                }
                Rectangle().fill(Theme.line).frame(height: 0.5)
                Text("↑ ↓ to choose · Return to open · ⌘Return to open its chat · Esc to close")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            }
            .frame(width: 640)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .padding(.top, 64)
        }
        .onAppear { focused = true }
    }

    private func results(_ items: [QuickSearch.Item], selected: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
                            Text(item.section.rawValue)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 10)
                                .padding(.bottom, 3)
                        }
                        PaletteRow(item: item, selected: index == selected)
                            .id(item.id)
                            .onTapGesture { model.open(item.target) }
                            .onHover { if $0 { model.paletteIndex = index } }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) {
                if let selected { proxy.scrollTo(items[selected].id) }
            }
        }
    }
}

private struct PaletteRow: View {
    @Environment(AppModel.self) private var model
    let item: QuickSearch.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white : .primary)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.detail.isEmpty ? 32 : 42)
        .background(selected ? Theme.accentFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.target {
        case let .page(title):
            Image(systemName: AppModel.WindowPage(rawValue: title)?.symbol ?? "square").font(.system(size: 13))
        case let .job(id):
            if let job = model.job(id) { JobGlyph(job: job.job, size: 14) } else { Image(systemName: "questionmark") }
        case let .run(id):
            if let run = model.allRuns.first(where: { $0.id == id }) {
                Image(systemName: run.shownStatus.symbol).font(.system(size: 14))
                    .foregroundStyle(selected ? Color.white : run.shownStatus.color)
            }
        case .secret:
            Image(systemName: "key").font(.system(size: 13))
        case .message:
            Image(systemName: "bubble.left").font(.system(size: 13))
        }
    }
}

/// The keys of the palette, seen before any text field: ⌘F in the app
/// window opens and closes it; while it is open, ↑ ↓ Return and Esc drive it.
@MainActor
enum PaletteKeys {
    private static var monitor: Any?

    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, model.appWindowKey, event.window?.isKeyWindow == true else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                model.paletteShown.toggle()
                return nil
            }
            guard model.paletteShown else { return event }
            switch event.keyCode {
            case 125: // down
                model.paletteIndex = min(model.paletteIndex + 1, max(model.paletteResults.count - 1, 0))
            case 126: // up
                model.paletteIndex = max(model.paletteIndex - 1, 0)
            case 36, 76: // return
                let items = model.paletteResults
                guard !items.isEmpty else { return nil }
                model.open(items[min(max(model.paletteIndex, 0), items.count - 1)].target, chat: mods == .command)
            case 53: // escape
                model.paletteShown = false
            default:
                return event
            }
            return nil
        }
    }
}
