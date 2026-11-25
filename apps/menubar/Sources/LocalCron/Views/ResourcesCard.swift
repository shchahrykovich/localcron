import Charts
import LocalCronKit
import SwiftUI

/// What a run's processes used, above its log: four tiles (CPU, memory,
/// disk, processes) and the chart of the chosen one, a sample every 2 s.
/// Texts and points come from `RunMetrics`.
struct ResourcesCard: View {
    let metrics: GetRunMetricsResult
    @AppStorage("runResourceMetric") private var choice = ResourceMetric.cpu.rawValue

    private var metric: ResourceMetric { ResourceMetric(rawValue: choice) ?? .cpu }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(ResourceMetric.allCases) { tile($0) }
                }
                if metrics.samples.isEmpty {
                    Text(RunMetrics.empty(metrics.run)).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    chart
                }
            }
        }
    }

    private func tile(_ m: ResourceMetric) -> some View {
        let selected = m == metric
        let text = RunMetrics.tile(m, resources: metrics.run.resources, samples: metrics.samples)
        return Button {
            choice = m.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(text.value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
                Text(text.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.accentSoft : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accentRing : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Show \(m.rawValue.lowercased()) over time")
    }

    private var chart: some View {
        let m = metric
        let points = RunMetrics.points(metrics.samples, m)
        let series = m == .disk ? [RunMetrics.read, RunMetrics.write] : [m.rawValue]
        let end = max(metrics.samples.last?.t ?? 0, metrics.intervalSecs)
        return VStack(alignment: .leading, spacing: 4) {
            Chart(points) { p in
                if m != .disk {
                    AreaMark(x: .value("Time", p.t), y: .value(m.rawValue, p.value))
                        .foregroundStyle(Theme.accent.opacity(0.12))
                }
                LineMark(x: .value("Time", p.t), y: .value(m.rawValue, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale(domain: series, range: m == .disk ? [Theme.accent, Theme.warning] : [Theme.accent])
            .chartLegend(.hidden)
            .chartXScale(domain: 0...end, range: .plotDimension(endPadding: 12))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.innerLine)
                    AxisValueLabel {
                        if let n = value.as(Double.self) { Text(RunMetrics.axis(m, n)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let t = value.as(Double.self) { Text(RunMetrics.elapsed(t)).fixedSize() }
                    }
                }
            }
            .font(.system(size: 10))
            .frame(height: 110)
            if m == .disk {
                HStack(spacing: 12) {
                    legend(RunMetrics.read, Theme.accent)
                    legend(RunMetrics.write, Theme.warning)
                }
            }
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
