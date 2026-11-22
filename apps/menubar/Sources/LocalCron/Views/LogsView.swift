import LocalCronKit
import SwiftUI

/// The app window, as in Slack: a rail of pages on the left (jobs, runs,
/// the calendar, the logs, the chat with the jobs, secrets, Settings) and
/// the chosen page beside it. The calendar and the logs read the history,
/// so it is loaded here while the window is open.
struct AppWindowView: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            PageRail()
            Rectangle().fill(Theme.line).frame(width: 0.5)
            Group {
                switch model.windowPage {
                case .jobs: JobsWindowPage()
                case .runs: RunsWindowPage()
                case .secrets: SecretsWindowPage()
                case .calendar: WeekView(perform: perform)
                case .logs: LogsView()
                case .chat: ChatView()
                case .settings: SettingsView(perform: perform)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            while !Task.isCancelled {
                await model.loadHistory()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// The pages of the app window, one icon above the other with its name
/// under it; Settings at the bottom. Chat shows how many messages are
/// unread, Secrets a dot while a job waits for the user's OK.
struct PageRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ForEach(AppModel.WindowPage.allCases.filter { $0 != .settings }, id: \.self) { page in
                item(page)
            }
            Spacer(minLength: 10)
            RailUpdate()
            item(.settings)
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func item(_ page: AppModel.WindowPage) -> some View {
        let selected = model.windowPage == page
        return Button { model.windowPage = page } label: {
            VStack(spacing: 4) {
                Image(systemName: page.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(selected ? Theme.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(alignment: .topTrailing) {
                        if page == .secrets, model.jobs.contains(where: { $0.secretsAllowed == false }) {
                            Circle().fill(Theme.warning).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Theme.sidebar, lineWidth: 2).padding(-2))
                                .offset(x: 2, y: -2)
                                .help("A job waits for your OK")
                        } else if page == .chat, model.unreadMessages > 0 {
                            Text("\(model.unreadMessages)")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.unread, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.sidebar, lineWidth: 2).padding(-2))
                                .offset(x: 6, y: -5)
                        }
                    }
                Text(page.rawValue)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page == .chat && model.unreadMessages > 0 ? "Chat, \(model.unreadMessages) new" : page.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Every run the daemon keeps, by day, on the left; the log of the chosen
/// run on the right. With no run chosen, the newest one in the list.
struct LogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let runs = model.logFilter.apply(model.allRuns, query: model.logJobFilter)
        let shownID = model.logRunID ?? runs.first?.id
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Segments(items: RunFilter.allCases, selection: $model.logFilter, fill: false) { filter, _ in Text(filter.title) }
                    .fixedSize()
                FilterField(prompt: "Filter by job", text: $model.logJobFilter).frame(width: 220)
                Spacer()
                if let logs = model.status?.logs {
                    Text("Run logs use \(Formatting.bytes(logs.bytes)) of \(Formatting.bytes(logs.budgetBytes))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("The oldest logs are deleted when they use more. Settings, Runs.")
                }
                LinkButton("Open Logs Folder") { model.openLogsFolder() }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.ground)
            Divider()
            HStack(spacing: 0) {
                list(runs, shownID: shownID)
                    .frame(width: 400)
                    .background(Theme.ground)
                Divider()
                Group {
                    if let shownID {
                        RunLogView(runID: shownID).id(shownID)
                    } else {
                        VStack(spacing: 6) {
                            Text("No log to show").font(.system(size: 13, weight: .medium))
                            Text("Click a run on the left to see its log here.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground)
            }
        }
    }

    @ViewBuilder private func list(_ runs: [Run], shownID: String?) -> some View {
        if runs.isEmpty {
            VStack(spacing: 6) {
                Text(model.allRuns.isEmpty ? "No runs yet" : "No run matches").font(.system(size: 13, weight: .medium))
                Text(model.allRuns.isEmpty ? "A run shows here when a job starts." : "Choose All, or clear the job filter.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let days = RunGroups.byDay(runs, now: model.now)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(days) { day in
                            VStack(spacing: 6) {
                                SectionLabel(text: day.title) { Text(RunGroups.count(day.runs.count)) }
                                Card {
                                    ForEach(Array(day.runs.enumerated()), id: \.element.id) { i, run in
                                        if i > 0 { RowDivider() }
                                        RunRow(run: run, selected: run.id == shownID).id(run.id)
                                    }
                                }
                            }
                            .id(day.id)
                        }
                    }
                    .padding(14)
                }
                .onAppear { reveal(model.logRunID, in: days, proxy) }
                .onChange(of: model.logRunID) { _, id in reveal(id, in: days, proxy) }
            }
        }
    }

    /// Scrolls to a run opened from elsewhere (the Runs page, a message, the
    /// calendar). Its day first: rows of a day not drawn yet cannot be found.
    private func reveal(_ id: String?, in days: [RunDay], _ proxy: ScrollViewProxy) {
        guard let id, let day = days.first(where: { $0.runs.contains { $0.id == id } }) else { return }
        proxy.scrollTo(day.id, anchor: .top)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
}

/// The output of one run. Refreshes itself while the run is not finished.
struct RunLogView: View {
    @Environment(AppModel.self) private var model
    let runID: String
    @State private var log: GetRunLogResult?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let job = model.job(log?.run.jobId ?? "") { JobTile(job: job, showDot: false) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(log?.run.jobId ?? runID).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await load() } }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            if let log {
                content(log)
            } else if let error {
                Text(error).foregroundStyle(Theme.dangerText).padding()
                Spacer()
            } else {
                ProgressView().padding()
                Spacer()
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                if log?.run.status.isFinished == true { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// "Run apple-books-charts.77, 30 min ago".
    private var subtitle: String {
        guard let at = log?.run.shownAt else { return "Run \(runID)" }
        return "Run \(runID), " + Formatting.past(at, now: model.now)
    }

    private func content(_ log: GetRunLogResult) -> some View {
        let run = log.run
        let job = model.job(run.jobId)
        let line = RunText.line(run, now: model.now)
        return VStack(spacing: 10) {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Chip(text: run.shownStatus.title, kind: run.shownStatus.chip)
                        Text(line.text).font(.system(size: 12)).foregroundStyle(line.tone == .plain ? .primary : line.tone.color)
                            .lineLimit(2)
                        Spacer()
                        if !run.status.isFinished {
                            if run.console != nil { SmallButton("Terminal") { model.openTerminal(run) } }
                            SmallButton("Stop") { Task { await model.cancel(run) } }
                        } else if let job {
                            if job.job.kind == .claude, run.sessionId != nil {
                                SmallButton("Resume") { model.resume(run) }
                                    .help("Open this session again in Claude Code, in a terminal, in the job's folder")
                            }
                            SmallButton("Run Again") { Task { await model.runNow(job) } }
                        }
                    }
                    RowDivider()
                    detail("Started by", RunText.startedBy(run, scheduleText: job?.scheduleText))
                    if let job {
                        detail(job.job.kind == .shell ? "Command" : "Prompt", (job.job.kind == .shell ? job.job.command : job.job.prompt) ?? "",
                               mono: job.job.kind == .shell)
                        detail("Folder", JobGroups.tilde(job.job.dir))
                    }
                    if let usage = run.usage {
                        detail("Tokens", RunText.tokens(usage))
                    }
                    if let session = run.sessionId, job?.job.kind == .claude {
                        HStack(alignment: .center, spacing: 8) {
                            Text("Session").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                            CopyLine(text: "claude --resume \(session)")
                                .help("Open this session again in Claude Code, in the job's folder")
                        }
                    }
                }
            }
            HStack {
                Text("Output").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(outputNote(log)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                LinkButton("Reveal in Finder") { model.revealLog(run) }
                LinkButton("Open in Console") { model.openLogInConsole(run) }
            }
            .padding(.horizontal, 4)
            ScrollView([.vertical, .horizontal]) {
                Text(log.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            // Bottom left: the newest lines, from the start of each line.
            // `.bottom` is x = 0.5, which shows the middle or end of long lines.
            .defaultScrollAnchor(.bottomLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func detail(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(mono ? Theme.mono : .system(size: 12)).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "214 lines, the end is shown".
    private func outputNote(_ log: GetRunLogResult) -> String {
        let lines = log.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return log.truncated ? "the end of \(Formatting.bytes(log.size)) is shown" : "\(lines) lines"
    }

    private func load() async {
        switch await model.log(runID) {
        case let .success(l):
            log = l
            error = nil
        case let .failure(e):
            error = e.localizedDescription
        }
    }
}
