import AppKit
import LocalCronKit
import Observation
import SwiftUI

/// The menu bar icon. A left click opens the app window at the page the user
/// left (jobs, runs, calendar, logs, chat, secrets, settings); a right click
/// shows the app commands. This replaces SwiftUI's MenuBarExtra, which
/// cannot open its window from code.
@MainActor
final class StatusItemController: NSObject {
    private unowned let model: AppModel
    /// Variable: the "Clock and text" style adds text.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// The window with every page, as in Slack.
    private var appWindow: AppWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
        let windowPerform: (AppMenu.Action) -> Void = { [weak self] action in self?.perform(action, fromWindow: true) }
        appWindow = AppWindow(title: Instance.current.appName, size: NSSize(width: 1180, height: 720),
                              minSize: NSSize(width: 820, height: 600), frameName: "AppWindow",
                              onKey: { [model] key in model.appWindowKey = key }) { [model] in
            AnyView(WindowFrame { AppWindowView(perform: windowPerform) }.environment(model))
        }
        model.openSettings = { [weak self] page in self?.showSettings(page) }
        model.openAppWindow = { [weak self] in self?.appWindow?.show() }
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        trackIcon()
    }

    /// Orange icon: a local build, or any instance that is not the release.
    private let isDev = BuildKind.current == .dev || !Instance.current.isRelease
    /// Turns the arc of the ring style while a run works.
    private var spinTimer: Timer?
    private var spin = 0.0

    /// Redraw the icon whenever the daemon state or the icon setting changes.
    private func trackIcon() {
        withObservationTracking {
            drawIcon()
            // Read so a poll redraws: the ring and the time move on.
            _ = model.now
            let spinning = model.iconStyle == .ring && model.statusIcon.state == .working
            if spinning, spinTimer == nil {
                spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.spin = (self.spin + 1.0 / 17).truncatingRemainder(dividingBy: 1)
                        self.drawIcon()
                    }
                }
            } else if !spinning, let timer = spinTimer {
                timer.invalidate()
                spinTimer = nil
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackIcon() }
        }
    }

    private func drawIcon() {
        let icon = model.statusIcon
        let name = BuildKind.current == .dev ? "\(Instance.current.appName) (development build)" : Instance.current.appName
        let style = model.iconStyle
        let image = MenuBarIconRenderer.image(style: style, icon: icon, colored: model.iconColor, dev: isDev, spin: spin)
        image.accessibilityDescription = icon.toolTip(appName: name)
        guard let button = item.button else { return }
        button.image = image
        button.imagePosition = .imageLeading
        let label = style == .clockText ? icon.label() : ""
        if button.title != label {
            button.attributedTitle = label.isEmpty ? NSAttributedString() : NSAttributedString(
                string: " " + label,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
                             .baselineOffset: 0.5])
        }
        button.toolTip = icon.toolTip(appName: name)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            // Open the menu after the button's mouse tracking ends, so the
            // menu does not take the button's mouse-up.
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { self.showMenu() } }
        } else {
            appWindow?.show()
        }
    }

    /// The app window at Settings, at `page` or at the section shown last.
    func showSettings(_ page: SettingsPage?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: SettingsView.pageKey) }
        model.windowPage = .settings
        appWindow?.show()
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
            case let .submenu(title, symbol, detail, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                // A job's submenu shows the job's icon.
                if let job = model.job(title) {
                    item.image = JobGlyph.menuImage(job.job)
                } else if let symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                if let detail { setDetail(item, detail) }
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
        if let symbol = entry.symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else if let jobID = entry.action.jobInMenu, let job = model.job(jobID) {
            // An entry of Run a Job Now or Copy Job as Prompt.
            item.image = JobGlyph.menuImage(job.job)
        }
        if entry.checked { item.state = .on }
        if entry.emphasized {
            item.attributedTitle = NSAttributedString(string: entry.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        if let detail = entry.detail { setDetail(item, detail) }
        return item
    }

    /// Small text under the title; a tooltip before macOS 14.4.
    private func setDetail(_ item: NSMenuItem, _ detail: String) {
        if #available(macOS 14.4, *) { item.subtitle = detail } else { item.toolTip = detail }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AppMenu.Action else { return }
        perform(action, fromWindow: false)
    }

    /// Runs a command of the icon's menu or of the window. From the icon's
    /// menu the window may be closed, so a result is said in an alert; in
    /// the window it goes to the footer.
    func perform(_ action: AppMenu.Action, fromWindow: Bool) {
        switch action {
        case .openWindow:
            // Menu actions run while the menu is closing; open the window after it.
            DispatchQueue.main.async { self.appWindow?.show() }
        case .newJob:
            DispatchQueue.main.async { self.model.newJob() }
        case let .setPaused(paused):
            Task { @MainActor in await model.setPaused(paused) }
        case let .showLog(runID):
            // The app window, at the Logs page.
            DispatchQueue.main.async { self.model.showLog(runID: runID) }
        case let .allowSecrets(jobID):
            guard let job = model.jobs.first(where: { $0.id == jobID }) else { return }
            Task { @MainActor in
                // From the menu the footer is not seen: say a failure in an
                // alert. Cancel leaves no message, so an old one is cleared.
                model.actionError = nil
                let allowed = await model.allowSecrets(job)
                if !allowed, !fromWindow, let why = model.actionError {
                    alert(.failed("\(jobID) was not allowed", why))
                }
            }
        case .settings:
            DispatchQueue.main.async { self.showSettings(nil) }
        case let .runNow(jobID), let .runEarly(jobID):
            guard let job = model.job(jobID) else { return }
            let early = action == .runEarly(jobID)
            Task { @MainActor in
                model.actionError = nil
                await model.runNow(job, early: early)
                if !fromWindow, let why = model.actionError { alert(.failed("\(jobID) did not start", why)) }
            }
        case .copyMCPCommand: model.copy(model.mcpCommand)
        case let .copySharePrompt(jobID):
            if let jobID {
                guard let job = model.job(jobID) else { return }
                model.copySharePrompt([job])
            } else {
                model.copySharePrompt()
            }
        case .openLogsFolder: model.openLogsFolder()
        case .openHelp: model.openHelp()
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
            case .idle, .checking, .downloading, .waitingForRuns:
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
