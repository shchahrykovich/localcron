import LocalCronKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, runs, agents, daemon, updates, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .runs: "Runs"
        case .agents: "Coding Agents"
        case .daemon: "Daemon"
        case .updates: "Updates"
        case .help: "Help"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .runs: "clock"
        case .agents: "sparkle"
        case .daemon: "server.rack"
        case .updates: "arrow.down.circle"
        case .help: "questionmark.circle"
        }
    }
}

/// The Settings window: the pages on the left, the chosen page on the right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    static let pageKey = "settingsPage"
    @AppStorage(SettingsView.pageKey) private var page: SettingsPage = .general
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { sidebarRow($0) }
                Spacer()
                Text("\(Instance.current.appName) \(model.version)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title).font(.system(size: 20, weight: .semibold))
                    switch page {
                    case .general: GeneralPage()
                    case .runs: RunsPage()
                    case .agents: AgentsPage(perform: perform)
                    case .daemon: DaemonPage()
                    case .updates: UpdatesPage(perform: perform)
                    case .help: HelpPage(perform: perform)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
        }
        .disabled(model.busy)
        .tint(Theme.accentFill)
    }

    private var updateAvailable: Bool {
        if case .available = model.update { return true }
        return false
    }

    /// A page in the sidebar: grey line icon, the chosen one filled with
    /// the accent and white text.
    private func sidebarRow(_ p: SettingsPage) -> some View {
        let selected = p == page
        return Button {
            page = p
        } label: {
            HStack(spacing: 8) {
                Image(systemName: p.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : .secondary)
                Text(p.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : .primary)
                Spacer()
                if p == .daemon {
                    Circle().fill(model.running ? Theme.online : Theme.warning).frame(width: 6, height: 6)
                        .accessibilityLabel(model.running ? "running" : "not running")
                }
                if p == .updates, updateAvailable {
                    Text("1").font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? Theme.accentFill : .white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(selected ? Color.white : Theme.accentFill, in: Capsule())
                        .accessibilityLabel("an update is available")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Theme.accentFill : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// − N +, in one bordered box.
struct CountStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            step("minus", value - 1, help: "Fewer")
            Text("\(value)").font(.system(size: 13).monospacedDigit()).frame(minWidth: 34)
                .frame(maxHeight: .infinity)
                .background(Theme.card)
            step("plus", value + 1, help: "More")
        }
        .frame(height: 26)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.neutralLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    private func step(_ symbol: String, _ next: Int, help: String) -> some View {
        Button { set(next) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(next))
        .help(help)
    }
}

/// A setting: its title and explanation on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var openAtLogin = OpenAtLogin().isOn

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Card {
                SettingRow(title: "Open at login", detail: "The daemon runs jobs without the app; the app shows them.") {
                    Toggle("", isOn: $openAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: openAtLogin) { _, on in
                            if let problem = OpenAtLogin().choose(on) { model.say(problem, failed: true) }
                            openAtLogin = OpenAtLogin().isOn
                        }
                }
                if let note = OpenAtLogin().note {
                    RowDivider()
                    LinkButton(note) { model.openLoginItems() }.padding(14)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("The icon in the menu bar")
                Card {
                    ForEach(Array(IconStyle.allCases.enumerated()), id: \.element) { i, style in
                        if i > 0 { RowDivider() }
                        styleRow(style)
                    }
                    RowDivider()
                    SettingRow(title: "Show problems in color",
                               detail: "Green while a run works, red for a failed run, orange for a job that waits for your OK.") {
                        Toggle("", isOn: $model.iconColor).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What every style keeps").font(.system(size: 12, weight: .semibold))
                    ForEach(["A click opens the window; a right click opens the menu.",
                             "A failed run stays shown until a run of that job ends well.",
                             "The tooltip lists everything that is going on.",
                             "A development build is orange."], id: \.self) {
                        Label($0, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func styleRow(_ style: IconStyle) -> some View {
        let selected = model.iconStyle == style
        return Button {
            model.iconStyle = style
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarIconRenderer.image(style: style, icon: model.statusIcon, colored: model.iconColor, dev: false))
                    if style == .clockText {
                        Text(model.statusIcon.label()).font(.system(size: 12).monospacedDigit())
                    }
                }
                .frame(width: 64, height: 24)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Text(style.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RunsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ConsoleTerminal.defaultsKey) private var consoleTerminal = ""
    /// The choices of the log space, in MB.
    private static let budgets: [UInt32] = [100, 500, 1024, 5120]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let config = model.config {
                Card {
                    SettingRow(title: "Runs at the same time",
                               detail: "More runs wait in a queue. A job never runs twice at once: a second run is skipped.") {
                        CountStepper(value: Int(config.maxConcurrent), range: 1...16) { n in
                            Task { await model.setConfig(maxConcurrent: UInt32(n)) }
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Space for run logs",
                               detail: "When the logs use more, the oldest are deleted first. The newest run of each job is always kept.") {
                        Picker("", selection: Binding(get: { config.logBudgetMB },
                                                      set: { mb in Task { await model.setConfig(logBudgetMB: mb) } })) {
                            ForEach(budgetChoices(config.logBudgetMB), id: \.self) { Text(Formatting.bytes(UInt64($0) * 1024 * 1024)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    if model.kittyURL != nil {
                        RowDivider()
                        SettingRow(title: "Open run consoles in",
                                   detail: "A Claude Code run works in a console you can watch and type into. It needs tmux.") {
                            Picker("", selection: Binding(
                                get: { ConsoleTerminal.chosen(saved: consoleTerminal, kittyInstalled: true) },
                                set: { consoleTerminal = $0.rawValue })) {
                                ForEach(ConsoleTerminal.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 130)
                        }
                    }
                }
                Card {
                    SettingRow(title: "Pause all jobs",
                               detail: "No scheduled run starts. Run Now still works. A time missed while paused is not caught up.") {
                        Toggle("", isOn: Binding(get: { model.paused }, set: { on in Task { await model.setPaused(on) } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            } else {
                Text("The daemon is not running: these settings are kept by it.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Run logs") { LinkButton("Show in Finder") { model.openLogsFolder() } }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let logs = model.status?.logs {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(Formatting.bytes(logs.bytes)) of \(Formatting.bytes(logs.budgetBytes))")
                                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                                Text(usageText(logs)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            UsageBar(logs: logs)
                        }
                        if let status = model.status {
                            Text(JobGroups.tilde(status.logsDir + "/runs")).font(Theme.mono).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("A secret's value never reaches a log: it shows as <secret NAME>.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    /// The fixed choices, and the saved value when it is none of them (set
    /// with the CLI).
    private func budgetChoices(_ current: UInt32) -> [UInt32] {
        Self.budgets.contains(current) ? Self.budgets : (Self.budgets + [current]).sorted()
    }

    /// "212 logs. pr-review uses the most: 21 MB."
    private func usageText(_ logs: LogUsage) -> String {
        var text = logs.files == 1 ? "1 log." : "\(logs.files) logs."
        if let job = logs.largestJob, logs.files > 1 { text += " \(job) uses the most: \(Formatting.bytes(logs.largestJobBytes))." }
        return text
    }
}

/// The space of the logs against the budget: the job that uses the most in
/// the accent, the other jobs lighter.
private struct UsageBar: View {
    let logs: LogUsage

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(1, logs.budgetBytes))
            let largest = CGFloat(Double(logs.largestJobBytes) / total) * geo.size.width
            let rest = CGFloat(Double(logs.bytes - min(logs.bytes, logs.largestJobBytes)) / total) * geo.size.width
            HStack(spacing: 1) {
                if largest > 0 { Rectangle().fill(Theme.accentFill).frame(width: max(2, min(largest, geo.size.width))) }
                if rest > 0 { Rectangle().fill(Theme.accentFill.opacity(0.45)).frame(width: max(2, min(rest, geo.size.width - largest))) }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: 6, alignment: .leading)
            .background(Theme.field)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .help(logs.largestJob.map { "\($0): \(Formatting.bytes(logs.largestJobBytes)); other jobs: \(Formatting.bytes(logs.bytes - min(logs.bytes, logs.largestJobBytes)))" } ?? "")
    }
}

private struct AgentsPage: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Claude Code and Codex add, change and run jobs through the \(Instance.current.appName) MCP server. They read a short note on how to use it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                agentRow("Claude Code", detail: "Adds the MCP server and a note to ~/.claude/CLAUDE.md.", button: "Add", action: .installClaude)
                RowDivider()
                agentRow("Codex", detail: "Adds the MCP server to config.toml and a note to AGENTS.md.", button: "Add", action: .installCodex)
                RowDivider()
                agentRow("Command line tool",
                         detail: model.cliInstalled ? "Installed in ~/.local/bin." : "Links \(Instance.current.cli) into ~/.local/bin.",
                         button: model.cliInstalled ? "Reinstall" : "Install", action: .installCLI)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("MCP command, for another agent")
                CopyLine(text: model.mcpCommand)
            }
        }
    }

    /// The button's last result shows under it: when nothing changes (the
    /// tool is installed already), a click must still show that it worked.
    private func agentRow(_ title: String, detail: String, button: String, action: AppMenu.Action) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                if let result = model.agentResult, result.action == action {
                    Label(result.feedback.summary, systemImage: result.feedback.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(result.feedback.failed ? Theme.dangerText : Theme.successText)
                        .textSelection(.enabled)
                        .id(result.at)
                        .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.25), value: model.agentResult?.at)
            Spacer()
            SmallButton(button) { perform(action) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DaemonPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if let status = model.status {
                    SettingRow(title: "Version") { Text("\(status.daemonVersion), pid \(status.pid)").foregroundStyle(.secondary) }
                    RowDivider()
                    SettingRow(title: "Jobs") { Text("\(status.enabledJobs) on, \(status.jobs) in all").foregroundStyle(.secondary) }
                    RowDivider()
                    SettingRow(title: "Data") {
                        Text(JobGroups.tilde(status.dataDir)).font(Theme.mono).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    SettingRow(title: "Not running", detail: model.daemonProblem) {
                        SmallButton("Start the Daemon", prominent: true) {
                            model.registerDaemon()
                            model.pollNow()
                        }
                    }
                }
            }
            if let note = model.serviceNote {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.warningText)
            }
            LinkButton("Open Login Items in System Settings") { model.openLoginItems() }
        }
    }
}

private struct UpdatesPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoUpdate") private var autoUpdate = true
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        Card {
            SettingRow(title: "Check for updates automatically", detail: "Every 6 hours. An update is installed only when you click it.") {
                Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: "\(Instance.current.appName) \(model.version)", detail: updateDetail) {
                updateControl
            }
        }
    }

    private var updateDetail: String? {
        switch model.update {
        case .upToDate: "Up to date."
        case let .failed(why): why
        case let .available(release): "Version \(release.version) is available."
        default: nil
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch model.update {
        case .idle, .upToDate, .failed:
            SmallButton("Check for Updates") { perform(.checkForUpdates) }
        case .checking:
            ProgressView().controlSize(.small)
        case let .available(release):
            SmallButton("Install \(release.version)", prominent: true) { Task { await model.installUpdate(release) } }
        case let .downloading(release):
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing \(release.version)…").font(.caption)
            }
        }
    }
}

private struct HelpPage: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                SettingRow(title: "Help", detail: "Every command and the agent instructions, in your browser. Copy as Markdown gives it to an agent.") {
                    SmallButton("Open") { perform(.openHelp) }
                }
            }
            Card {
                SettingRow(title: "Uninstall \(Instance.current.appName)",
                           detail: "Stops the daemon and deletes every job, run and log, the command line tool link, the notes and the Claude Code MCP server.") {
                    Button("Uninstall…", role: .destructive) {
                        if confirm("Uninstall \(Instance.current.appName)?",
                                   "This stops the daemon and deletes every job, run and log, the command line tool link, the notes and the Claude Code MCP server.",
                                   button: "Uninstall") {
                            Task { await model.uninstall() }
                        }
                    }
                }
                RowDivider()
                SettingRow(title: "Quit \(Instance.current.appName)", detail: "The daemon goes on running jobs.") {
                    SmallButton("Quit") { perform(.quit) }
                }
            }
        }
    }
}
