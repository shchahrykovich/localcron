import LocalCronKit
import SwiftUI

/// The title bar of a page of the app window: an icon, a title, a line
/// under it, and the page's buttons at the end. As the Chat header.
struct PageHeader<Trailing: View>: View {
    let page: AppModel.WindowPage
    let title: String
    var subtitle: String?
    var subtitleColor: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.symbol)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Theme.neutralSoft, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(subtitleColor).lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// The lists of Jobs, Runs and Secrets were made for a narrow column; in the
/// window they keep a readable width, in the middle.
private struct Column<Content: View>: View {
    var width: CGFloat = 820
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.top, 12)
            .frame(maxWidth: width, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .background(Theme.ground)
    }
}

/// Jobs: today's strip and every job, or the editor of one job.
struct JobsWindowPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case let .editor(draft) = model.page {
            Column(width: 680) {
                JobEditorView(draft: draft)
                    // A new editor for each job, so the fields start fresh.
                    .id(draft.isNew ? "new" : draft.id)
            }
        } else {
            VStack(spacing: 0) {
                PageHeader(page: .jobs, title: model.jobs.isEmpty ? "Jobs" : "Jobs · \(model.jobs.count)",
                           subtitle: statusLine, subtitleColor: model.running && !model.paused ? .secondary : Theme.warningText) {
                    if model.running {
                        if model.activeRuns.count > 1 {
                            IconButton(symbol: "stop.fill", help: "Stop all runs", size: 28) { Task { await model.stopAll() } }
                        }
                        IconButton(symbol: model.paused ? "play.fill" : "pause.fill",
                                   help: model.paused ? "Resume all jobs" : "Pause all jobs: no scheduled run starts", size: 28) {
                            Task { await model.setPaused(!model.paused) }
                        }
                        if !model.jobs.isEmpty {
                            SmallButton("+ New Job", prominent: true) { model.newJob() }
                                .keyboardShortcut("n")
                        }
                    }
                }
                Column {
                    if model.status == nil, model.daemonProblem != nil || model.serviceNote != nil {
                        NotRunningView()
                    } else {
                        JobsView()
                    }
                }
            }
        }
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
}

/// Runs: by day, as a month, or the tokens agents used.
struct RunsWindowPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .runs, title: "Runs", subtitle: logsLine) {
                if model.runsMode == .list {
                    LinkButton("Open All Logs") { model.windowPage = .logs }
                }
            }
            Column { RunsView() }
        }
    }

    private var logsLine: String? {
        model.status?.logs.map { "Run logs use \(Formatting.bytes($0.bytes)) of \(Formatting.bytes($0.budgetBytes))" }
    }
}

/// Secrets: their names and state, the jobs that wait for an OK, or the
/// editor of one secret.
struct SecretsWindowPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case let .secretEditor(draft) = model.page {
            Column(width: 680) {
                SecretEditorView(draft: draft)
                    .id(draft.isNew ? "new-secret" : "secret-\(draft.name)")
            }
        } else {
            VStack(spacing: 0) {
                PageHeader(page: .secrets, title: "Secrets",
                           subtitle: "Values stay in your login keychain; the app never shows one") {
                    if model.running {
                        SmallButton("+ New Secret", prominent: true) { model.newSecret() }
                    }
                }
                Column { SecretsView() }
            }
        }
    }
}

/// A new version, at the bottom of the rail: a click installs it.
struct RailUpdate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.update {
        case let .available(release):
            Button { Task { await model.installUpdate(release) } } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accentFill)
                    Text("Update").font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Install \(Instance.current.appName) \(release.version)")
        case .downloading:
            VStack(spacing: 3) {
                ProgressView().controlSize(.small)
                Text("Installing").font(.system(size: 10)).foregroundStyle(.secondary)
            }
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
