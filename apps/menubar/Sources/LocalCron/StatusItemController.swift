import AppKit
import LocalCronKit
import Observation
import SwiftUI

/// The menu bar icon. A left click toggles the LocalCron window (a popover),
/// a right click shows the app commands. It also owns the Settings and week
/// windows. This replaces SwiftUI's
/// MenuBarExtra, which cannot open its window from code.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private unowned let model: AppModel
    /// Variable: the "Clock and text" style adds text.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: AppWindow?
    private var weekWindow: AppWindow?
    /// When the popover last closed. A click on the icon first closes the
    /// popover, then reaches `clicked`; without this check the same click
    /// would open it again.
    private var closedAt = Date.distantPast
    /// While the popover is shown: a click in another app, and this app
    /// losing focus (kitty opened), close it. `.transient` alone misses
    /// clicks in other apps once this app is not the active one.
    private var outsideClicks: Any?
    private var resignActive: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()
        // Semi-transient: the folder panel and alerts of this app do not
        // close it; a click in another app does.
        // Closes on a click anywhere outside, other apps included
        // (.semitransient ignores clicks in other apps).
        popover.behavior = .transient
        popover.delegate = self
        let main = MainView(perform: { [weak self] action in self?.perform(action, fromWindow: true) })
        let content = NSHostingController(rootView: main.environment(model).frame(width: 480, height: 600))
        content.sizingOptions = .preferredContentSize
        // After the controller: setting it resets contentSize.
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 480, height: 600)
        let windowPerform: (AppMenu.Action) -> Void = { [weak self] action in self?.perform(action, fromWindow: true) }
        settingsWindow = AppWindow(title: "\(Instance.current.appName) Settings", size: NSSize(width: 780, height: 560),
                                   minSize: NSSize(width: 640, height: 420)) { [model] in
            AnyView(WindowFrame { SettingsView(perform: windowPerform) }.environment(model))
        }
        weekWindow = AppWindow(title: "\(Instance.current.appName) Runs", size: NSSize(width: 1120, height: 700),
                               minSize: NSSize(width: 760, height: 480)) { [model] in
            AnyView(WindowFrame { WeekView(perform: windowPerform) }.environment(model))
        }
        model.openSettings = { [weak self] page in self?.showSettings(page) }
        model.openWeek = { [weak self] in
            self?.popover.performClose(nil)
            self?.weekWindow?.show()
        }
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

    /// Settings, at `page` or at the page shown last.
    func showSettings(_ page: SettingsPage?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: SettingsView.pageKey) }
        popover.performClose(nil)
        settingsWindow?.show()
    }

    func showWindow() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.windowOpen = true
        watchOutside()
    }

    /// performClose asks popoverShouldClose, so an alert or panel of this app
    /// keeps the popover open.
    private func watchOutside() {
        stopWatchingOutside()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        resignActive = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopWatchingOutside() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let resignActive { NotificationCenter.default.removeObserver(resignActive) }
        outsideClicks = nil
        resignActive = nil
    }

    /// Stay open while an alert or the folder panel opened from the popover
    /// runs: a click in it is outside the popover, but the user is not done.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        NSApp.modalWindow == nil
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        model.windowOpen = false
        stopWatchingOutside()
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
        } else if case let .runNow(jobID) = entry.action, let job = model.job(jobID) {
            // An entry of Run a Job Now.
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
        case let .setPaused(paused):
            Task { @MainActor in await model.setPaused(paused) }
        case let .stopRun(runID):
            if let run = model.activeRuns.first(where: { $0.id == runID }) {
                Task { @MainActor in await model.cancel(run) }
            }
        case let .openTerminal(runID):
            if let run = model.activeRuns.first(where: { $0.id == runID }) { model.openTerminal(run) }
        case .stopAllRuns:
            Task { @MainActor in await model.stopAll() }
        case let .showLog(runID):
            model.showLog(runID: runID)
            DispatchQueue.main.async { self.showWindow() }
        case let .allowSecrets(jobID):
            guard let job = model.jobs.first(where: { $0.id == jobID }) else { return }
            Task { @MainActor in
                // From the menu the footer is not seen: say a failure in an
                // alert. Cancel leaves no message, so an old one is cleared.
                model.message = nil
                let allowed = await model.allowSecrets(job)
                if !allowed, !fromWindow, model.messageFailed, let why = model.message {
                    alert(.failed("\(jobID) was not allowed", why))
                }
            }
        case .settings:
            DispatchQueue.main.async { self.showSettings(nil) }
        case let .runNow(jobID), let .runEarly(jobID):
            guard let job = model.job(jobID) else { return }
            let early = action == .runEarly(jobID)
            Task { @MainActor in
                model.message = nil
                await model.runNow(job, early: early)
                if !fromWindow, model.messageFailed, let why = model.message { alert(.failed("\(jobID) did not start", why)) }
            }
        case let .showRuns(jobID):
            model.showRuns(jobID: jobID)
            DispatchQueue.main.async { self.showWindow() }
        case let .editJob(jobID):
            guard let job = model.job(jobID) else { return }
            model.edit(job)
            DispatchQueue.main.async { self.showWindow() }
        case .copyMCPCommand: model.copy(model.mcpCommand)
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
