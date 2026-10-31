import LocalCronKit
import SwiftUI

/// The Runs tab: the runs by day, or a month calendar.
struct RunsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Segments(items: AppModel.RunsMode.allCases, selection: $model.runsMode, fill: false) { mode, _ in Text(mode.rawValue) }
                    .fixedSize()
                if model.runsMode == .list {
                    Segments(items: RunFilter.allCases, selection: $model.runFilter, fill: false) { filter, _ in
                        HStack(spacing: 4) {
                            Text(filter.title)
                            if filter == .failed, failedCount > 0 {
                                Text("\(failedCount)").foregroundStyle(Theme.dangerText)
                            }
                        }
                    }
                    .fixedSize()
                    FilterField(prompt: "Filter by job", text: $model.runJobFilter)
                } else if model.runsMode == .usage {
                    Spacer()
                    Picker("Period", selection: $model.usagePeriod) {
                        ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            switch model.runsMode {
            case .list: RunList()
            case .calendar: MonthCalendarView()
            case .usage: UsageView()
            }
        }
    }

    private var failedCount: Int { model.runs.filter(RunFilter.failed.matches).count }
}

struct RunList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.runJobFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let runs = model.runs.filter { model.runFilter.matches($0) && (query.isEmpty || $0.jobId.contains(query)) }
        if runs.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(model.runs.isEmpty ? "No runs yet" : "No run matches").font(.system(size: 13, weight: .medium))
                Text(model.runs.isEmpty ? "A run shows here when a job starts." : "Choose All, or clear the job filter.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(RunGroups.byDay(runs, now: model.now)) { day in
                        VStack(spacing: 6) {
                            SectionLabel(text: day.title) { Text(RunGroups.count(day.runs.count)) }
                            Card {
                                ForEach(Array(day.runs.enumerated()), id: \.element.id) { i, run in
                                    if i > 0 { RowDivider() }
                                    RunRow(run: run)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }
}

struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: Run
    @State private var hovering = false

    var body: some View {
        let line = RunText.line(run, now: model.now)
        Button {
            model.showLog(run)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: run.status.symbol).font(.system(size: 15)).foregroundStyle(run.status.color)
                    .frame(width: 18)
                    .help(run.status.title)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if let job = model.job(run.jobId) {
                            JobGlyph(job: job.job, size: 12).foregroundStyle(.secondary)
                        }
                        Text(run.jobId).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let chip = RunText.chip(run) {
                            Chip(text: chip, kind: run.trigger == .catchUp ? .accent : .outline)
                        }
                    }
                    Text(line.text).font(.system(size: 11, weight: line.tone == .accent ? .medium : .regular))
                        .foregroundStyle(line.tone.color).lineLimit(1).truncationMode(.tail)
                        .help(line.text)
                }
                Spacer(minLength: 4)
                if let usage = run.usage {
                    Text(Formatting.tokens(usage.total)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        .help(RunText.tokens(usage))
                }
                Text(run.shownAt.map { Formatting.clock($0) } ?? "").font(.system(size: 12).monospacedDigit())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Theme.rowHover : run.status.isFailure || line.tone == .danger ? Theme.dangerRow : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Log") { model.showLog(run) }
            Button("Reveal Log in Finder") { model.revealLog(run) }
            if let job = model.job(run.jobId) {
                Button("Run \(run.jobId) Again") { Task { await model.runNow(job) } }
                Button("Edit \(run.jobId)…") { model.edit(job) }
            }
            if !run.status.isFinished {
                Divider()
                if run.console != nil { Button("Open Terminal") { model.openTerminal(run) } }
                Button("Stop") { Task { await model.cancel(run) } }
                Button("Kill Now") { Task { await model.cancel(run, kill: true) } }
            }
        }
    }
}

