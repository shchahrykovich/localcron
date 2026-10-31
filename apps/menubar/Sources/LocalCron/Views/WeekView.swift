import LocalCronKit
import SwiftUI

/// The week window: a column for each day, a block for each run at its time,
/// planned runs dashed. A click on a block shows that run on the right.
struct WeekView: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void
    @State private var anchor = Date()
    @State private var days = 7
    @State private var jobFilter = ""
    @State private var selected: String?

    /// Points for one hour.
    private let hour: CGFloat = 23
    private let gutter: CGFloat = 48

    var body: some View {
        let cal = mondayCalendar
        let first = days == 7 ? cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor : cal.startOfDay(for: anchor)
        let dates = (0..<days).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        let all = model.timeMarks(from: merged).filter { jobFilter.isEmpty || $0.jobID == jobFilter }
        let shown = all.filter { m in dates.contains { cal.isDate(m.start, inSameDayAs: $0) } }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar(dates)
                Divider()
                GeometryReader { geo in
                    let column = (geo.size.width - gutter - 14) / CGFloat(days)
                    VStack(spacing: 0) {
                        dayHeaders(dates, marks: shown, column: column)
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView {
                                grid(dates, marks: shown, column: column)
                                    .padding(.top, 8)
                                    .padding(.trailing, 14)
                            }
                            .onAppear { proxy.scrollTo("hour-7", anchor: .top) }
                        }
                    }
                }
            }
            .background(Theme.card)
            Divider()
            sidePanel(shown, all: all)
                .frame(width: 260)
                .background(Theme.ground)
        }
        .task {
            while !Task.isCancelled {
                await model.loadHistory()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var mondayCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var merged: [Run] {
        let fresh = Set(model.runs.map(\.id))
        return model.runs + model.history.filter { !fresh.contains($0.id) }
    }

    // MARK: Toolbar

    private func toolbar(_ dates: [Date]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.left", help: days == 7 ? "Previous week" : "Previous day", size: 26) { move(-1) }
                Button("Today") { anchor = Date() }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 10)
                IconButton(symbol: "chevron.right", help: days == 7 ? "Next week" : "Next day", size: 26) { move(1) }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.neutralLine, lineWidth: 1))
            Text(title(dates)).font(.system(size: 15, weight: .semibold)).padding(.leading, 6)
            Spacer()
            Picker("Show jobs", selection: $jobFilter) {
                Text("All jobs").tag("")
                ForEach(Array(Set(model.jobs.map(\.id) + model.history.map(\.jobId))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Segments(items: [1, 7], selection: $days, fill: false) { n, _ in Text(n == 1 ? "Day" : "Week") }.fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.ground)
    }

    private func move(_ step: Int) {
        anchor = Calendar.current.date(byAdding: .day, value: step * days, to: anchor) ?? anchor
    }

    /// "26 October to 1 November 2026", or "Friday 30 October 2026".
    private func title(_ dates: [Date]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        guard let a = dates.first, let b = dates.last else { return "" }
        if dates.count == 1 {
            f.dateFormat = "EEEE d MMMM yyyy"
            return f.string(from: a)
        }
        f.dateFormat = Calendar.current.isDate(a, equalTo: b, toGranularity: .month) ? "d" : "d MMMM"
        let start = f.string(from: a)
        f.dateFormat = "d MMMM yyyy"
        return "\(start) to \(f.string(from: b))"
    }

    // MARK: Grid

    private func dayHeaders(_ dates: [Date], marks: [TimeMark], column: CGFloat) -> some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE"
        return HStack(spacing: 0) {
            Spacer().frame(width: gutter)
            ForEach(dates, id: \.self) { day in
                let dayMarks = MonthGrid.marks(marks, on: day)
                let past = dayMarks.filter { $0.mark != .planned }
                let notOK = dayMarks.filter { $0.mark.isProblem }.count
                let today = Calendar.current.isDateInToday(day)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(f.string(from: day)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(today ? Color.white : .primary)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(today ? Theme.accentFill : .clear, in: Capsule())
                    }
                    Text(past.isEmpty ? (dayMarks.isEmpty ? "" : "\(dayMarks.count) planned")
                                      : RunGroups.count(past.count) + (notOK > 0 ? ", \(notOK) not OK" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(notOK > 0 ? Theme.dangerText : .secondary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(width: column, height: 44, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.innerLine).frame(width: 1) }
            }
            Spacer(minLength: 0)
        }
    }

    private func grid(_ dates: [Date], marks: [TimeMark], column: CGFloat) -> some View {
        let height = hour * 24
        return ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { h in
                Rectangle().fill(h % 6 == 0 ? Theme.line : Theme.innerLine).frame(height: 1)
                    .offset(x: gutter, y: CGFloat(h) * hour)
                    .id("hour-\(h)")
                if h % 2 == 0, h < 24 {
                    Text(String(format: "%02d:00", h)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .offset(y: CGFloat(h) * hour - 6)
                }
            }
            ForEach(Array(dates.enumerated()), id: \.offset) { i, day in
                let x = gutter + CGFloat(i) * column
                Rectangle().fill(Theme.innerLine).frame(width: 1, height: height).offset(x: x)
                if Calendar.current.isDateInToday(day) {
                    Rectangle().fill(Theme.accentFill.opacity(0.04)).frame(width: column, height: height).offset(x: x)
                    let nowY = CGFloat(model.now.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600) * hour
                    Rectangle().fill(Theme.accentFill).frame(width: column, height: 2).offset(x: x, y: nowY - 1)
                    Circle().fill(Theme.accentFill).frame(width: 8, height: 8).offset(x: x - 4, y: nowY - 4)
                }
                let dayMarks = MonthGrid.marks(marks, on: day).sorted { $0.start < $1.start }
                let blocks = WeekLayout.blocks(dayMarks, day: Calendar.current.startOfDay(for: day), minMinutes: 40, now: model.now)
                ForEach(Array(zip(dayMarks, blocks).enumerated()), id: \.element.0.id) { _, pair in
                    block(pair.0, pair.1, x: x, column: column)
                }
            }
        }
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func block(_ m: TimeMark, _ b: WeekBlock, x: CGFloat, column: CGFloat) -> some View {
        let w = column / CGFloat(b.columns)
        let h = CGFloat((b.bottom - b.top) / 60) * hour
        let style = m.mark.soft
        let isSelected = selected == m.id
        return Button {
            selected = m.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text((m.mark == .failed ? "✕ " : "") + m.jobID).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                if h >= 26 {
                    Text("\(Formatting.clock(m.start)), " + (m.mark == .planned ? "planned" : took(m))).font(.system(size: 10)).lineLimit(1)
                }
            }
            .foregroundStyle(style.text)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(width: max(8, w - 4), height: h, alignment: .topLeading)
            .background(style.fill, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style.border, style: StrokeStyle(lineWidth: 1, dash: m.mark == .planned ? [3, 2] : []))
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accentFill, lineWidth: 2).padding(-2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: x + CGFloat(b.column) * w + 2, y: CGFloat(b.top / 60) * hour)
        .zIndex(isSelected ? 2 : 1)
        .help("\(m.jobID), \(Formatting.clock(m.start)), \(m.mark.title.lowercased())")
    }

    private func took(_ m: TimeMark) -> String {
        let end = m.end ?? (m.mark == .working ? model.now : m.start)
        return "\(max(1, Int((end.timeIntervalSince(m.start) / 60).rounded()))) min"
    }

    // MARK: Side panel

    private func sidePanel(_ marks: [TimeMark], all: [TimeMark]) -> some View {
        let mark = all.first { $0.id == selected }
        let run = mark?.runID.flatMap { id in merged.first { $0.id == id } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let mark {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(mark.jobID).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Chip(text: mark.mark.title, kind: chip(mark.mark))
                            }
                            Text(Formatting.dayTitle(mark.start, now: model.now) + " at " + Formatting.clock(mark.start))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            RowDivider()
                            if let run {
                                row("Took", run.seconds(now: model.now).map { Formatting.duration($0) + (run.status.isFinished ? "" : " so far") } ?? "Not started")
                                row("Started by", RunText.startedBy(run, scheduleText: model.job(run.jobId)?.scheduleText))
                                let line = RunText.line(run, now: model.now)
                                row("Result", line.text, color: line.tone == .plain ? .primary : line.tone.color)
                                HStack {
                                    SmallButton("Show Log") { perform(.showLog(run.id)) }
                                    if model.job(run.jobId) != nil {
                                        SmallButton("Run Again") { perform(.runNow(run.jobId)) }
                                    }
                                }
                            } else {
                                row("Took", "Not run yet")
                                if let job = model.job(mark.jobID), let next = ApiDate.parse(job.nextRun),
                                   abs(next.timeIntervalSince(mark.start)) < 1 {
                                    SmallButton("Run Now, Instead of This Run") { perform(.runEarly(job.id)) }
                                }
                            }
                        }
                    }
                } else {
                    Text("Click a run to see it here.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(days == 7 ? "This week" : "This day")
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(RunMark.allCases, id: \.self) { kind in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3).fill(kind.soft.fill)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(kind.soft.border, lineWidth: 1))
                                        .frame(width: 12, height: 12)
                                    Text(kind.title).font(.system(size: 12))
                                    Spacer()
                                    Text("\(marks.filter { $0.mark == kind }.count)").font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("A block is at least 40 minutes tall, so short runs stay readable. Hover a block for its exact time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func chip(_ mark: RunMark) -> Chip.Kind {
        switch mark {
        case .succeeded: .success
        case .failed: .danger
        case .timedOut: .warning
        case .stopped, .planned: .neutral
        case .working: .accent
        }
    }

    private func row(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}
