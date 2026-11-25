import Foundation
import XCTest
@testable import LocalCronKit

final class RunMetricsTests: XCTestCase {
    private let samples = [
        MetricSample(t: 2, cpu: 99.6, mem: 1_753_448, read: 2048, write: 0, procs: 1),
        MetricSample(t: 4, cpu: 250, mem: 3 * 1024 * 1024, read: 0, write: 1024, procs: 3),
    ]

    func testEachMetricIsOneLineAndDiskIsTwo() {
        XCTAssertEqual(RunMetrics.points(samples, .cpu).map(\.value), [99.6, 250])
        XCTAssertEqual(RunMetrics.points(samples, .memory).map(\.value), [1_753_448, 3_145_728])
        XCTAssertEqual(RunMetrics.points(samples, .processes).map(\.value), [1, 3])
        let disk = RunMetrics.points(samples, .disk)
        XCTAssertEqual(disk.map(\.series), ["Read", "Read", "Write", "Write"])
        XCTAssertEqual(disk.map(\.value), [2048, 0, 0, 1024])
        XCTAssertEqual(Set(disk.map(\.id)).count, 4, "ids are unique for the chart")
    }

    func testAFinishedRunShowsItsSums() {
        let r = Resources(cpuSecs: 4.47, peakCpu: 100.1, peakMem: 2 * 1024 * 1024, readBytes: 1024, writtenBytes: 3072, peakProcs: 7,
                          samples: 2)
        XCTAssertEqual(RunMetrics.tile(.cpu, resources: r, samples: samples).value, "4.5 s")
        XCTAssertEqual(RunMetrics.tile(.cpu, resources: r, samples: samples).note, "peak 100%")
        XCTAssertEqual(RunMetrics.tile(.memory, resources: r, samples: samples).value, "2 MB")
        XCTAssertEqual(RunMetrics.tile(.disk, resources: r, samples: samples).value, "4 KB")
        XCTAssertEqual(RunMetrics.tile(.disk, resources: r, samples: samples).note, "1 KB read")
        XCTAssertEqual(RunMetrics.tile(.processes, resources: r, samples: samples).value, "7")
    }

    func testARunningRunShowsItsNewestSample() {
        XCTAssertEqual(RunMetrics.tile(.cpu, resources: nil, samples: samples).value, "250%")
        XCTAssertEqual(RunMetrics.tile(.cpu, resources: nil, samples: samples).note, "now")
        XCTAssertEqual(RunMetrics.tile(.memory, resources: nil, samples: samples).value, "3 MB")
        XCTAssertEqual(RunMetrics.tile(.disk, resources: nil, samples: samples).value, "1 KB/s")
        XCTAssertEqual(RunMetrics.tile(.processes, resources: nil, samples: []).value, "–")
    }

    func testAxisLabels() {
        XCTAssertEqual(RunMetrics.axis(.cpu, 150), "150%")
        XCTAssertEqual(RunMetrics.axis(.memory, 512 * 1024 * 1024), "512 MB")
        XCTAssertEqual(RunMetrics.axis(.disk, 0), "0 B/s")
        XCTAssertEqual(RunMetrics.axis(.disk, 500), "500 B/s")
        XCTAssertEqual(RunMetrics.axis(.processes, 2.9), "3")
        XCTAssertEqual(RunMetrics.elapsed(2), "0:02")
        XCTAssertEqual(RunMetrics.elapsed(725), "12:05")
        XCTAssertEqual(RunMetrics.elapsed(3723), "1:02:03")
    }

    func testTheExampleReplyDecodesWithItsSamples() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("api/examples/get_run_metrics.reply.json")
        struct Reply: Decodable { var result: GetRunMetricsResult }
        let m = try Api.decoder.decode(Reply.self, from: Data(contentsOf: url)).result
        XCTAssertEqual(m.intervalSecs, 2)
        XCTAssertEqual(m.samples.map(\.t), [2, 4])
        XCTAssertEqual(m.run.resources?.cpuSecs, 4.47)
        XCTAssertEqual(RunMetrics.tile(.cpu, resources: m.run.resources, samples: m.samples).value, "4.5 s")
    }

    func testTheEmptyChartSaysWhy() {
        XCTAssertTrue(RunMetrics.empty(makeRun("a.1", .succeeded, start: "2026-10-30T08:00:00Z", end: "2026-10-30T08:00:01Z"))
            .contains("shorter than one sample"))
        XCTAssertTrue(RunMetrics.empty(makeRun("a.2", .running, start: "2026-10-30T08:00:00Z")).contains("first sample"))
    }
}