/// A month: each day shows how its runs went; the chosen day shows when
/// each job ran.
struct MonthCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var month = Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())

    var body: some View {
        let marks = model.timeMarks(from: merged)
        ScrollView {
            VStack(spacing: 10) {
                Card(padding: 8) {
                    VStack(spacing: 3) {
                        HStack {
                            Text(monthTitle).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            IconButton(symbol: "chevron.left", help: "Previous month", size: 22) { shift(-1) }
                            Button("Today") {
                                month = Date()
                                selected = Calendar.current.startOfDay(for: Date())
                            }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                            IconButton(symbol: "chevron.right", help: "Next month", size: 22) { shift(1) }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) {
                                Text($0).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            ForEach(MonthGrid.days(of: month)) { day in
                                cell(day, marks: MonthGrid.marks(marks, on: day.date))
                            }
                        }
                    }
                }
                DayLanes(day: selected, marks: MonthGrid.marks(marks, on: selected))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .task {
            while !Task.isCancelled {
                await model.loadHistory()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var merged: [Run] { model.allRuns }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func cell(_ day: MonthDay, marks: [TimeMark]) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day.date)
        let isSelected = cal.isDate(day.date, inSameDayAs: selected)
        let counts = MonthGrid.counts(marks)
        let failed = marks.filter { $0.mark.isProblem }.count
        return Button {
            selected = cal.startOfDay(for: day.date)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Text("\(day.number)")
                        .font(.system(size: 11, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : day.outside ? Color.secondary.opacity(0.6) : .primary)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 2)
                        .background(isToday ? Theme.accentFill : .clear, in: Capsule())
                    Spacer(minLength: 0)
                    // The runs that ran; planned ones are not counted.
                    let done = marks.filter { $0.mark != .planned }.count
                    if done > 0 {
                        Text("\(done)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(failed > 0 ? Theme.dangerText : .secondary)
                    }
                }
                Spacer(minLength: 0)
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(counts, id: \.mark) { c in
                            Rectangle().fill(c.mark.solid)
                                .frame(width: max(2, geo.size.width * CGFloat(c.count) / CGFloat(max(1, marks.count)) - 1))
                        }
                    }
                }
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .padding(.horizontal, 4)
            .padding(.top, 3)
            .padding(.bottom, 5)
            .frame(height: 36)
            .background(isSelected ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.accentFill : day.outside ? .clear : Theme.innerLine,
                                                                    lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.number), \(RunGroups.count(marks.count))" + (failed > 0 ? ", \(failed) not OK" : ""))
    }
}

/// One day: a lane for each job, its runs at their time of day.
struct DayLanes: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let marks: [TimeMark]

    var body: some View {
        let jobs = Array(Set(marks.map(\.jobID))).sorted()
        let isToday = Calendar.current.isDateInToday(day)
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatting.dayTitle(day, now: model.now)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(MonthGrid.summary(marks)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if jobs.isEmpty {
                    Text("No job ran on this day.").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    ForEach(jobs, id: \.self) { job in
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                if let view = model.job(job) {
                                    JobGlyph(job: view.job, size: 12).foregroundStyle(.secondary)
                                }
                                Text(job).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                            }
                            .frame(width: 104, alignment: .leading)
                            .help(job)
                            let jobMarks = marks.filter { $0.jobID == job }
                            GeometryReader { geo in
                                lane(jobMarks, width: geo.size.width, now: isToday)
                            }
                            .frame(height: 18)
                            let done = jobMarks.filter { $0.mark != .planned }.count
                            Text(done > 0 ? "\(done)" : "")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(jobMarks.contains { $0.mark.isProblem } ? Theme.dangerText : .secondary)
                                .frame(width: 18, alignment: .trailing)
                                .help(RunGroups.count(done))
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(["00:00", "06:00", "12:00", "18:00"], id: \.self) {
                            Text($0).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.leading, 112)
                    .padding(.trailing, 26)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 8)
        }
    }

    private func lane(_ marks: [TimeMark], width: CGFloat, now: Bool) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * width }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.innerLine).frame(height: 1).offset(y: 9)
            ForEach(marks) { m in
                let w = max(4, (m.end ?? (m.mark == .working ? model.now : m.start)).timeIntervalSince(m.start) / 86400 * width)
                Group {
                    if m.mark == .planned {
                        PlannedMark(mark: m)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(m.mark.solid)
                            .help("\(m.jobID) \(Formatting.clock(m.start)), \(m.mark.title.lowercased())")
                            .onTapGesture { if let id = m.runID { model.showLog(runID: id) } }
                    }
                }
                .frame(width: w, height: 10)
                .offset(x: min(x(m.start), width - w), y: 4)
            }
            if now {
                Rectangle().fill(Theme.accentFill).frame(width: 2, height: 18).offset(x: x(model.now) - 1)
            }
        }
        .frame(width: width, height: 18, alignment: .topLeading)
    }
}

