import AppKit
import LocalCronKit
import Observation
import SwiftUI

/// The menu bar icon. A left click toggles the LocalCron window (a popover),
/// a right click shows the app commands. This replaces SwiftUI's
/// MenuBarExtra, which cannot open its window from code.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private unowned let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    /// When the popover last closed. A click on the icon first closes the
    /// popover, then reaches `clicked`; without this check the same click
    /// would open it again.
    private var closedAt = Date.distantPast

    init(model: AppModel) {
        self.model = model
        super.init()
        // Semi-transient: the folder panel and alerts of this app do not
        // close it; a click in another app does.
        popover.behavior = .semitransient
        popover.delegate = self
        let main = MainView(perform: { [weak self] action in self?.perform(action, fromWindow: true) })
        let content = NSHostingController(rootView: main.environment(model).frame(width: 520, height: 600))
        content.sizingOptions = .preferredContentSize
        // After the controller: setting it resets contentSize.
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 520, height: 600)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            let name = Instance.current.appName
            button.toolTip = BuildKind.current == .dev ? "\(name) (development build)" : name
        }
        trackIcon()
    }

    /// Orange icon: a local build, or any instance that is not the release.
    private let isDev = BuildKind.current == .dev || !Instance.current.isRelease

    /// Redraw the icon whenever the daemon state changes.
    private func trackIcon() {
        withObservationTracking {
            let name = !model.running ? "clock.badge.exclamationmark" : model.anyRunActive ? "clock.arrow.circlepath" : "clock"
            var image = NSImage(systemSymbolName: name, accessibilityDescription: Instance.current.appName)
            // The status bar ignores contentTintColor, so the color is drawn
            // into the image, which then must not be a template.
            if isDev {
                image = image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
                image?.isTemplate = false
            }
            item.button?.image = image
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackIcon() }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            // Open the menu after the button's mouse tracking ends, so the
            // menu does not take the button's mouse-up.
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { self.showMenu() } }
        } else if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            showWindow()
        }
    }

    func showWindow() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.windowOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        model.windowOpen = false
    }

    // MARK: Right-click menu

    private func showMenu() {
        item.menu = makeMenu(AppMenu.entries(model.menuContext))
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeMenu(_ entries: [AppMenu.Entry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .header(title):
                menu.addItem(.sectionHeader(title: title))
            case let .item(entry):
                menu.addItem(menuItem(entry))
            case let .submenu(title, symbol, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.submenu = makeMenu(children)
                menu.addItem(item)
            }
        }
        return menu
    }

    private func menuItem(_ entry: AppMenu.Item) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(menuAction(_:)), keyEquivalent: entry.shortcut ?? "")
        item.target = self
        item.representedObject = entry.action
        if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if entry.checked { item.state = .on }
        if entry.emphasized {
            item.attributedTitle = NSAttributedString(string: entry.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        if let detail = entry.detail {
            if #available(macOS 14.4, *) { item.subtitle = detail } else { item.toolTip = detail }
        }
        return item
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AppMenu.Action else { return }
        perform(action, fromWindow: false)
    }

    /// Runs a command of the icon's menu or of the window. From the icon's
    /// menu the window is closed, so a result is said in an alert; in the
    /// window it goes to the footer.
    func perform(_ action: AppMenu.Action, fromWindow: Bool) {
        switch action {
        case .openWindow:
            // Menu actions run while the menu is closing; open the window after it.
            DispatchQueue.main.async { self.showWindow() }
        case .newJob:
            model.newJob()
            DispatchQueue.main.async { self.showWindow() }
        case .settings:
            model.page = .tabs
            model.tab = .settings
            DispatchQueue.main.async { self.showWindow() }
        case .copyMCPCommand: model.copy(model.mcpCommand)
        case .openLogsFolder: model.openLogsFolder()
        case .installCLI: report(model.installCLI(), fromWindow: fromWindow)
        case .installClaude:
            Task { @MainActor in report(await model.installClaude(), fromWindow: fromWindow) }
        case .installCodex: report(model.installCodex(), fromWindow: fromWindow)
        case .checkForUpdates:
            if fromWindow { Task { @MainActor in await model.checkForUpdates(manual: true) } } else { checkForUpdates() }
        case .quit: NSApp.terminate(nil)
        }
    }

    /// The window shows results in its footer; the menu shows an alert.
    private func report(_ feedback: Feedback, fromWindow: Bool) {
        guard !fromWindow else { return }
        DispatchQueue.main.async { self.alert(feedback) }
    }

    private func checkForUpdates() {
        Task { @MainActor in
            await model.checkForUpdates(manual: true)
            switch model.update {
            case let .available(release):
                let answer = alert(.updateAvailable(release, current: model.version), buttons: ["Install", "Later"])
                guard answer == .alertFirstButtonReturn else { return }
                await model.installUpdate(release)
                // On success the app quits; it is still here only on failure.
                if case let .failed(why) = model.update { alert(.failed("Could not install the update", why)) }
            case .upToDate:
                alert(.upToDate(version: model.version))
            case let .failed(why):
                alert(.failed("Could not check for updates", why))
            case .idle, .checking, .downloading:
                break
            }
        }
    }

    @discardableResult
    private func alert(_ feedback: Feedback, buttons: [String] = []) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = feedback.title
        alert.informativeText = feedback.detail
        alert.alertStyle = feedback.failed ? .warning : .informational
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }
}
