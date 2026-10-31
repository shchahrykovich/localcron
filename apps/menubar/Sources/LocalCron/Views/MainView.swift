import LocalCronKit
import SwiftUI

/// The popover: a header, the tabs, and a footer. The editor and a run log
/// take the place of the header and the tabs.
struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Runs a command of the "…" menu (StatusItemController).
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            switch model.page {
            case .tabs:
                header
                Segments(items: AppModel.Tab.allCases, selection: $model.tab) { tab, _ in tabLabel(tab) }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                Group {
                    if model.status == nil, model.daemonProblem != nil || model.serviceNote != nil {
                        NotRunningView()
                    } else {
                        switch model.tab {
                        case .jobs: JobsView()
                        case .runs: RunsView()
                        case .secrets: SecretsView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .editor(draft):
                JobEditorView(draft: draft)
                    // A new editor for each job, so the fields start fresh.
                    .id(draft.isNew ? "new" : draft.id)
            case let .secretEditor(draft):
                SecretEditorView(draft: draft)
                    .id(draft.isNew ? "new-secret" : "secret-\(draft.name)")
            case let .log(runID):
                RunLogView(runID: runID).id(runID)
            }
            Rectangle().fill(Theme.line).frame(height: 0.5)
            footer
        }
        .background(Theme.ground)
        .tint(Theme.accentFill)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(active: model.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(Instance.current.appName).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(statusLine).foregroundStyle(model.running ? .secondary : Theme.warningText).lineLimit(1)
                }
                .font(.system(size: 11))
            }
            Spacer()
            if model.running {
                if model.activeRuns.count > 1 {
                    IconButton(symbol: "stop.fill", help: "Stop all runs", size: 28) { Task { await model.stopAll() } }
                }
                IconButton(symbol: model.paused ? "play.fill" : "pause.fill",
                           help: model.paused ? "Resume all jobs" : "Pause all jobs: no scheduled run starts", size: 28) {
                    Task { await model.setPaused(!model.paused) }
                }
            }
            IconButton(symbol: "slider.horizontal.3", help: "Settings", size: 28) { model.openSettings(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var dotColor: Color {
        guard let status = model.status else { return Theme.warning }
        return status.paused ? Theme.warning : Theme.online
    }

    /// "Running, 5 of 6 jobs on, 1 run working".
    private var statusLine: String {
        guard let s = model.status else { return "Not running, no job starts" }
        if s.paused { return "Paused, no scheduled run starts" + (s.running > 0 ? ", \(s.running) working" : "") }
        if s.jobs == 0 { return "Running, no jobs" }
        var text = "Running, \(s.enabledJobs) of \(s.jobs) jobs on"
        if s.running > 0 { text += s.running == 1 ? ", 1 run working" : ", \(s.running) runs working" }
        if s.queued > 0 { text += ", \(s.queued) waiting" }
        return text
    }

    @ViewBuilder private func tabLabel(_ tab: AppModel.Tab) -> some View {
        HStack(spacing: 6) {
            Text(tab.rawValue)
            switch tab {
            case .jobs where !model.jobs.isEmpty:
                Text("\(model.jobs.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            case .runs where !model.activeRuns.isEmpty:
                Text("\(model.activeRuns.count)")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accentFill, in: Capsule())
                    .accessibilityLabel("\(model.activeRuns.count) working")
            case .secrets where model.jobs.contains { $0.secretsAllowed == false }:
                Circle().fill(Theme.warning).frame(width: 6, height: 6).help("A job waits for your OK")
                    .accessibilityLabel("a job waits for your OK")
            case .secrets where !model.secrets.isEmpty:
                Text("\(model.secrets.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.page == .tabs { footerAction }
            UpdateBadge()
            if let m = model.message {
                Image(systemName: model.messageFailed ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(model.messageFailed ? Theme.dangerText : Theme.online)
                Text(m).font(.system(size: 11)).foregroundStyle(model.messageFailed ? Theme.dangerText : .secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(m)
                    .onTapGesture { model.message = nil }
            } else if model.page == .tabs, model.tab == .runs, model.runsMode == .list, let logs = model.status?.logs {
                Text("Run logs use \(Formatting.bytes(logs.bytes)) of \(Formatting.bytes(logs.budgetBytes))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("The oldest logs are deleted when they use more. Settings, Runs.")
            }
            Spacer(minLength: 4)
            Text("v\(model.version)").font(.system(size: 11)).foregroundStyle(.secondary)
            Menu {
                AppMenuItems(entries: AppMenu.entries(model.menuContext), perform: perform)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More commands")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 38)
    }

    /// The main button of the tab, at the start of the footer.
    @ViewBuilder private var footerAction: some View {
        if model.running {
            switch model.tab {
            case .jobs:
                SmallButton("+ New Job", prominent: true) { model.newJob() }
                    .keyboardShortcut("n")
            case .runs where model.runsMode == .calendar:
                SmallButton("Open Week View") { model.openWeek() }
            case .secrets:
                SmallButton("+ New Secret", prominent: true) { model.newSecret() }
            case .runs:
                EmptyView()
            }
        }
    }
}

/// AppMenu entries as a SwiftUI menu: a section per group between separators.
struct AppMenuItems: View {
    let entries: [AppMenu.Entry]
    let perform: (AppMenu.Action) -> Void

    /// The entries split at the separators; a group's first header is its title.
    private var groups: [(title: String?, entries: [AppMenu.Entry])] {
        var out: [(title: String?, entries: [AppMenu.Entry])] = [(nil, [])]
        for entry in entries {
            switch entry {
            case .separator: out.append((nil, []))
            case let .header(title) where out[out.count - 1].entries.isEmpty: out[out.count - 1].title = title
            default: out[out.count - 1].entries.append(entry)
            }
        }
        return out.filter { !$0.entries.isEmpty }
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let title = group.title {
                Section(title) { rows(group.entries) }
            } else {
                Section { rows(group.entries) }
            }
        }
    }

    private func rows(_ entries: [AppMenu.Entry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .item(item):
                let button = Button { perform(item.action) } label: {
                    if item.checked {
                        Label(item.title, systemImage: "checkmark")
                    } else if let symbol = item.symbol {
                        Label(item.title, systemImage: symbol)
                    } else {
                        Text(item.title)
                    }
                }
                if let key = item.shortcut?.first {
                    button.keyboardShortcut(KeyEquivalent(key))
                } else {
                    button
                }
            case let .submenu(title, symbol, detail, children):
                Menu {
                    AppMenuItems(entries: children, perform: perform)
                } label: {
                    let text = detail.map { "\(title)  \($0)" } ?? title
                    if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
                }
            case .header, .separator:
                EmptyView()
            }
        }
    }
}

struct UpdateBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.update {
        case let .available(release):
            Button("Update to \(release.version)") { Task { await model.installUpdate(release) } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accentFill)
                .controlSize(.small)
        case let .downloading(release):
            ProgressView().controlSize(.small)
            Text("Installing \(release.version)…").font(.caption)
        case .checking, .idle, .upToDate, .failed:
            EmptyView()
        }
    }
}

/// The daemon does not answer: the jobs are saved, nothing starts.
struct NotRunningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("The \(Instance.current.appName) daemon is not running").font(.system(size: 13, weight: .semibold))
                    }
                    Text(model.jobs.isEmpty
                         ? "No job starts until it runs."
                         : "Your \(model.jobs.count) job\(model.jobs.count == 1 ? " is" : "s are") saved. A run missed while it was off is caught up once when it starts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = model.serviceNote ?? model.daemonProblem {
                        Text(problem).font(Theme.mono).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack(spacing: 10) {
                        SmallButton("Start the Daemon", prominent: true) {
                            model.registerDaemon()
                            model.pollNow()
                        }
                        LinkButton("Open Login Items in System Settings") { model.openLoginItems() }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}