/// A planned time in a day lane. A click offers to run the job now; for the
/// job's next time, the run can take its place (`run_job` with `early`).
private struct PlannedMark: View {
    @Environment(AppModel.self) private var model
    let mark: TimeMark
    @State private var asking = false

    /// Only the next time of a job can be run early.
    private var isNext: Bool {
        guard let next = model.planned[mark.jobID]?.min() else { return false }
        return abs(next.timeIntervalSince(mark.start)) < 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accentFill, lineWidth: 1.5).background(Theme.card)
            .contentShape(Rectangle().inset(by: -4))
            .help("\(mark.jobID) \(Formatting.clock(mark.start)), planned. Click to run it now.")
            .onTapGesture { asking = true }
            .contextMenu { buttons }
            .popover(isPresented: $asking, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if let job = model.job(mark.jobID) { JobGlyph(job: job.job, size: 12).foregroundStyle(.secondary) }
                        Text(mark.jobID).font(.system(size: 12, weight: .semibold))
                    }
                    Text("Planned: \(Formatting.soon(mark.start, now: model.now))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if isNext {
                            SmallButton("Run Now, Instead of \(Formatting.clock(mark.start))", prominent: true) { run(early: true) }
                                .help("This run takes the place of the \(Formatting.clock(mark.start)) run; the schedule goes on after it")
                        }
                        SmallButton("Run Now", prominent: !isNext) { run(early: false) }
                            .help("An extra run; the \(Formatting.clock(mark.start)) run stays")
                    }
                }
                .padding(12)
            }
    }

    @ViewBuilder private var buttons: some View {
        if isNext {
            Button("Run Now, Instead of \(Formatting.clock(mark.start))") { run(early: true) }
        }
        Button("Run Now") { run(early: false) }
    }

    private func run(early: Bool) {
        asking = false
        guard let job = model.job(mark.jobID) else { return }
        Task { await model.runNow(job, early: early) }
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
                Button {
                    model.page = .tabs
                } label: {
                    Label("Runs", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                Spacer()
                VStack(spacing: 0) {
                    Text(log?.run.jobId ?? runID).font(.system(size: 13, weight: .semibold))
                    if let at = log?.run.shownAt {
                        Text(Formatting.past(at, now: model.now).capitalizedFirst).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await load() } }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
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

    private func content(_ log: GetRunLogResult) -> some View {
        let run = log.run
        let job = model.job(run.jobId)
        let line = RunText.line(run, now: model.now)
        return VStack(spacing: 10) {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Chip(text: run.status.title, kind: run.status.chip)
                        Text(line.text).font(.system(size: 12)).foregroundStyle(line.tone == .plain ? .primary : line.tone.color)
                            .lineLimit(2)
                        Spacer()
                        if !run.status.isFinished {
                            if run.console != nil { SmallButton("Terminal") { model.openTerminal(run) } }
                            SmallButton("Stop") { Task { await model.cancel(run) } }
                        } else if let job {
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
            .defaultScrollAnchor(.bottom)
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

extension String {
    /// "today 09:00" → "Today 09:00".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
