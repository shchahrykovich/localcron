import Charts
import LocalCronKit
import SwiftUI

/// The tokens that claude and codex runs used: a bar for each day, split by
/// job, and the jobs with the most. With a job chosen, its bars are split
/// by kind of tokens.
struct UsageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let stats = TokenStats(runs: model.allRuns, now: model.now, period: model.usagePeriod, metric: model.usageMetric,
                               job: model.usageJob)
        ScrollView {
            VStack(spacing: 10) {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        header(stats)
                        Segments(items: TokenMetric.allCases, selection: $model.usageMetric, fill: false) { metric, _ in
                            Text(metric.rawValue)
                        }
                        .fixedSize()
                        if stats.runs == 0 {
                            empty
                        } else {
                            chart(stats)
                            legend(stats)
                        }
                    }
                }
                if model.usageJob == nil, !stats.jobs.isEmpty {
                    SectionLabel(text: "Jobs") { Text("the most tokens first") }
                    Card {
                        ForEach(Array(stats.jobs.enumerated()), id: \.element.id) { i, job in
                            if i > 0 { RowDivider() }
                            jobRow(job, of: stats)
                        }
                    }
                } else if let id = model.usageJob, let job = stats.jobs.first {
                    SectionLabel(id)
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(TokenKind.allCases, id: \.self) { kind in
                                kindRow(kind, job.usage)
                            }
                            RowDivider().padding(.vertical, 2)
                            Text("Cache reads cost about a tenth of new input, so the output and the new input "
                                 + "matter most for the price.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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

    private func header(_ stats: TokenStats) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let id = model.usageJob {
                Button {
                    model.usageJob = nil
                } label: {
                    Label("All jobs", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                if let job = model.job(id) {
                    JobGlyph(job: job.job, size: 12).foregroundStyle(.secondary)
                }
                Text(id).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Formatting.tokens(model.usageMetric.value(stats.total))) \(model.usageMetric == .output ? "output tokens" : "tokens")")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(summary(stats)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// "12 runs, 46K output, 9.1M from the cache".
    private func summary(_ stats: TokenStats) -> String {
        let runs = RunGroups.count(stats.runs)
        if model.usageMetric == .output { return "\(runs), \(Formatting.tokens(stats.total.total)) tokens in all" }
        return "\(runs), \(Formatting.tokens(stats.total.outputTokens)) output, "
            + "\(Formatting.tokens(stats.total.cacheReadTokens)) from the cache"
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Text("No tokens in this time").font(.system(size: 12, weight: .medium))
            Text("A claude or codex run shows its tokens here when it ends.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func chart(_ stats: TokenStats) -> some View {
        Chart(stats.bars) { bar in
            BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Tokens", Double(bar.tokens)))
                .foregroundStyle(by: .value("Series", bar.series))
        }
        .chartForegroundStyleScale(domain: stats.series, range: stats.series.map { color($0, in: stats) })
        .chartLegend(.hidden)
        .chartXScale(domain: (stats.days.first ?? model.now)...(Calendar.current.date(byAdding: .day, value: 1,
                                                                                         to: stats.days.last ?? model.now) ?? model.now), range: .plotDimension(endPadding: 16))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.innerLine)
                AxisValueLabel {
                    if let n = value.as(Double.self) { Text(Formatting.tokens(UInt64(max(0, n)))) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: model.usagePeriod == .week ? 1 : model.usagePeriod == .month ? 7 : 30)) { _ in
                AxisValueLabel(format: model.usagePeriod == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
            }
        }
        .font(.system(size: 10))
        .frame(height: 150)
    }

    private func legend(_ stats: TokenStats) -> some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(stats.series, id: \.self) { name in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(color(name, in: stats)).frame(width: 8, height: 8)
                    Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .help(name)
            }
        }
    }

    private func jobRow(_ job: JobTokens, of stats: TokenStats) -> some View {
        let value = model.usageMetric.value(job.usage)
        let largest = max(1, stats.jobs.map { model.usageMetric.value($0.usage) }.max() ?? 1)
        return Button {
            model.usageJob = job.jobID
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color(stats.series.contains(job.jobID) ? job.jobID : TokenStats.other, in: stats))
                    .frame(width: 4, height: 26)
                if let view = model.job(job.jobID) {
                    JobGlyph(job: view.job, size: 13).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.jobID).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(Formatting.tokens(value)).font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    GeometryReader { geo in
                        Capsule().fill(Theme.accentFill.opacity(0.7))
                            .frame(width: max(2, geo.size.width * CGFloat(value) / CGFloat(largest)), height: 3)
                    }
                    .frame(height: 3)
                    Text("\(RunGroups.count(job.runs)), \(Formatting.tokens(job.usage.outputTokens)) output, "
                         + "\(Formatting.tokens(job.usage.total / UInt64(max(1, job.runs)))) a run")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The tokens of \(job.jobID) by day")
    }

    private func kindRow(_ kind: TokenKind, _ usage: TokenUsage) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Self.kindColor(kind)).frame(width: 8, height: 8)
            Text(kind.rawValue).font(.system(size: 12))
            Spacer()
            Text(Formatting.tokens(kind.value(usage))).font(.system(size: 12).monospacedDigit())
        }
    }

    private static let jobColors: [Color] = [
        Theme.accentFill,
        Color(light: 0x1F9E89, dark: 0x3CC4AC),
        Color(light: 0xE08A00, dark: 0xF0A030),
        Color(light: 0xC2417A, dark: 0xE86AA0),
        Color(light: 0x3B82C4, dark: 0x6AAEF0),
    ]

    static func kindColor(_ kind: TokenKind) -> Color {
        switch kind {
        case .input: Theme.accentFill
        case .cacheWrite: Color(light: 0x8F8CE0, dark: 0x7A76D8)
        case .cacheRead: Theme.planned
        case .output: Color(light: 0xE08A00, dark: 0xF0A030)
        }
    }

    private func color(_ series: String, in stats: TokenStats) -> Color {
        if let kind = TokenKind(rawValue: series), model.usageJob != nil { return Self.kindColor(kind) }
        if series == TokenStats.other { return Theme.stopped }
        let i = stats.series.firstIndex(of: series) ?? 0
        return Self.jobColors[i % Self.jobColors.count]
    }
}
