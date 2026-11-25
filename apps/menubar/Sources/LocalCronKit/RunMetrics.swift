import Foundation

/// What the resources chart of a run shows.
public enum ResourceMetric: String, CaseIterable, Sendable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case processes = "Processes"

    public var id: String { rawValue }
}

/// One point of a line in the resources chart.
public struct MetricPoint: Identifiable, Equatable, Sendable {
    /// Seconds since the run started.
    public var t: Double
    public var value: Double
    /// The line: the metric's name, or "Read" and "Write" for disk.
    public var series: String

    public var id: String { "\(series) \(t)" }
}

/// The texts and points of the resources card above a run's log.
public enum RunMetrics {
    public static let read = "Read"
    public static let write = "Write"

    /// The lines of one metric: disk has two, read and write.
    public static func points(_ samples: [MetricSample], _ metric: ResourceMetric) -> [MetricPoint] {
        switch metric {
        case .cpu: samples.map { MetricPoint(t: $0.t, value: $0.cpu, series: metric.rawValue) }
        case .memory: samples.map { MetricPoint(t: $0.t, value: Double($0.mem), series: metric.rawValue) }
        case .processes: samples.map { MetricPoint(t: $0.t, value: Double($0.procs), series: metric.rawValue) }
        case .disk:
            samples.map { MetricPoint(t: $0.t, value: $0.read, series: read) }
                + samples.map { MetricPoint(t: $0.t, value: $0.write, series: write) }
        }
    }

    /// The big text of a tile and the small one under it. A finished run
    /// shows its sums; a running one its newest sample.
    public static func tile(_ metric: ResourceMetric, resources: Resources?, samples: [MetricSample]) -> (value: String, note: String) {
        if let r = resources {
            switch metric {
            case .cpu: return (Formatting.duration(r.cpuSecs), "peak \(percent(r.peakCpu))")
            case .memory: return (Formatting.bytes(r.peakMem), "peak")
            case .disk: return (Formatting.bytes(r.readBytes + r.writtenBytes), "\(Formatting.bytes(r.readBytes)) read")
            case .processes: return ("\(r.peakProcs)", "peak")
            }
        }
        guard let last = samples.last else { return ("–", "") }
        switch metric {
        case .cpu: return (percent(last.cpu), "now")
        case .memory: return (Formatting.bytes(last.mem), "now")
        case .disk: return (rate(last.read + last.write), "now")
        case .processes: return ("\(last.procs)", "now")
        }
    }

    /// A label of the value axis.
    public static func axis(_ metric: ResourceMetric, _ value: Double) -> String {
        switch metric {
        case .cpu: percent(value)
        case .memory: Formatting.bytes(UInt64(max(0, value)))
        case .disk: rate(value)
        case .processes: "\(Int(value.rounded()))"
        }
    }

    /// "0:02", "12:05", "1:02:03": time since the run started.
    public static func elapsed(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        let (h, m, sec) = (s / 3600, s / 60 % 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "250%": 2.5 cores.
    public static func percent(_ value: Double) -> String {
        "\(Int(max(0, value).rounded()))%"
    }

    /// "0 B/s", "12 KB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let n = UInt64(max(0, bytesPerSecond).rounded())
        return n == 0 ? "0 B/s" : Formatting.bytes(n).replacingOccurrences(of: " bytes", with: " B") + "/s"
    }

    /// Under the chart when there is nothing to draw.
    public static func empty(_ run: Run) -> String {
        run.status.isFinished
            ? "This run was shorter than one sample (every 2 s): only its sums are kept."
            : "The first sample comes 2 s after the start."
    }
}
